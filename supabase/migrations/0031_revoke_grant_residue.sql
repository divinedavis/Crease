-- Migration 0022 set out to remove privileges that were "inert today (RLS
-- denies) but one policy slip from catastrophe". It stopped short of these.
--
-- Each revoke below was checked against the policies that actually exist: a
-- privilege is only removed where NO policy grants that command, so the role
-- cannot be using it today. Anything with a live policy — addresses,
-- device_tokens, order_items, profiles, service_items — is left alone.

-- TRUNCATE is the sharpest of the set and the least defensible. RLS does not
-- apply to TRUNCATE at all, so unlike the others these are not "inert because
-- RLS denies" — they are inert only because PostgREST happens to expose no
-- verb for it. Nothing in this system truncates anything.
revoke truncate on all tables in schema public from authenticated;
revoke truncate on all tables in schema public from anon;

-- Supabase's default GRANT ALL, never asked for by a migration and matched by
-- no policy:
--   cleaners  — a customer creating or deleting a shop
--   orders    — no DELETE policy exists; orders are ended by status, never removed
--   prospects — the canvassing tool only reads and updates (policies confirm it)
revoke delete on public.cleaners, public.orders, public.prospects from authenticated;
revoke insert on public.cleaners, public.prospects from authenticated;

-- And stop the same residue arriving on the next table someone creates.
alter default privileges in schema public
  revoke truncate on tables from authenticated, anon;
