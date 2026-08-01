-- Crease — core schema
-- Two-leg dry cleaning marketplace: customer -> cleaner (pickup leg),
-- cleaner -> customer (return leg). Each leg is an independent courier
-- delivery, because no courier network holds a package for three days.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- enums
-- ---------------------------------------------------------------------------

-- The order lifecycle spans both legs plus the cleaning in between.
-- `awaiting_approval` exists because a dry cleaning order cannot be priced
-- until the cleaner opens the bag and counts what is actually in it.
create type order_status as enum (
  'draft',
  'scheduled',            -- pickup window chosen, not yet dispatched
  'pickup_dispatched',    -- courier requested for leg 1
  'in_transit_to_cleaner',
  'at_cleaner',           -- dropped off, not yet counted
  'awaiting_approval',    -- intake price exceeds the customer's estimate
  'cleaning',
  'ready',                -- cleaned, waiting for return window
  'return_dispatched',    -- courier requested for leg 2
  'in_transit_to_customer',
  'delivered',
  'cancelled',
  'failed'
);

create type leg_type as enum ('pickup', 'return');

-- Normalized across providers. Uber Direct, DoorDash Drive and the mock
-- courier all map onto these; raw provider status is kept on the row.
create type leg_status as enum (
  'pending',              -- created locally, not yet sent to a provider
  'dispatching',          -- provider accepted, finding a courier
  'courier_assigned',
  'en_route_to_pickup',
  'at_pickup',
  'picked_up',
  'en_route_to_dropoff',
  'at_dropoff',
  'delivered',
  'returned',             -- courier could not deliver, brought it back
  'cancelled',
  'failed'
);

create type payment_status as enum (
  'requires_payment_method',
  'authorized',           -- held at order time against the estimate
  'captured',             -- taken after intake pricing is final
  'partially_refunded',
  'refunded',
  'failed',
  'cancelled'
);

-- ---------------------------------------------------------------------------
-- identity
-- ---------------------------------------------------------------------------

create table public.profiles (
  id           uuid primary key references auth.users on delete cascade,
  full_name    text,
  phone        text,
  avatar_url   text,
  default_address_id uuid,          -- fk added after addresses exists
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.addresses (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users on delete cascade,
  label        text,                -- "Home", "Office"
  line1        text not null,
  line2        text,
  city         text not null,
  state        text not null,
  postal_code  text not null,
  country      text not null default 'US',
  lat          double precision,
  lng          double precision,
  -- Courier-facing detail. Uber Direct passes these straight to the courier.
  access_notes text,                -- "buzzer 4B, leave with doorman"
  created_at   timestamptz not null default now()
);

alter table public.profiles
  add constraint profiles_default_address_fkey
  foreign key (default_address_id) references public.addresses(id) on delete set null;

create index addresses_user_id_idx on public.addresses(user_id);

-- ---------------------------------------------------------------------------
-- supply side
-- ---------------------------------------------------------------------------

create table public.cleaners (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  slug          text not null unique,
  phone         text,
  email         text,
  line1         text not null,
  line2         text,
  city          text not null,
  state         text not null,
  postal_code   text not null,
  country       text not null default 'US',
  lat           double precision not null,
  lng           double precision not null,
  -- Courier networks are short-haul. This is the radius we will quote within.
  service_radius_miles numeric(4,1) not null default 5.0,
  turnaround_hours     int not null default 48,
  -- Opening hours as an array of {dow, open, close}; couriers must arrive
  -- inside these or the leg gets returned.
  hours         jsonb not null default '[]'::jsonb,
  commission_bps int not null default 2000,   -- our cut, basis points
  stripe_account_id text,                     -- Connect account for payouts
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);

create index cleaners_active_idx on public.cleaners(active) where active;

-- Portal access. A user may staff more than one location.
create table public.cleaner_staff (
  cleaner_id  uuid not null references public.cleaners on delete cascade,
  user_id     uuid not null references auth.users on delete cascade,
  role        text not null default 'staff' check (role in ('owner','staff')),
  created_at  timestamptz not null default now(),
  primary key (cleaner_id, user_id)
);

create index cleaner_staff_user_idx on public.cleaner_staff(user_id);

-- Per-cleaner price list. Customers estimate against this; the cleaner
-- confirms actual counts at intake.
create table public.service_items (
  id          uuid primary key default gen_random_uuid(),
  cleaner_id  uuid not null references public.cleaners on delete cascade,
  code        text not null,              -- 'shirt', 'suit_2pc', 'comforter'
  label       text not null,
  unit_price_cents int not null check (unit_price_cents >= 0),
  active      boolean not null default true,
  sort_order  int not null default 0,
  unique (cleaner_id, code)
);

create index service_items_cleaner_idx on public.service_items(cleaner_id) where active;

-- ---------------------------------------------------------------------------
-- orders
-- ---------------------------------------------------------------------------

create table public.orders (
  id            uuid primary key default gen_random_uuid(),
  short_code    text not null unique default upper(substr(encode(gen_random_bytes(6),'hex'),1,6)),
  customer_id   uuid not null references auth.users on delete restrict,
  cleaner_id    uuid not null references public.cleaners on delete restrict,
  address_id    uuid not null references public.addresses on delete restrict,

  status        order_status not null default 'draft',

  -- Scheduling. Courier networks are on-demand, so these are the windows we
  -- promise the customer; the dispatcher fires the leg at window start.
  pickup_window_start  timestamptz,
  pickup_window_end    timestamptz,
  return_window_start  timestamptz,
  return_window_end    timestamptz,

  -- Money, in cents. estimate_* is what the customer saw at checkout;
  -- subtotal is what the cleaner counted at intake.
  estimate_subtotal_cents int not null default 0,
  subtotal_cents          int,
  delivery_fee_cents      int not null default 0,
  service_fee_cents       int not null default 0,
  tax_cents               int not null default 0,
  tip_cents               int not null default 0,
  total_cents             int,

  -- If intake exceeds the estimate by more than this, we stop and ask.
  -- Below it we capture silently. Keeps the happy path one-tap.
  approval_threshold_cents int not null default 1500,
  approved_at   timestamptz,

  customer_notes text,
  cleaner_notes  text,
  cancelled_reason text,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index orders_customer_idx on public.orders(customer_id, created_at desc);
create index orders_cleaner_idx  on public.orders(cleaner_id, status);
create index orders_status_idx   on public.orders(status)
  where status not in ('delivered','cancelled','failed');

-- Garments. Rows are created by the cleaner at intake, not by the customer.
create table public.order_items (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.orders on delete cascade,
  service_item_id uuid references public.service_items on delete set null,
  label        text not null,
  quantity     int not null default 1 check (quantity > 0),
  unit_price_cents int not null check (unit_price_cents >= 0),
  -- Intake photo. Evidence for damage/loss disputes, which is the single
  -- biggest liability in this business.
  photo_path   text,
  notes        text,
  created_at   timestamptz not null default now()
);

create index order_items_order_idx on public.order_items(order_id);

-- ---------------------------------------------------------------------------
-- delivery legs — the courier abstraction boundary
-- ---------------------------------------------------------------------------

create table public.delivery_legs (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references public.orders on delete cascade,
  leg            leg_type not null,
  status         leg_status not null default 'pending',

  provider       text not null default 'mock',    -- 'mock'|'uber_direct'|'doordash'
  provider_delivery_id text,
  provider_status text,                           -- raw, for debugging
  tracking_url   text,

  -- Denormalized endpoints. The courier call must not depend on a join, and
  -- addresses can be edited after the fact — the leg records what we sent.
  pickup_name    text not null,
  pickup_phone   text,
  pickup_address text not null,
  pickup_lat     double precision,
  pickup_lng     double precision,
  dropoff_name   text not null,
  dropoff_phone  text,
  dropoff_address text not null,
  dropoff_lat    double precision,
  dropoff_lng    double precision,

  -- Verification. Signature on both legs is the recommendation for garments.
  pickup_verification  text,   -- 'none'|'signature'|'pincode'|'picture'
  dropoff_verification text,
  dropoff_pincode      text,

  courier_name    text,
  courier_phone   text,
  courier_vehicle text,
  courier_lat     double precision,
  courier_lng     double precision,

  fee_cents       int,
  quoted_at       timestamptz,
  quote_expires_at timestamptz,
  dispatched_at   timestamptz,
  picked_up_at    timestamptz,
  completed_at    timestamptz,

  attempt         int not null default 1,
  last_error      text,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  -- One live leg of each type per order. Retries bump `attempt` on a new row
  -- only after the previous one is terminal, so partial-unique it.
  constraint delivery_legs_provider_unique unique (provider, provider_delivery_id)
);

create index delivery_legs_order_idx on public.delivery_legs(order_id, leg);
create unique index delivery_legs_one_live_idx
  on public.delivery_legs(order_id, leg)
  where status not in ('delivered','returned','cancelled','failed');

-- Raw provider webhooks. Landing table — service_role only, never exposed.
-- Kept verbatim so a mis-parse can be replayed instead of lost.
create table public.delivery_events (
  id          bigserial primary key,
  provider    text not null,
  event_id    text,
  event_type  text,
  delivery_leg_id uuid references public.delivery_legs on delete set null,
  provider_delivery_id text,
  payload     jsonb not null,
  signature_valid boolean,
  processed_at timestamptz,
  error       text,
  received_at timestamptz not null default now()
);

create unique index delivery_events_dedupe_idx
  on public.delivery_events(provider, event_id) where event_id is not null;
create index delivery_events_unprocessed_idx
  on public.delivery_events(received_at) where processed_at is null;

-- ---------------------------------------------------------------------------
-- payments
-- ---------------------------------------------------------------------------

create table public.payments (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.orders on delete cascade,
  status        payment_status not null default 'requires_payment_method',
  stripe_payment_intent_id text unique,
  -- Authorized against the estimate at checkout, captured after intake.
  authorized_cents int,
  captured_cents   int,
  refunded_cents   int not null default 0,
  currency      text not null default 'usd',
  last_error    text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index payments_order_idx on public.payments(order_id);

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

-- SECURITY DEFINER so order policies can check staff membership without
-- recursing into cleaner_staff's own RLS.
create or replace function public.is_cleaner_staff(p_cleaner_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.cleaner_staff
    where cleaner_id = p_cleaner_id and user_id = auth.uid()
  );
$$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger orders_touch        before update on public.orders
  for each row execute function public.touch_updated_at();
create trigger delivery_legs_touch before update on public.delivery_legs
  for each row execute function public.touch_updated_at();
create trigger payments_touch      before update on public.payments
  for each row execute function public.touch_updated_at();
create trigger profiles_touch      before update on public.profiles
  for each row execute function public.touch_updated_at();

-- New auth user -> profile row. No email verification step anywhere.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, full_name, avatar_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.raw_user_meta_data->>'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- row level security
-- ---------------------------------------------------------------------------

alter table public.profiles        enable row level security;
alter table public.addresses       enable row level security;
alter table public.cleaners        enable row level security;
alter table public.cleaner_staff   enable row level security;
alter table public.service_items   enable row level security;
alter table public.orders          enable row level security;
alter table public.order_items     enable row level security;
alter table public.delivery_legs   enable row level security;
alter table public.delivery_events enable row level security;
alter table public.payments        enable row level security;

create policy profiles_self on public.profiles
  for all to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy addresses_self on public.addresses
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Partner list is browsable by any signed-in user so the app can show
-- coverage before an order exists.
create policy cleaners_read on public.cleaners
  for select to authenticated using (active);
create policy cleaners_staff_write on public.cleaners
  for update to authenticated
  using (public.is_cleaner_staff(id)) with check (public.is_cleaner_staff(id));

create policy cleaner_staff_self on public.cleaner_staff
  for select to authenticated using (user_id = auth.uid());

create policy service_items_read on public.service_items
  for select to authenticated using (active or public.is_cleaner_staff(cleaner_id));
create policy service_items_write on public.service_items
  for all to authenticated
  using (public.is_cleaner_staff(cleaner_id)) with check (public.is_cleaner_staff(cleaner_id));

create policy orders_customer_read on public.orders
  for select to authenticated using (customer_id = auth.uid());
create policy orders_customer_insert on public.orders
  for insert to authenticated with check (customer_id = auth.uid());
-- Customers may only edit their own draft orders and the approval flag.
-- Every status transition past 'scheduled' is the dispatcher's job.
create policy orders_customer_update on public.orders
  for update to authenticated
  using (customer_id = auth.uid() and status in ('draft','awaiting_approval'))
  with check (customer_id = auth.uid());
create policy orders_cleaner_read on public.orders
  for select to authenticated using (public.is_cleaner_staff(cleaner_id));
create policy orders_cleaner_update on public.orders
  for update to authenticated
  using (public.is_cleaner_staff(cleaner_id)) with check (public.is_cleaner_staff(cleaner_id));

create policy order_items_read on public.order_items
  for select to authenticated using (
    exists (select 1 from public.orders o where o.id = order_id
            and (o.customer_id = auth.uid() or public.is_cleaner_staff(o.cleaner_id)))
  );
create policy order_items_cleaner_write on public.order_items
  for all to authenticated using (
    exists (select 1 from public.orders o where o.id = order_id
            and public.is_cleaner_staff(o.cleaner_id))
  ) with check (
    exists (select 1 from public.orders o where o.id = order_id
            and public.is_cleaner_staff(o.cleaner_id))
  );

-- Legs are read-only to everyone but the dispatcher (service_role).
create policy delivery_legs_read on public.delivery_legs
  for select to authenticated using (
    exists (select 1 from public.orders o where o.id = order_id
            and (o.customer_id = auth.uid() or public.is_cleaner_staff(o.cleaner_id)))
  );

create policy payments_read on public.payments
  for select to authenticated using (
    exists (select 1 from public.orders o where o.id = order_id and o.customer_id = auth.uid())
  );

-- delivery_events intentionally has NO policy: default-deny for anon and
-- authenticated. Only service_role (which bypasses RLS) touches it.

-- ---------------------------------------------------------------------------
-- grants — RLS gates rows, GRANT gates table visibility to PostgREST
-- ---------------------------------------------------------------------------

grant select, insert, update, delete on public.profiles      to authenticated, service_role;
grant select, insert, update, delete on public.addresses     to authenticated, service_role;
grant select                          on public.cleaners      to authenticated;
grant select, insert, update, delete on public.cleaners      to service_role;
grant update                          on public.cleaners      to authenticated;
grant select                          on public.cleaner_staff to authenticated;
grant select, insert, update, delete on public.cleaner_staff to service_role;
grant select, insert, update, delete on public.service_items to authenticated, service_role;
grant select, insert, update           on public.orders        to authenticated;
grant select, insert, update, delete on public.orders        to service_role;
grant select, insert, update, delete on public.order_items   to authenticated, service_role;
grant select                          on public.delivery_legs to authenticated;
grant select, insert, update, delete on public.delivery_legs to service_role;
grant select                          on public.payments      to authenticated;
grant select, insert, update, delete on public.payments      to service_role;
grant select, insert, update, delete on public.delivery_events to service_role;
grant usage, select on sequence public.delivery_events_id_seq to service_role;

-- is_cleaner_staff is safe for clients (it only ever answers for auth.uid()).
-- The other two are internal; make sure they are not callable from a browser.
revoke execute on function public.touch_updated_at()  from anon, authenticated;
revoke execute on function public.handle_new_user()   from anon, authenticated;
revoke execute on function public.is_cleaner_staff(uuid) from anon;

notify pgrst, 'reload schema';
