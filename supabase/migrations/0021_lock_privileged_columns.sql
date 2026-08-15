-- Second-pass hardening: RLS WITH CHECK cannot restrict which columns an
-- authenticated client writes, and the table-wide UPDATE grants let shop staff
-- and customers overwrite money/status/payout columns. PostgreSQL cannot
-- subtract a column from a table-wide grant, so revoke the table-wide UPDATE
-- and re-grant only the columns clients legitimately edit; INSERT (order
-- creation estimates) and all service_role writes are unaffected.

-- #1 — cleaners: platform/payout columns become service_role-only.
-- Re-granted: everything the portal edits (name, contact, address, hours).
-- Withheld: commission_bps, stripe_account_id, active, payouts_enabled,
-- connect_requirements.
revoke update on public.cleaners from authenticated;
grant update (
  name, slug, phone, email, line1, line2, city, state, postal_code,
  country, lat, lng, service_radius_miles, turnaround_hours, hours
) on public.cleaners to authenticated;

-- #2 — orders: money columns become service_role-only (set at INSERT or by the
-- dispatch service). Re-granted: every non-money column, so existing client
-- updates (customer_item_count, approved_at, cleaner markCollected status,
-- draft edits) keep working. Withheld: estimate_subtotal_cents, subtotal_cents,
-- delivery_fee_cents, service_fee_cents, tax_cents, tip_cents, total_cents,
-- approval_threshold_cents.
revoke update on public.orders from authenticated;
grant update (
  id, short_code, customer_id, cleaner_id, address_id, status,
  pickup_window_start, pickup_window_end, return_window_start, return_window_end,
  approved_at, customer_notes, cleaner_notes, cancelled_reason, created_at,
  updated_at, service_tier, estimated_ready_at, ready_at, service_type,
  return_committed_at, customer_item_count, cleaner_item_count
) on public.orders to authenticated;

-- ...and a customer update can only result in an allowed status (blocks the
-- draft -> 'cleaning'/'ready' self-transition that skipped the approval charge).
alter policy orders_customer_update on public.orders
  with check (customer_id = auth.uid() and status in ('draft','awaiting_approval'));

-- #4 — role-aware staff check for owner/manager-only operations (payout
-- onboarding, and available for future sensitive policies). Membership-only
-- is_cleaner_staff stays for day-to-day order operations.
create or replace function public.is_cleaner_admin(p_cleaner uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select exists (
    select 1 from public.cleaner_staff cs
    where cs.cleaner_id = p_cleaner
      and cs.user_id = auth.uid()
      and cs.role in ('owner', 'manager')
  );
$$;
revoke all on function public.is_cleaner_admin(uuid) from public;
grant execute on function public.is_cleaner_admin(uuid) to authenticated, service_role;
