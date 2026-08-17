-- The one money table the column-locking passes never reached.
--
-- Every other table that carries money or identity was column-locked in
-- 0021/0022/0024/0025/0031, because a Postgres RLS policy checks the ROW but
-- cannot restrict which COLUMNS a write touches — an ownership-only policy plus
-- a table-wide UPDATE grant lets a user rewrite any column of their own row.
-- profiles kept a full-table UPDATE grant against exactly such a policy
-- (profiles_self, USING id = auth.uid()), and two of its columns are Stripe
-- references the dispatcher charges against:
--
--   payment_customer_ref        -> Stripe customer for authorize/capture
--   default_payment_method_ref  -> the saved card charged off-session
--
-- A user could UPDATE their own row to point these at another account's Stripe
-- ids and have their next order charge the victim's card. It is latent today
-- (both columns are NULL for every profile — no code path writes them yet, the
-- saved-card flow is unshipped) which is precisely why this is the moment to
-- lock it: closing it before the feature goes live costs nothing and needs no
-- client change, whereas closing it after means a coordinated rollout.
--
-- id/created_at/updated_at were also in the grant and have no business being
-- client-writable: id is the identity the policy keys on, and updated_at is
-- maintained by the touch_updated_at BEFORE trigger (which sets NEW without
-- needing a column grant).

revoke update on public.profiles from authenticated;

-- Re-grant only what a person legitimately edits about themselves. When the
-- saved-card feature ships, the dispatcher (service_role, which keeps its full
-- grant) writes the two refs — never the client.
grant update (full_name, phone, avatar_url, default_address_id)
  on public.profiles to authenticated;
