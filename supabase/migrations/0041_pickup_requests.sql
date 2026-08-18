-- An order placed from the web, before the web can place a real one.
--
-- A real order row needs an authenticated customer: orders.customer_id is
-- auth.uid() and every policy on it turns on that. The site has no accounts
-- yet — and asking somebody to create one before they can find out whether we
-- even reach their street is how a first order becomes a bounced tab.
--
-- So a request is what the web takes today: everything needed to place the
-- order on their behalf, from a form that takes twenty seconds. The counter
-- staff and the founder work them by hand, which at one partner shop is the
-- honest capacity anyway, and every one is a real person with a real address
-- asking for a real pickup — which is a far better demand signal than an email
-- on a waitlist.
--
-- Write-only from outside, like demand_pings and for the same reason: this is
-- a list of names, phone numbers and home addresses.

create table public.pickup_requests (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  name          text not null check (length(name) between 1 and 120),
  -- The only channel that reliably reaches somebody about a pickup today.
  phone         text not null check (length(phone) between 7 and 32),
  email         text check (email is null or length(email) between 3 and 320),
  address       text not null check (length(address) between 3 and 300),
  address_notes text check (address_notes is null or length(address_notes) <= 500),
  lat           double precision,
  lng           double precision,
  service_type  service_type not null default 'dry_clean',
  service_tier  text not null default 'round_trip'
                  check (service_tier in ('round_trip', 'pickup_only', 'return_only')),
  -- Free text on purpose. "Two suits and a comforter" is what people can
  -- actually tell you before anyone has opened the bag, and the shop prices it
  -- at intake exactly as it does for an app order.
  items_note    text check (items_note is null or length(items_note) <= 1000),
  preferred_when text check (preferred_when is null or length(preferred_when) <= 200),
  cleaner_id    uuid references public.cleaners on delete set null,
  -- The coverage check that preceded it, so a request can be read back to the
  -- address that produced it.
  demand_ping_id uuid references public.demand_pings on delete set null,
  status        text not null default 'new'
                  check (status in ('new', 'contacted', 'booked', 'declined')),
  handled_notes text,
  order_id      uuid references public.orders on delete set null,
  updated_at    timestamptz not null default now()
);

create index pickup_requests_status_idx on public.pickup_requests(status, created_at desc);
create index pickup_requests_cleaner_idx on public.pickup_requests(cleaner_id, created_at desc);

create trigger pickup_requests_touch before update on public.pickup_requests
  for each row execute function public.touch_updated_at();

alter table public.pickup_requests enable row level security;

create policy pickup_requests_public_insert on public.pickup_requests
  for insert to anon, authenticated with check (true);

-- Shop staff see the requests addressed to their own shop, and nothing else.
create policy pickup_requests_cleaner_read on public.pickup_requests
  for select to authenticated using (public.is_cleaner_staff(cleaner_id));
create policy pickup_requests_cleaner_update on public.pickup_requests
  for update to authenticated using (public.is_cleaner_staff(cleaner_id))
  with check (public.is_cleaner_staff(cleaner_id));

grant insert on public.pickup_requests to anon;
grant select, insert, update on public.pickup_requests to authenticated;
grant select, insert, update, delete on public.pickup_requests to service_role;

notify pgrst, 'reload schema';
