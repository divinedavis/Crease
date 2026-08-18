-- Every address anyone asks us about, whether or not they order.
--
-- The question is where in Brooklyn people want this, and no existing table can
-- answer it: orders only records the people who already said yes, in the two
-- neighbourhoods where a partner happens to exist. The ones who typed an
-- address, found out we do not reach them and closed the tab are the entire
-- point — they are the map of where to sign the next shop.
--
-- So the check itself is the instrument. Somebody entering an address is
-- expressing demand at a location, and that is recorded before anything is
-- asked of them: no account, no email, no order.
--
-- It is personal data, so it is write-only from the outside. anon may insert
-- (that is the whole feature) and may never read: the table is a list of
-- home addresses, and one leaked select is every customer's door.

create table public.demand_pings (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  -- What they typed, as they typed it. Kept because a failed geocode is a
  -- signal too — a street we cannot resolve is a street we cannot serve.
  query           text not null check (length(query) between 2 and 300),
  lat             double precision,
  lng             double precision,
  -- NYC neighbourhood, resolved server-side where the geocode allows it, so
  -- the report can group without re-geocoding a year of rows.
  neighborhood    text,
  in_service_area boolean not null default false,
  nearest_cleaner_id uuid references public.cleaners on delete set null,
  nearest_miles   numeric(5,2),
  -- Optional and asked for only after the answer: somebody outside the area
  -- who wants telling when we arrive. Null for everyone who just looked.
  email           text check (email is null or length(email) between 3 and 320),
  -- Anonymous, per-browser, so three attempts at the same address by one
  -- person do not read as three households wanting this.
  session_ref     text,
  source          text not null default 'web'
);

create index demand_pings_created_idx on public.demand_pings(created_at desc);
create index demand_pings_area_idx on public.demand_pings(in_service_area, created_at desc);
create index demand_pings_email_idx on public.demand_pings(email) where email is not null;

alter table public.demand_pings enable row level security;

-- Insert-only from the outside. There is deliberately no select policy for
-- anon or authenticated: this table is a list of where people live.
create policy demand_pings_public_insert on public.demand_pings
  for insert to anon, authenticated with check (true);

grant insert on public.demand_pings to anon, authenticated;
revoke select, update, delete on public.demand_pings from anon, authenticated;
grant select, insert, update, delete on public.demand_pings to service_role;

notify pgrst, 'reload schema';
