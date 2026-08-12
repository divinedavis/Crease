-- Whether a laundromat actually takes drop-off work, which is the question
-- that decides if it can be a Crease partner at all. Three-valued on
-- purpose: true (staff take bags), false (coin machines only), and null —
-- unknown until someone asks at the counter. OSM answers it for about a
-- third of them; the canvasser's thumb answers the rest.
-- Dry cleaners stay null: full service is what a dry cleaner is.

alter table public.prospects add column full_service boolean;

notify pgrst, 'reload schema';
