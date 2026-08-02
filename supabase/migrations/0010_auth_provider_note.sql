-- Not a schema change: a record of an auth-config setting that lives outside
-- the database and has bitten this codebase before.
--
-- Supabase projects start with the Apple provider DISABLED. Native
-- signInWithIdToken fails until it is enabled with the iOS bundle id as the
-- client id — no Services ID, no .p8, those are only for the web OAuth flow.
--
--   curl -X PATCH "https://api.supabase.com/v1/projects/<ref>/config/auth" \
--     -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
--     -H "Content-Type: application/json" \
--     -d '{"external_apple_enabled": true,
--          "external_apple_client_id": "com.divinedavis.crease"}'
--
-- Applied 2026-08-02. The failure it causes is confusing: Apple's own sheet
-- reports "Sign Up Not Completed", which reads like a provisioning problem
-- rather than a backend setting.

select 1;
