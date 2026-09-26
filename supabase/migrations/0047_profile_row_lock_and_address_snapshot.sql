-- Close two holes from the 2026-09-25 audit.

-- ---------------------------------------------------------------------------
-- 1. profiles: no client INSERT or DELETE
-- ---------------------------------------------------------------------------
-- 0032 column-locked UPDATE on profiles to four columns, but the table-wide
-- INSERT and DELETE grants from Supabase's defaults were never touched, and
-- profiles_self is `for all ... with check (id = auth.uid())`. So a customer
-- could DELETE their own row and INSERT it back with is_review_account = true
-- (orders routed to the simulated carrier) or with someone else's Stripe
-- customer id — every column the UPDATE lock protects, set on the way back in.
--
-- Nothing on the client side needs either privilege:
--   * the row is created by handle_new_user() (SECURITY DEFINER, trigger
--     on_auth_user_created on auth.users) at signup;
--   * the row is removed by delete_account() (SECURITY DEFINER);
--   * the iOS app only SELECTs and UPDATEs (phone); web and portal never write
--     profiles; scripts/seed.mjs upserts with the service role.
revoke insert, delete on public.profiles from authenticated, anon;

-- ---------------------------------------------------------------------------
-- 2. orders.address_snapshot: where the courier goes is fixed at checkout
-- ---------------------------------------------------------------------------
-- addresses stays fully customer-writable (the app legitimately folds a moved
-- pin and new door notes back into a saved row on the next booking), and the
-- dispatcher used to re-read the live row for every leg. So a customer could
-- pass the 3-mile check at payment, then rewrite the saved address to anywhere
-- and have the courier sent there.
--
-- The dispatcher now copies the address onto the order at payment-intent,
-- in the same request that checks the service area, and every leg reads the
-- copy. Service-role only: no grant to authenticated (orders INSERT/UPDATE are
-- column grants since 0021, so a new column is unwritable by default; the
-- revoke below states it so a future table-wide grant cannot pick it up).
alter table public.orders
  add column if not exists address_snapshot jsonb;

comment on column public.orders.address_snapshot is
  'The pickup/return address as it stood when payment was started. Couriers are dispatched to this, not to the live addresses row. Written by the dispatcher (service role) only.';

revoke insert (address_snapshot), update (address_snapshot) on public.orders from authenticated, anon;

-- Orders already paid for and still moving get the address they have now, so
-- the hole is closed for them too rather than only for orders booked from here.
update public.orders o
   set address_snapshot = jsonb_build_object(
         'id', a.id, 'label', a.label, 'line1', a.line1, 'line2', a.line2,
         'city', a.city, 'state', a.state, 'postal_code', a.postal_code,
         'access_notes', a.access_notes, 'lat', a.lat, 'lng', a.lng)
  from public.addresses a
 where a.id = o.address_id
   and o.address_snapshot is null
   and o.status not in ('draft', 'delivered', 'cancelled');

notify pgrst, 'reload schema';
