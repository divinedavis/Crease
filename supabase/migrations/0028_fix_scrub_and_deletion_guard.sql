-- Eighth pass. Both of these repair migrations of mine from the seventh that
-- were wrong in ways only a live run revealed.

-- =========================================================================
-- scrub_finished_leg_pii (0025) writes NULL into delivery_legs.dropoff_address,
-- which is NOT NULL. Every row it matches raises 23502 and the whole function
-- aborts. It has never fired only because the predicate needs rows older than
-- 90 days and the oldest leg is from 2026-08-01 — so this was set to start
-- failing at the end of October, printing one line into a log nobody reads
-- while the PII it exists to remove quietly stayed.
--
-- Redact rather than null: the address columns are NOT NULL because a leg
-- without a destination is meaningless as a record, and that is still true
-- after the personal part is gone. Also scrub pickup_address, which the
-- original missed — on a return leg that is the customer's home.
-- =========================================================================
create or replace function public.scrub_finished_leg_pii(p_days integer default 90)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  n integer;
begin
  update public.delivery_legs l
     set dropoff_address = '[redacted]',
         pickup_address = '[redacted]',
         dropoff_phone = null,
         dropoff_lat = null,
         dropoff_lng = null,
         dropoff_pincode = null,
         pickup_phone = null,
         pickup_lat = null,
         pickup_lng = null,
         courier_phone = null,
         courier_lat = null,
         courier_lng = null
    from public.orders o
   where l.order_id = o.id
     and o.status in ('delivered', 'cancelled', 'failed')
     and l.updated_at < now() - make_interval(days => p_days)
     and l.dropoff_address <> '[redacted]';
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.scrub_finished_leg_pii(integer) from public, anon, authenticated;
grant execute on function public.scrub_finished_leg_pii(integer) to service_role;

-- =========================================================================
-- delete_account's in-flight guard (0027) is blocking 100% of real customers:
-- both live accounts hold orders at at_cleaner / cleaning / ready, and the
-- message tells them to "cancel them first" when the cancel route refuses
-- every one of those statuses. That is an App Store 5.1.1(v) failure — the
-- deletion path exists but nobody can reach it.
--
-- Narrow the block to the states where a courier is genuinely moving or money
-- is mid-flight, and let the rest through. A bag sitting on a shop's rack is a
-- reason to warn, not a reason to trap someone in an account forever.
-- =========================================================================
create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := auth.uid();
  v_moving integer;
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;

  if exists (select 1 from public.cleaner_staff cs where cs.user_id = v_user) then
    raise exception 'staff accounts must be removed by the shop owner';
  end if;

  -- Only the states a customer can actually resolve, or that have a courier on
  -- the road right now. Everything else is the shop's to finish.
  select count(*) into v_moving
    from public.orders
   where customer_id = v_user
     and status in ('pickup_dispatched', 'in_transit_to_cleaner',
                    'return_dispatched', 'in_transit_to_customer');
  if v_moving > 0 then
    raise exception 'a courier is on the way for % of your orders — please wait until they arrive', v_moving;
  end if;

  -- Everything else goes with the account. Detaching the order instead would be
  -- kinder to the shop, but orders.customer_id and orders.address_id are both
  -- NOT NULL and the addresses are deleted here too — so a detached row cannot
  -- exist without a schema change. Erasure wins over the queue row; the shop
  -- keeps its payout history via Stripe, which is the record that matters.
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
