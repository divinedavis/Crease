-- Third-pass hardening from the 5-subsystem audit. Closes the CRITICAL
-- prospects hole, the INSERT/UPDATE grant gaps 0021 missed, the cleaner status
-- write surface, and the authenticated/anon grant drift.

-- =========================================================================
-- Auth #1 (CRITICAL) — prospects authorized by a CLAIMABLE sentinel email.
-- Open signup + autoconfirm let anyone register 'canvass@crease.local' and
-- read/tamper all prospect PII. Drop the claimable address; keep only the
-- owner's real (already-registered, unclaimable) account.
-- =========================================================================
alter policy prospects_canvasser_read on public.prospects
  using (auth.email() = 'divinejdavis@gmail.com');
alter policy prospects_canvasser_write on public.prospects
  using (auth.email() = 'divinejdavis@gmail.com')
  with check (auth.email() = 'divinejdavis@gmail.com');

-- =========================================================================
-- Auth #2 / Payments #2 (HIGH) — orders INSERT was never column-locked, so a
-- customer could create an order in any status, for any cleaner, with any
-- money values. Lock INSERT to exactly the fields the app sends, pin the
-- status to 'draft', require an active cleaner and a self-owned address, and
-- forbid negative money.
-- =========================================================================
revoke insert on public.orders from authenticated;
grant insert (
  customer_id, cleaner_id, address_id, status,
  estimate_subtotal_cents, delivery_fee_cents, service_tier,
  pickup_window_start, pickup_window_end, customer_notes, customer_item_count
) on public.orders to authenticated;

alter policy orders_customer_insert on public.orders
  with check (
    customer_id = auth.uid()
    and status = 'draft'
    and exists (select 1 from public.cleaners c where c.id = cleaner_id and c.active)
    and exists (select 1 from public.addresses a where a.id = address_id and a.user_id = auth.uid())
  );

-- Payments #1 / Auth #7 (HIGH/LOW) — cleaner_id was re-granted for UPDATE in
-- 0021, letting a customer repoint a draft to a colluding shop (payout
-- redirect) or an arbitrary address. The app never updates these post-create.
revoke update (cleaner_id, address_id) on public.orders from authenticated;

-- Defense-in-depth: money columns can never go negative (blocks under-charge /
-- negative-hold shaping). NOT VALID enforces on new/updated rows without
-- risking existing-row validation.
alter table public.orders
  add constraint orders_money_nonneg check (
    estimate_subtotal_cents >= 0 and delivery_fee_cents >= 0 and
    coalesce(subtotal_cents,0) >= 0 and coalesce(total_cents,0) >= 0 and
    coalesce(service_fee_cents,0) >= 0 and coalesce(tax_cents,0) >= 0 and
    coalesce(tip_cents,0) >= 0 and coalesce(approval_threshold_cents,0) >= 0
  ) not valid;

-- =========================================================================
-- Dispatch #6 (MEDIUM) — orders_cleaner_update had no status whitelist, so a
-- shop token could force 'cancelled'/'failed' (or any state) directly. Allow
-- the operational statuses a shop legitimately reaches; keep cancel/fail (and
-- the void/refund-adjacent flow) service-role-only.
-- =========================================================================
alter policy orders_cleaner_update on public.orders
  with check (
    is_cleaner_staff(cleaner_id)
    and status in (
      'scheduled','pickup_dispatched','in_transit_to_cleaner','at_cleaner',
      'awaiting_approval','cleaning','ready','return_dispatched',
      'in_transit_to_customer','delivered'
    )
  );

-- =========================================================================
-- Auth #4/#5 (MEDIUM) — Supabase default-privilege drift left authenticated
-- with write DML and anon with SELECT on tables the migrations never granted.
-- Inert today (RLS denies) but one policy/RLS slip from catastrophe. Restore
-- least privilege.
-- =========================================================================
revoke insert, update, delete on
  public.cleaner_staff, public.delivery_legs, public.payments,
  public.payouts, public.delivery_events, public.notifications_sent
  from authenticated;
revoke insert, update on public.device_tokens from authenticated;  -- keep SELECT+DELETE

revoke select on
  public.addresses, public.cleaner_staff, public.cleaners, public.delivery_events,
  public.delivery_legs, public.device_tokens, public.notifications_sent,
  public.order_items, public.orders, public.payments, public.payouts, public.profiles
  from anon;  -- anon keeps SELECT only on service_items (public menu) and prospects
