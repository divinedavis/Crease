-- Let the customer say what is in the bag before it leaves the house.
--
-- Until now only shop staff could write order_items, so the app had no way to
-- send a list and no way to price one: it inserted estimate_subtotal_cents = 0
-- and the hold came out at delivery + fees + $15 of headroom. Against a median
-- dry cleaning bill that headroom is nothing, so effectively every order
-- tripped 'awaiting_approval' and asked the customer to approve a price after
-- their clothes had already gone. The approval gate was built as the exception
-- and had quietly become the default path.
--
-- Two changes, both narrow:
--
--   * A customer may write items on their OWN order while it is still a draft.
--     Nothing about the money is taken on trust: the existing validate trigger
--     already pins unit_price_cents to the shop's published price, refuses an
--     item belonging to another shop, refuses one that is not the order's own
--     service type, and caps quantity. A forged line fails at the trigger, not
--     at the till.
--   * The trigger's status window gains 'draft'. It was written for the
--     intake form, which never sees a draft, so a customer-declared list was
--     refused by the very rule that makes it safe.
--
-- The declaration is not a bill. The shop still counts the bag and replaces
-- the list at intake; this only decides how big a hold to place and what the
-- counter sees when the bag lands.

create policy order_items_customer_write on public.order_items
  for all to authenticated
  using (
    exists (
      select 1 from public.orders o
      where o.id = order_id and o.customer_id = auth.uid() and o.status = 'draft'
    )
  )
  with check (
    exists (
      select 1 from public.orders o
      where o.id = order_id and o.customer_id = auth.uid() and o.status = 'draft'
    )
  );

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

  -- 'draft' is the customer declaring what they are sending; the rest is the
  -- intake form. Past those the bill is settled and the lines are evidence.
  if v_order.status not in ('draft', 'scheduled', 'at_cleaner', 'awaiting_approval', 'cleaning') then
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

notify pgrst, 'reload schema';
