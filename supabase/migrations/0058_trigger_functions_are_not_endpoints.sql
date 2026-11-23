-- Close the function grants nobody uses.
--
-- The weekly Supabase security check lists every function a client role can
-- reach through /rest/v1/rpc. Reviewed 2026-11-23, three groups were open
-- for no reason:
--
--   1. Trigger functions. Postgres gives every new function EXECUTE to PUBLIC,
--      so all six were "callable" by anon and authenticated. A trigger does
--      not need that: the privilege is checked when the trigger is created,
--      not when it fires (proved on this database with a throwaway table: a
--      role with no EXECUTE on the function still had its insert stamped by
--      the trigger). Calling one directly only ever errors, but there is no
--      reason to leave the door there.
--
--   2. touch_updated_at() and clear_courier_pii_on_terminal() had no pinned
--      search_path. Neither names a table, so nothing could be redirected
--      today; pinning it keeps that true if a later edit adds one.
--
--   3. is_cleaner_staff() / is_cleaner_admin() were open to signed-out
--      callers. Every policy that uses them is for `authenticated`, the two
--      functions that call them are SECURITY DEFINER, and signed out they can
--      only answer false. `authenticated` keeps its grant: fourteen policies
--      and the portal's Settings page depend on it.
--
-- Left as they are, on purpose: delete_account() (the app's Delete account,
-- acts only on the caller), order_photo_count() (the photo-upload policy
-- needs it), shop_payout_status() (answers only for the caller's own shop).

alter function public.touch_updated_at() set search_path = public, pg_temp;
alter function public.clear_courier_pii_on_terminal() set search_path = public, pg_temp;

revoke all on function public.touch_updated_at() from public, anon, authenticated;
revoke all on function public.clear_courier_pii_on_terminal() from public, anon, authenticated;
revoke all on function public.cap_open_drafts() from public, anon, authenticated;
revoke all on function public.forbid_customer_status_change() from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.validate_order_item() from public, anon, authenticated;

revoke all on function public.is_cleaner_staff(uuid) from public, anon;
revoke all on function public.is_cleaner_admin(uuid) from public, anon;
grant execute on function public.is_cleaner_staff(uuid) to authenticated, service_role;
grant execute on function public.is_cleaner_admin(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
