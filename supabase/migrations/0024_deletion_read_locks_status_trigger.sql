-- Fifth-pass hardening: account deletion, read-side PII locks, and a trigger
-- that stops a customer driving their own order's status.

-- =========================================================================
-- #3 (HIGH) — There is no account-deletion path, and the FK graph makes one
-- impossible from the platform side: orders.customer_id -> profiles RESTRICT
-- and payouts.order_id -> orders RESTRICT mean even the dashboard's "delete
-- user" fails for anyone who has ever ordered. That blocks GDPR/CCPA erasure
-- and App Store guideline 5.1.1(v).
--
-- Deletes in FK order: payouts -> orders (cascades delivery_legs, order_items,
-- payments, notifications_sent) -> addresses -> profiles -> auth.users.
-- Payout rows are removed rather than kept: Stripe is the authoritative record
-- of every transfer, so the local copy is a convenience, not the ledger.
-- =========================================================================
create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;

  -- A shop owner's account cannot be self-deleted: the shop's orders, staff and
  -- payouts belong to the business, not the person, and removing them here
  -- would take other people's records with it.
  if exists (select 1 from public.cleaner_staff cs where cs.user_id = v_user) then
    raise exception 'staff accounts must be removed by the shop owner';
  end if;

  delete from public.payouts p
    using public.orders o
    where p.order_id = o.id and o.customer_id = v_user;

  delete from public.orders where customer_id = v_user;
  delete from public.addresses where user_id = v_user;
  delete from public.profiles where id = v_user;
  delete from auth.users where id = v_user;
end;
$$;
revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

-- =========================================================================
-- #5 (HIGH) — cleaners_read is USING (active), i.e. every ACTIVE shop, not the
-- shops you staff. So any signed-up account (signups are open) could read every
-- shop's Stripe Connect account id and contact email. 0023 kept those columns
-- granted on the false premise that RLS scoped the rows to your own shop.
--
-- The portal reads payout status through shop_payout_status() below instead.
-- phone/address stay readable: the customer app shows the shop's contact card.
-- =========================================================================
revoke select on public.cleaners from authenticated;
grant select (
  id, name, slug, phone, email, line1, line2, city, state, postal_code,
  country, lat, lng, service_radius_miles, turnaround_hours, hours,
  active, created_at
) on public.cleaners to authenticated;

-- Staff-scoped payout status, so the settings page keeps working without
-- handing the Connect account id to every authenticated user.
create or replace function public.shop_payout_status(p_cleaner uuid)
returns table (has_account boolean, payouts_enabled boolean)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select (c.stripe_account_id is not null), coalesce(c.payouts_enabled, false)
  from public.cleaners c
  where c.id = p_cleaner and public.is_cleaner_staff(c.id);
$$;
revoke all on function public.shop_payout_status(uuid) from public, anon;
grant execute on function public.shop_payout_status(uuid) to authenticated;

-- =========================================================================
-- #6 (HIGH) — delivery_legs denormalises the customer's home address and phone,
-- plus the courier's phone and live GPS, and delivery_legs_read exposes every
-- column to shop staff — bypassing the addresses lockdown, from quote time,
-- forever. Neither client reads these columns (verified against the iOS
-- DeliveryLeg model and the portal's leg select), so revoke them.
--
-- dropoff_pincode stays granted because the customer app displays it; splitting
-- it away from shop staff needs an API change (both are the `authenticated`
-- role), so that residue is tracked separately.
-- =========================================================================
revoke select on public.delivery_legs from authenticated;
grant select (
  id, order_id, leg, attempt, status, provider, provider_delivery_id,
  provider_status, tracking_url, fee_cents, quoted_at, quote_expires_at,
  courier_name, courier_vehicle, dropoff_pincode,
  dispatched_at, picked_up_at, completed_at, last_error, created_at, updated_at
) on public.delivery_legs to authenticated;

-- =========================================================================
-- #9 (MEDIUM) — orders_customer_update permits any status within
-- {draft, awaiting_approval} in BOTH directions, so a customer can walk an
-- order back to draft: the approval charge can then never be claimed (its
-- atomic gate looks for 'awaiting_approval'), and every draft-only mutation
-- reopens mid-lifecycle. A policy cannot compare NEW.status to OLD.status, so
-- enforce the transition in a trigger.
--
-- Shop staff still drive status (intake, ready, collected); the service role
-- bypasses this entirely. Only the customer path is frozen — the app never
-- legitimately writes status, it signals approval via approved_at.
-- =========================================================================
create or replace function public.forbid_customer_status_change()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if new.status is distinct from old.status
     and auth.uid() = old.customer_id
     and not public.is_cleaner_staff(old.cleaner_id) then
    raise exception 'order status is set by Crease, not by the customer';
  end if;
  return new;
end;
$$;

drop trigger if exists orders_forbid_customer_status on public.orders;
create trigger orders_forbid_customer_status
  before update on public.orders
  for each row execute function public.forbid_customer_status_change();

-- Identity and pricing columns a client never legitimately rewrites. Dropping
-- service_tier here is the root fix for the tier-swap-after-payment hole (the
-- dispatcher also re-asserts the paid tier before dispatching).
revoke update on public.orders from authenticated;
grant update (
  status, pickup_window_start, pickup_window_end,
  return_window_start, return_window_end, approved_at,
  customer_notes, cleaner_notes, cancelled_reason, updated_at,
  estimated_ready_at, ready_at, return_committed_at,
  customer_item_count, cleaner_item_count
) on public.orders to authenticated;

-- =========================================================================
-- #12 (LOW, privacy audit) — anon has no policy on these, so RLS denies today,
-- but the grants shouldn't be the only thing between anon and 479 canvassed
-- businesses if a policy is ever added. service_items stays: the public menu.
-- =========================================================================
revoke select on public.prospects from anon;
