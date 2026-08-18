-- Let the customer say which service they are buying.
--
-- 0022 locked orders INSERT to an explicit column list, which is the right
-- shape and caught this the first time the app tried: service_type was never
-- in it, so a booking that named its service was refused outright. The column
-- has existed since 0014 and has only ever been set by the default, meaning
-- every order ever placed claimed to be dry cleaning — including the laundry
-- ones, which then quoted a 48-hour turnaround for a two-hour wash and drew
-- their price from the wrong half of the shop's list.
--
-- Granted with a check rather than on trust: an order may only name a service
-- the chosen shop actually publishes a live price for. Without it a customer
-- could book a press at a shop that does not press, and the first anyone would
-- know is a counter holding a bag it has no price for.

grant insert (service_type) on public.orders to authenticated;

alter policy orders_customer_insert on public.orders
  with check (
    customer_id = auth.uid()
    and status = 'draft'
    and exists (select 1 from public.cleaners c where c.id = cleaner_id and c.active)
    and exists (select 1 from public.addresses a where a.id = address_id and a.user_id = auth.uid())
    and exists (
      select 1 from public.service_items si
      where si.cleaner_id = orders.cleaner_id
        and si.service_type = orders.service_type
        and si.active
    )
  );

notify pgrst, 'reload schema';
