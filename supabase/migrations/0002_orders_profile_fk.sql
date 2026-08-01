-- orders.customer_id references auth.users, which PostgREST cannot traverse
-- from public.orders. Add a parallel FK to public.profiles so the dispatcher
-- (and the portal) can embed the customer in one query. profiles.id is itself
-- auth.users.id, so this constrains nothing new — it only makes the
-- relationship visible to the schema cache.

alter table public.orders
  add constraint orders_customer_profile_fkey
  foreign key (customer_id) references public.profiles(id) on delete restrict;

notify pgrst, 'reload schema';
