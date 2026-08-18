-- The canvass list was built when Brooklyn was the whole plan, so the borough
-- was implicit in every row. The expansion roadmap needs it explicit: phase
-- progress is "how much of THIS market is canvassed", and a page that has to
-- infer that from a nullable ZIP silently drops every row whose ZIP OSM never
-- carried.
--
-- Default 'Brooklyn' because that is literally what all 479 existing rows are.
-- The check list is the roadmap's markets plus the Bronx — not on the plan,
-- but a NYC canvass list that cannot hold a Bronx row is a trap for whoever
-- seeds one.

alter table public.prospects
  add column borough text not null default 'Brooklyn'
  check (borough in ('Brooklyn', 'Manhattan', 'Queens', 'Staten Island', 'Bronx', 'New Jersey'));

-- Every roadmap read is "count this borough", and the canvass tool scopes its
-- list the same way once a second market is seeded.
create index prospects_borough_idx on public.prospects(borough);

-- Table-level grants already cover a new column, but re-issuing is how this
-- schema states intent: the canvasser reads and edits the list, and borough is
-- seed-derived rather than something to fix at a counter — it stays inside the
-- existing UPDATE grant only because the RLS policy already narrows every
-- write on this table to the founder's own account.
grant select, update on public.prospects to authenticated;
grant select, insert, update, delete on public.prospects to service_role;

notify pgrst, 'reload schema';
