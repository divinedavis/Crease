-- is_crease_admin() is a helper, not an endpoint.
--
-- 0055 granted EXECUTE on it to `authenticated`, which made it callable by
-- any signed-in user at /rest/v1/rpc/is_crease_admin. Nothing calls it that
-- way: no page, no app, no policy. Its only callers are create_shop_invite(),
-- list_shop_invites() and approve_shop(), and those are SECURITY DEFINER, so
-- the check inside them runs as the function owner and needs no grant to the
-- caller. The weekly Supabase security check flagged it on 2026-11-23.
--
-- All a signed-in user could learn from it was whether they themselves are an
-- admin, so this closes a door nobody needs rather than a leak. The three
-- founder functions keep their grant: the canvass page calls them with the
-- founder's own session, and each one refuses anyone who is not in
-- crease_admins before it does anything else.

revoke all on function public.is_crease_admin() from public, anon, authenticated;
grant execute on function public.is_crease_admin() to service_role;

notify pgrst, 'reload schema';
