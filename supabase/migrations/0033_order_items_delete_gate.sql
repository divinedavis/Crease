-- 0029 pinned order_items prices and closed the intake status window against
-- INSERT and UPDATE, but the trigger is BEFORE INSERT OR UPDATE only — DELETE
-- was left wide open. A shop's own token holds table DELETE on order_items
-- (it needs it: the portal's saveIntake replaces the line set with
-- delete-by-order then re-insert), so nothing stopped that same token from
-- deleting the lines off a delivered, captured, or disputed order — erasing the
-- intake-photo rows the schema calls the biggest liability in the business, or
-- reshaping the bill for a re-settlement.
--
-- The fix is the same status window as INSERT/UPDATE, applied to DELETE. The
-- legitimate intake delete happens while the order is still in that window, so
-- it is unaffected; a delete once the order has left the window is refused.
-- The dispatcher (service_role, auth.uid() null) is never gated.

create or replace function public.validate_order_item()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_order   public.orders%rowtype;
  v_service public.service_items%rowtype;
  v_row     public.order_items%rowtype := case when tg_op = 'DELETE' then old else new end;
begin
  select * into v_order from public.orders where id = v_row.order_id;
  if not found then
    -- The parent order is already gone (e.g. a draft purge cascading): there is
    -- nothing left to protect, so let the row delete rather than wedge the cascade.
    if tg_op = 'DELETE' then
      return old;
    end if;
    raise exception 'no such order';
  end if;

  -- The service role is the dispatcher settling and reconciling; not a client.
  if auth.uid() is null then
    return v_row;
  end if;

  -- Same window the intake form is rendered in — now enforced on removal too, so
  -- a delivered, captured order's lines cannot be deleted out from under it.
  if v_order.status not in ('scheduled', 'at_cleaner', 'awaiting_approval', 'cleaning') then
    raise exception 'order % is % — its items can no longer be changed',
      v_order.short_code, v_order.status;
  end if;

  -- Nothing further to validate on the way out.
  if tg_op = 'DELETE' then
    return old;
  end if;

  -- The price is the shop's published price for that service, not a number the
  -- caller chose. Also pins the item to the order's own shop and service type.
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

  -- The ceilings the intake form already enforces.
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
  before insert or update or delete on public.order_items
  for each row execute function public.validate_order_item();
