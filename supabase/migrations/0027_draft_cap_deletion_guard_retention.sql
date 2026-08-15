-- Seventh pass. Two of these repair fixes from the sixth that were wrong in
-- ways only live data revealed.

-- =========================================================================
-- #05 (HIGH) — the draft cap added in 0025 counts EVERY draft a customer has
-- ever left behind, and a draft is created when booking starts and only leaves
-- on successful payment. So every abandoned checkout is permanent, and two live
-- accounts (19 drafts and 10 drafts) can no longer create any order at all.
--
-- The cap was meant to stop someone spraying thousands of unpaid orders onto
-- shops' boards, and a rolling window does that just as well without punishing
-- a customer for changing their mind ten times over a fortnight.
-- =========================================================================
create or replace function public.cap_open_drafts()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_recent integer;
begin
  select count(*) into v_recent
    from public.orders
   where customer_id = new.customer_id
     and status = 'draft'
     and created_at > now() - interval '24 hours';
  if v_recent >= 15 then
    raise exception 'too many unfinished orders started today — finish or cancel one first';
  end if;
  return new;
end;
$$;

-- Abandoned drafts are not a record of anything: nobody paid, no shop ever saw
-- the bag. Sweep them so the board stays honest and the cap stays meaningful.
create or replace function public.purge_abandoned_drafts(p_days integer default 30)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  n integer;
begin
  delete from public.orders o
   where o.status = 'draft'
     and o.created_at < now() - make_interval(days => p_days)
     -- Never touch one that has a payment row: money means it is not abandoned,
     -- it is a problem, and it should surface rather than disappear.
     and not exists (select 1 from public.payments p where p.order_id = o.id);
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.purge_abandoned_drafts(integer) from public, anon, authenticated;
grant execute on function public.purge_abandoned_drafts(integer) to service_role;

-- =========================================================================
-- #15 (MEDIUM) — delete_account() deletes orders unconditionally, so a
-- customer with a bag on a shop's rack removes the shop's queue row mid-job,
-- leaves a live courier uncancelled, and erases the local record of a captured
-- charge. Refuse while anything is in flight, mirroring the staff guard that
-- is already in this function.
-- =========================================================================
create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := auth.uid();
  v_live integer;
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;

  if exists (select 1 from public.cleaner_staff cs where cs.user_id = v_user) then
    raise exception 'staff accounts must be removed by the shop owner';
  end if;

  -- An order between booking and delivery involves a shop and often a courier.
  -- Deleting it here would strand both, and destroy the only local record of a
  -- charge the customer may still want refunded.
  select count(*) into v_live
    from public.orders
   where customer_id = v_user
     and status not in ('draft', 'delivered', 'cancelled', 'failed');
  if v_live > 0 then
    raise exception 'you have % order(s) in progress — wait until they are delivered, or cancel them first', v_live;
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
-- #40 (LOW) — the courier is a third party with no account here and no way to
-- ask us for anything. Their name, phone and last position sit on the leg
-- forever. The 90-day scrub is a floor; once a leg is terminal the contact
-- details have served their entire purpose, so drop them then.
-- =========================================================================
create or replace function public.clear_courier_pii_on_terminal()
returns trigger
language plpgsql
as $$
begin
  -- Deliberately not gated on a status CHANGE: a later write to an already
  -- terminal leg (a straggling webhook, a backfill) would otherwise put the
  -- courier's number back. Any write that leaves the row terminal clears it.
  if new.status in ('delivered', 'returned', 'cancelled', 'failed') then
    new.courier_phone := null;
    new.courier_lat := null;
    new.courier_lng := null;
  end if;
  return new;
end;
$$;

drop trigger if exists delivery_legs_clear_courier_pii on public.delivery_legs;
create trigger delivery_legs_clear_courier_pii
  before update on public.delivery_legs
  for each row execute function public.clear_courier_pii_on_terminal();

-- =========================================================================
-- #39 (LOW) — orders and addresses had no retention at all. Don't delete the
-- rows (they are the business record); drop the free-text that is the actual
-- personal data long after anyone could need it.
-- =========================================================================
create or replace function public.scrub_old_order_notes(p_days integer default 365)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  n integer;
begin
  update public.orders
     set customer_notes = null,
         cleaner_notes = null
   where status in ('delivered', 'cancelled', 'failed')
     and updated_at < now() - make_interval(days => p_days)
     and (customer_notes is not null or cleaner_notes is not null);
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.scrub_old_order_notes(integer) from public, anon, authenticated;
grant execute on function public.scrub_old_order_notes(integer) to service_role;

-- NOTE on profiles.payment_customer_ref / default_payment_method_ref: the audit
-- flagged them as unused columns worth dropping. They are NOT dropped here —
-- services/dispatch/src/payments.ts selects both on every loadOrder(), so
-- dropping them breaks checkout. Left in place deliberately.
