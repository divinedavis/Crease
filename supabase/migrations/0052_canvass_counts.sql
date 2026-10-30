-- The canvass counters (public /public/canvass-stats tile and the owner
-- dashboard's Crease card) each ran seven separate head:true counts on
-- prospects per refresh. With the tile's 60 s cache that was ~330k count
-- queries since the stats reset on a 479-row table, most of the project's
-- PostgREST traffic (audit 2026-10-30). One function returns all seven in a
-- single scan.
--
-- Counts only, like the routes that call it: no prospect row leaves here.
-- service_role only — the dispatch service is the sole caller.

create or replace function public.canvass_counts()
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'shops',        count(*),
    'dry_cleaners', count(*) filter (where kind = 'dry_cleaner'),
    'laundromats',  count(*) filter (where kind = 'laundromat'),
    'contacted',    count(*) filter (where visited),
    'interested',   count(*) filter (where outcome = 'interested'),
    'following_up', count(*) filter (where outcome = 'follow_up'),
    'declined',     count(*) filter (where outcome = 'declined')
  )
  from public.prospects
$$;
revoke all on function public.canvass_counts() from public, anon, authenticated;
grant execute on function public.canvass_counts() to service_role;
