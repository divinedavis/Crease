-- Canvassing list: every dry cleaner and laundromat in Brooklyn, one row
-- each, so partner outreach ("will you accept deliveries from our app?")
-- has a checklist instead of a memory.
--
-- Seeded from OpenStreetMap (scripts/seed-prospects.mjs); the working state
-- — visited, outcome, notes — belongs to whoever is walking the streets.
-- `kind` is a hard split, not a tag: a dry cleaner and a laundromat get a
-- different pitch, and the tool has to let them be worked as separate lists.

create table public.prospects (
  id            uuid primary key default gen_random_uuid(),
  osm_id        text not null unique,      -- reseeds update, never duplicate
  kind          text not null check (kind in ('dry_cleaner', 'laundromat')),
  name          text not null,
  address       text,
  zip           text,
  phone         text,
  lat           double precision,
  lng           double precision,
  neighborhood  text not null,
  visited       boolean not null default false,
  visited_at    timestamptz,
  outcome       text check (outcome in ('interested', 'declined', 'follow_up')),
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index prospects_neighborhood_idx on public.prospects(neighborhood);

alter table public.prospects enable row level security;

-- This is the founder's street tool, not part of the customer or cleaner
-- product. Shop staff and app customers authenticate against this same
-- project, so "to authenticated" alone would hand every Bedford Cleaners
-- login the whole prospect list, notes included. The allowlist is the fence.
create policy prospects_canvasser_read on public.prospects
  for select to authenticated
  using (auth.email() in ('divinejdavis@gmail.com', 'canvass@crease.local'));
create policy prospects_canvasser_write on public.prospects
  for update to authenticated
  using (auth.email() in ('divinejdavis@gmail.com', 'canvass@crease.local'))
  with check (auth.email() in ('divinejdavis@gmail.com', 'canvass@crease.local'));

-- Grant then let RLS refuse: a revoke from anon turns a session-refresh race
-- into a hard 42501 instead of an empty result.
grant select         on public.prospects to anon;
grant select, update on public.prospects to authenticated;
grant select, insert, update, delete on public.prospects to service_role;

notify pgrst, 'reload schema';
