-- Sixth pass: PII retention beyond delivery_events, and a ceiling on unpaid
-- drafts.

-- =========================================================================
-- #10 — Only delivery_events had a purge. Orders keep the customer's address
-- and the courier's phone forever, and the courier is a third party with no
-- account and no way to ask. Scrub the leg PII once an order is finished and
-- the window for a dispute has passed; keep the row itself, because the
-- operational history (which leg, which status, what it cost) is what
-- reconstructs a delivery months later.
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
     set dropoff_phone = null,
         dropoff_address = null,
         dropoff_lat = null,
         dropoff_lng = null,
         dropoff_pincode = null,
         pickup_phone = null,
         courier_phone = null,
         courier_lat = null,
         courier_lng = null
    from public.orders o
   where l.order_id = o.id
     and o.status in ('delivered', 'cancelled', 'failed')
     and l.updated_at < now() - make_interval(days => p_days)
     -- Only rows that still hold something, so the job is cheap on repeat runs.
     and (l.dropoff_phone is not null or l.dropoff_address is not null
          or l.courier_phone is not null or l.dropoff_pincode is not null);
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.scrub_finished_leg_pii(integer) from public, anon, authenticated;
grant execute on function public.scrub_finished_leg_pii(integer) to service_role;

-- Notification history is a delivery log, not a record anyone needs a year on.
create or replace function public.purge_notifications_sent(p_days integer default 90)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  n integer;
begin
  delete from public.notifications_sent
   where sent_at < now() - make_interval(days => p_days);
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.purge_notifications_sent(integer) from public, anon, authenticated;
grant execute on function public.purge_notifications_sent(integer) to service_role;

-- =========================================================================
-- #7 — Nothing caps order creation. Any authenticated user can insert
-- unlimited unpaid drafts naming any active shop, and they land on that shop's
-- board. Cap the number of open drafts per customer; a real customer never has
-- more than one or two in flight.
--
-- A trigger rather than a policy predicate: the INSERT policy is already doing
-- ownership, status and FK-validity work, and a counting subquery there is
-- easy to misread as a security check when it is really a quota.
-- =========================================================================
create or replace function public.cap_open_drafts()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_open integer;
begin
  select count(*) into v_open
    from public.orders
   where customer_id = new.customer_id
     and status = 'draft';
  if v_open >= 10 then
    raise exception 'too many unpaid orders open — finish or cancel one first';
  end if;
  return new;
end;
$$;

drop trigger if exists orders_cap_open_drafts on public.orders;
create trigger orders_cap_open_drafts
  before insert on public.orders
  for each row execute function public.cap_open_drafts();
