-- What the grant table said about pickup_requests, checked while adding the
-- owner column beside it.
--
--   anon           SELECT
--   authenticated  SELECT, INSERT, UPDATE, DELETE
--
-- The table holds a name, a phone number, an email and a home address for
-- everyone who has asked to be collected from. anon was never granted SELECT
-- by any migration — Supabase grants the public roles everything on a new
-- table in `public` by default, and 0041 only ever added to that. Row level
-- security is on and no policy admits anon, so nothing leaks today; it leaks
-- the first time somebody writes a permissive policy for a different reason
-- and does not realise the grant beneath it is open.
--
-- Staff need to read the requests addressed to their own shop and mark them
-- contacted or booked. That is SELECT and UPDATE, both already gated by
-- is_cleaner_staff(). Nothing in this repo inserts or deletes as either public
-- role: the pickup form writes through a server action holding the service
-- role, and the portal never touches this table.

revoke select on public.pickup_requests from anon;
revoke insert, delete on public.pickup_requests from authenticated;

-- Said out loud, so the next reader of this file does not have to query for it.
grant select, update on public.pickup_requests to authenticated;
grant select, insert, update, delete on public.pickup_requests to service_role;

notify pgrst, 'reload schema';
