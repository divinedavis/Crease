-- The bill is derived from order_items, but order_items is client-written.
--
-- settleOrder computes the cleaning subtotal from these rows precisely so the
-- total can't be a number a client sent. That reasoning holds only if the rows
-- themselves are trustworthy — and they are not: `order_items_cleaner_write` is
-- FOR ALL to `authenticated` gated only on is_cleaner_staff, and the role holds
-- table-level INSERT/UPDATE/DELETE. A shop's own Supabase token can POST any
-- unit_price_cents, any quantity, against an order in any status.
--
-- Every protection lives in the portal's server action: the per-unit ceilings,
-- the service_type filter, prices taken from the catalogue, and the status gate.
-- The Data API is a strictly larger surface than the server action and has none
-- of them. Revoking the grant is not an option — that action IS the shop's
-- write path — so the rules move into the database, where both surfaces meet.

create or replace function public.validate_order_item()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_order   public.orders%rowtype;
  v_service public.service_items%rowtype;
begin
  select * into v_order from public.orders where id = new.order_id;
  if not found then
    raise exception 'no such order';
  end if;

  -- The service role is the dispatcher settling and reconciling; it is not a
  -- client and is not what this guards against.
  if auth.uid() is null then
    return new;
  end if;

  -- Same window the intake form is rendered in. Without it a delivered,
  -- captured order can be recounted and re-settled at a higher total.
  if v_order.status not in ('scheduled', 'at_cleaner', 'awaiting_approval', 'cleaning') then
    raise exception 'order % is % — its items can no longer be changed',
      v_order.short_code, v_order.status;
  end if;

  -- The price is the shop's published price for that service, not a number the
  -- caller chose. Also pins the item to the order's own shop and service type,
  -- so a laundry rate cannot be billed against a dry cleaning order.
  select * into v_service from public.service_items where id = new.service_item_id;
  if not found then
    raise exception 'no such service item';
  end if;
  if v_service.cleaner_id <> v_order.cleaner_id then
    raise exception 'that service belongs to a different shop';
  end if;
  if v_service.service_type <> v_order.service_type then
    raise exception 'that service is not part of this order type';
  end if;
  if new.unit_price_cents <> v_service.unit_price_cents then
    raise exception 'price must match the published price for %', v_service.label;
  end if;

  -- The ceilings the intake form already enforces, so a posted quantity cannot
  -- bill six figures or overflow numeric(8,2).
  if v_service.unit = 'pound' then
    if new.quantity > 200 then
      raise exception 'weight above the 200 lb maximum';
    end if;
  elsif new.quantity > 99 then
    raise exception 'count above the 99 piece maximum';
  end if;

  return new;
end;
$$;

drop trigger if exists order_items_validate on public.order_items;
create trigger order_items_validate
  before insert or update on public.order_items
  for each row execute function public.validate_order_item();
