-- crease: wrap auth.*() in (select ...) so RLS evaluates it once per
-- query, not once per row (advisor auth_rls_initplan). Same predicates.
-- Generated from live pg_policies 2026-10-30.

alter policy "profiles_self" on public."profiles"
  using ((id = ( SELECT auth.uid() AS uid)))
  with check ((id = ( SELECT auth.uid() AS uid)));

alter policy "addresses_self" on public."addresses"
  using ((user_id = ( SELECT auth.uid() AS uid)))
  with check ((user_id = ( SELECT auth.uid() AS uid)));

alter policy "cleaner_staff_self" on public."cleaner_staff"
  using ((user_id = ( SELECT auth.uid() AS uid)));

alter policy "orders_customer_read" on public."orders"
  using ((customer_id = ( SELECT auth.uid() AS uid)));

alter policy "order_items_read" on public."order_items"
  using ((EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = order_items.order_id) AND ((o.customer_id = ( SELECT auth.uid() AS uid)) OR is_cleaner_staff(o.cleaner_id))))));

alter policy "delivery_legs_read" on public."delivery_legs"
  using ((EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = delivery_legs.order_id) AND ((o.customer_id = ( SELECT auth.uid() AS uid)) OR is_cleaner_staff(o.cleaner_id))))));

alter policy "payments_read" on public."payments"
  using ((EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = payments.order_id) AND (o.customer_id = ( SELECT auth.uid() AS uid))))));

alter policy "device_tokens_self" on public."device_tokens"
  using ((user_id = ( SELECT auth.uid() AS uid)));

alter policy "device_tokens_forget" on public."device_tokens"
  using ((user_id = ( SELECT auth.uid() AS uid)));

alter policy "orders_customer_update" on public."orders"
  using (((customer_id = ( SELECT auth.uid() AS uid)) AND (status = ANY (ARRAY['draft'::order_status, 'awaiting_approval'::order_status]))))
  with check (((customer_id = ( SELECT auth.uid() AS uid)) AND (status = ANY (ARRAY['draft'::order_status, 'awaiting_approval'::order_status]))));

alter policy "prospects_canvasser_read" on public."prospects"
  using ((( SELECT auth.email() AS email) = 'divinejdavis@gmail.com'::text));

alter policy "prospects_canvasser_write" on public."prospects"
  using ((( SELECT auth.email() AS email) = 'divinejdavis@gmail.com'::text))
  with check ((( SELECT auth.email() AS email) = 'divinejdavis@gmail.com'::text));

alter policy "order_items_customer_write" on public."order_items"
  using ((EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = order_items.order_id) AND (o.customer_id = ( SELECT auth.uid() AS uid)) AND (o.status = 'draft'::order_status)))))
  with check ((EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = order_items.order_id) AND (o.customer_id = ( SELECT auth.uid() AS uid)) AND (o.status = 'draft'::order_status)))));

alter policy "orders_customer_insert" on public."orders"
  with check (((customer_id = ( SELECT auth.uid() AS uid)) AND (status = 'draft'::order_status) AND (EXISTS ( SELECT 1
   FROM cleaners c
  WHERE ((c.id = orders.cleaner_id) AND c.active))) AND (EXISTS ( SELECT 1
   FROM addresses a
  WHERE ((a.id = orders.address_id) AND (a.user_id = ( SELECT auth.uid() AS uid))))) AND (EXISTS ( SELECT 1
   FROM service_items si
  WHERE ((si.cleaner_id = orders.cleaner_id) AND (si.service_type = orders.service_type) AND si.active)))));
