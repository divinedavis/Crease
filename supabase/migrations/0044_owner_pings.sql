-- Stop the demand tiles counting the person building the site.
--
-- On the day this was written the dashboard read "6 addresses checked · 67%
-- inside the courier band", and all six rows were the owner's: five typed into
-- a desktop over ten minutes (251 Dekalb, then 299 Ashford), one from his
-- phone two hours later. The nginx log for creasenyc.com holds exactly
-- thirteen /api/address requests for that period and every one came from those
-- two devices. The tile was a man testing his own site, reported back to him
-- as demand — and demand is the number this business is being steered by.
--
-- The traffic tile already had an answer for this: /?owner=1 leaves a cookie,
-- the cookie re-registers the address from every network the device joins, and
-- the nginx counter skips it. This carries the same mark one layer down, to
-- the rows the site itself writes.

alter table public.demand_pings
  add column if not exists owner boolean not null default false;
comment on column public.demand_pings.owner is
  'Written by a device marked with /?owner=1. Excluded from every demand tile.';

alter table public.pickup_requests
  add column if not exists owner boolean not null default false;
comment on column public.pickup_requests.owner is
  'Written by a device marked with /?owner=1. Excluded from the request tiles.';

-- The backfill, bounded by the timestamp of the last of those six rows rather
-- than left open: anything arriving after this migration is somebody else
-- until their own browser says otherwise.
update public.demand_pings
   set owner = true
 where created_at <= '2026-08-19T02:00:00Z';
update public.pickup_requests
   set owner = true
 where created_at <= '2026-08-19T02:00:00Z';

-- Every demand query is "not the owner, since a date".
create index if not exists demand_pings_real_idx
  on public.demand_pings(created_at desc) where not owner;
create index if not exists pickup_requests_real_idx
  on public.pickup_requests(created_at desc) where not owner;

-- A column that hides a row from the dashboard must not be writable by the
-- public. anon has held INSERT on both tables since they were created, from a
-- design where the browser wrote its own rows; it does not — every write goes
-- through a server action holding the service role, and no browser client in
-- this repo touches either table. Left in place, that grant now lets anyone
-- insert home addresses into the tables the dashboard reads as demand and
-- stamp owner on them to vanish from it.
drop policy if exists demand_pings_public_insert on public.demand_pings;
drop policy if exists pickup_requests_public_insert on public.pickup_requests;
revoke insert on public.demand_pings from anon, authenticated;
revoke insert on public.pickup_requests from anon;

-- Restated rather than assumed: a migration that revokes should say what is
-- left standing. Shop staff keep the reads and updates their policies gate.
grant select, insert, update, delete on public.demand_pings to service_role;
grant select, insert, update, delete on public.pickup_requests to service_role;
grant select, update on public.pickup_requests to authenticated;

notify pgrst, 'reload schema';
