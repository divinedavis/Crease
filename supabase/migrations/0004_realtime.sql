-- The portal board must move on its own: couriers change state while the
-- tablet sits untouched on the counter, and a stale board means a shop pulls
-- the wrong bag. Realtime only announces that a row changed — RLS still
-- decides what each shop may actually read back.

alter publication supabase_realtime add table public.orders;
alter publication supabase_realtime add table public.delivery_legs;
