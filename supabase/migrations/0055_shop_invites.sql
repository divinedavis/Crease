-- Shop sign-up by invite link.
--
-- Until now every shop was a hand-written insert (0035 is Fulton's) plus a
-- cleaner_staff row added by hand, which meant a shop that said yes at the
-- counter could not actually start until somebody got to a laptop. This lets
-- the founder hand a shop a link (or its QR) from the canvass page; the shop
-- signs in with Google, types its address and laundry price, and lands in the
-- portal as a PENDING shop that customers cannot see until the founder
-- approves it.
--
-- Why it is shaped this way:
--
--   * A shop account sees its customers' names, home addresses and handoff
--     PINs. So nobody becomes a shop by finding a URL: each invite is a
--     single-use, 48-bit random code that expires in 14 days, and even a
--     claimed invite only produces an INACTIVE shop. `active` is still not a
--     column the authenticated role can update (0021), so a shop cannot
--     approve itself; approve_shop() below is the only way on, and it checks
--     crease_admins.
--   * Admins are a table of user ids, not an email in a policy. The repo is
--     public, and a user id is not a login you can claim by signing up with
--     the right address. The row itself is inserted out of band, never in a
--     migration.
--   * The claim runs as one SECURITY DEFINER function so the invite, the shop,
--     its owner row and its first price are written in one transaction or not
--     at all, with the invite row locked so two phones cannot both spend it.

-- ---------------------------------------------------------------------------
-- who may mint invites and approve shops
-- ---------------------------------------------------------------------------
create table if not exists public.crease_admins (
  user_id    uuid primary key references auth.users on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.crease_admins enable row level security;
revoke all on public.crease_admins from public, anon, authenticated;
grant select, insert, update, delete on public.crease_admins to service_role;

create or replace function public.is_crease_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.crease_admins where user_id = (select auth.uid()));
$$;
revoke all on function public.is_crease_admin() from public, anon;
grant execute on function public.is_crease_admin() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- invites
-- ---------------------------------------------------------------------------
create table if not exists public.shop_invites (
  id             uuid primary key default gen_random_uuid(),
  -- 12 hex characters out of a v4 uuid's random bits: 48 bits, unambiguous to
  -- read aloud, and the only thing standing between a stranger and a pending
  -- shop. peek/claim answer the same "not valid" for unknown, used and expired.
  code           text not null unique
                 default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))
                 check (code ~ '^[A-F0-9]{12}$'),
  label          text not null check (length(label) between 1 and 120),
  prospect_id    uuid references public.prospects on delete set null,
  -- What the shop's payout gives up. 290 is the floor 0038 enforces on every
  -- shop: exactly Stripe's card percentage, cost recovery rather than a cut of
  -- the cleaning, and what Fulton pays. Anything above it is a per-invite
  -- decision made before the link is handed over.
  commission_bps int not null default 290 check (commission_bps between 290 and 5000),
  created_by     uuid references auth.users on delete set null,
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null default now() + interval '14 days',
  claimed_at     timestamptz,
  claimed_by     uuid references auth.users on delete set null,
  cleaner_id     uuid references public.cleaners on delete set null
);
create index if not exists shop_invites_prospect_idx on public.shop_invites (prospect_id);
alter table public.shop_invites enable row level security;
revoke all on public.shop_invites from public, anon, authenticated;
grant select, insert, update, delete on public.shop_invites to service_role;

-- When the founder switched a shop on. Null on an invited shop means pending.
alter table public.cleaners add column if not exists approved_at timestamptz;
update public.cleaners set approved_at = created_at where active and approved_at is null;
grant select (approved_at) on public.cleaners to authenticated;

-- A pending shop's staff must be able to read their own row, or the portal
-- tells a shop that just signed up that it is "not linked to a shop". Active
-- rows stay readable to everyone exactly as before (the app's shop picker);
-- the column grants from 0024 still decide WHICH columns.
alter policy cleaners_read on public.cleaners
  using (active or public.is_cleaner_staff(id));

-- ---------------------------------------------------------------------------
-- founder side: mint, list, approve
-- ---------------------------------------------------------------------------
create or replace function public.create_shop_invite(p_label text, p_prospect uuid default null)
returns table (id uuid, code text, expires_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_label text := btrim(coalesce(p_label, ''));
begin
  if not public.is_crease_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if length(v_label) = 0 or length(v_label) > 120 then
    raise exception 'label must be 1-120 characters' using errcode = '22023';
  end if;
  -- One open invite per canvassed shop: tapping the button twice should show
  -- the same link, not mint a second live one.
  if p_prospect is not null then
    return query
      select i.id, i.code, i.expires_at from public.shop_invites i
      where i.prospect_id = p_prospect and i.claimed_at is null and i.expires_at > now()
      order by i.created_at desc limit 1;
    if found then return; end if;
  end if;
  return query
    insert into public.shop_invites (label, prospect_id, created_by)
    values (v_label, p_prospect, (select auth.uid()))
    returning shop_invites.id, shop_invites.code, shop_invites.expires_at;
end;
$$;
revoke all on function public.create_shop_invite(text, uuid) from public, anon;
grant execute on function public.create_shop_invite(text, uuid) to authenticated;

create or replace function public.list_shop_invites()
returns table (
  id uuid, code text, label text, prospect_id uuid, created_at timestamptz,
  expires_at timestamptz, claimed_at timestamptz, cleaner_id uuid,
  shop_name text, shop_address text, shop_phone text, active boolean,
  approved_at timestamptz, payouts_enabled boolean,
  price_cents_per_lb int, minimum_lbs numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_crease_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return query
    select i.id, i.code, i.label, i.prospect_id, i.created_at, i.expires_at,
           i.claimed_at, i.cleaner_id, c.name,
           concat_ws(', ', c.line1, c.city, c.state || ' ' || c.postal_code),
           c.phone, c.active, c.approved_at, coalesce(c.payouts_enabled, false),
           s.unit_price_cents, s.minimum_units
    from public.shop_invites i
    left join public.cleaners c on c.id = i.cleaner_id
    left join lateral (
      select si.unit_price_cents, si.minimum_units from public.service_items si
      where si.cleaner_id = c.id and si.service_type = 'wash_fold' and si.unit = 'pound'
      order by si.active desc, si.sort_order limit 1
    ) s on true
    order by i.created_at desc;
end;
$$;
revoke all on function public.list_shop_invites() from public, anon;
grant execute on function public.list_shop_invites() to authenticated;

create or replace function public.approve_shop(p_cleaner uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  n int;
begin
  if not public.is_crease_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  -- Only shops that came in through an invite: this is not a general-purpose
  -- switch for turning hand-made shops on and off.
  update public.cleaners c set active = true, approved_at = coalesce(c.approved_at, now())
  where c.id = p_cleaner
    and exists (select 1 from public.shop_invites i where i.cleaner_id = c.id);
  get diagnostics n = row_count;
  return n = 1;
end;
$$;
revoke all on function public.approve_shop(uuid) from public, anon;
grant execute on function public.approve_shop(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- shop side: look at a link, then spend it
-- ---------------------------------------------------------------------------

-- What the join page shows before sign-in: the name and address the founder
-- had on file, so the shop sees its own storefront, not a blank form. Answers
-- nothing at all for a code that is unknown, used or expired.
create or replace function public.peek_shop_invite(p_code text)
returns table (label text, address text, zip text, phone text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select i.label, p.address, p.zip, p.phone
  from public.shop_invites i
  left join public.prospects p on p.id = i.prospect_id
  where i.code = upper(btrim(p_code))
    and i.claimed_at is null
    and i.expires_at > now();
$$;
revoke all on function public.peek_shop_invite(text) from public;
grant execute on function public.peek_shop_invite(text) to anon, authenticated;

create or replace function public.claim_shop_invite(
  p_code text,
  p_name text,
  p_phone text,
  p_line1 text,
  p_city text,
  p_state text,
  p_postal_code text,
  p_lat double precision,
  p_lng double precision,
  p_price_cents_per_lb int,
  p_minimum_lbs numeric,
  p_turnaround_hours int
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_invite public.shop_invites%rowtype;
  v_name   text := btrim(coalesce(p_name, ''));
  v_id     uuid;
  v_slug   text;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;

  select * into v_invite from public.shop_invites
  where code = upper(btrim(p_code))
  for update;
  if not found or v_invite.claimed_at is not null or v_invite.expires_at <= now() then
    raise exception 'invite not valid' using errcode = 'P0002';
  end if;

  -- The portal validates all of this first; this is the backstop for anyone
  -- calling the function straight from the anon key with a code in hand.
  if length(v_name) not between 1 and 120
     or coalesce(p_phone, '') !~ '^\+1[0-9]{10}$'
     or length(btrim(coalesce(p_line1, ''))) not between 1 and 200
     or length(btrim(coalesce(p_city, ''))) not between 1 and 80
     or coalesce(p_state, '') !~ '^[A-Z]{2}$'
     or coalesce(p_postal_code, '') !~ '^[0-9]{5}$'
     or p_lat is null or p_lat not between -90 and 90
     or p_lng is null or p_lng not between -180 and 180
     or p_price_cents_per_lb is null or p_price_cents_per_lb not between 50 and 2000
     or p_minimum_lbs is null or p_minimum_lbs not between 0 and 50
     or p_turnaround_hours is null or p_turnaround_hours not between 1 and 336 then
    raise exception 'invalid shop details' using errcode = '22023';
  end if;

  v_slug := trim(both '-' from regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g'));
  v_slug := coalesce(nullif(v_slug, ''), 'shop') || '-' || lower(substr(v_invite.code, 1, 6));

  insert into public.cleaners
    (name, slug, phone, email, line1, city, state, postal_code, lat, lng,
     turnaround_hours, commission_bps, active, approved_at)
  values
    (v_name, v_slug, p_phone, (select auth.email()), btrim(p_line1), btrim(p_city),
     p_state, p_postal_code, p_lat, p_lng, p_turnaround_hours,
     v_invite.commission_bps, false, null)
  returning id into v_id;

  insert into public.cleaner_staff (cleaner_id, user_id, role)
  values (v_id, v_uid, 'owner');

  insert into public.service_items
    (cleaner_id, code, label, unit_price_cents, service_type, unit,
     turnaround_hours, minimum_units, sort_order)
  values
    (v_id, 'wash_fold', 'Wash & fold', p_price_cents_per_lb, 'wash_fold', 'pound',
     p_turnaround_hours, p_minimum_lbs, 10);

  update public.shop_invites
  set claimed_at = now(), claimed_by = v_uid, cleaner_id = v_id
  where id = v_invite.id;

  return v_id;
end;
$$;
revoke all on function public.claim_shop_invite(text, text, text, text, text, text, text, double precision, double precision, int, numeric, int) from public, anon;
grant execute on function public.claim_shop_invite(text, text, text, text, text, text, text, double precision, double precision, int, numeric, int) to authenticated;

notify pgrst, 'reload schema';
