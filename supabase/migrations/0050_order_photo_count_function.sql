-- 0049's insert policy counted the order's photos with a subquery on
-- storage.objects, inside a policy ON storage.objects: Postgres applies the
-- table's policies to that subquery too and stops with "infinite recursion
-- detected in policy for relation objects", which Storage reports to the app
-- as "The database schema is invalid or incompatible" — every customer upload
-- refused. Count through a SECURITY DEFINER function instead, which reads the
-- table without re-entering its policies. It returns only a number for a
-- folder name, so it leaks nothing a caller could not infer from the cap.

create or replace function public.order_photo_count(p_folder text)
returns integer
language sql
stable
security definer
set search_path = storage, pg_temp
as $$
  select count(*)::int
    from storage.objects
   where bucket_id = 'order-photos'
     and (storage.foldername(name))[1] = p_folder
$$;
revoke all on function public.order_photo_count(text) from public, anon;
grant execute on function public.order_photo_count(text) to authenticated;

drop policy if exists order_photos_customer_insert on storage.objects;
create policy order_photos_customer_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'order-photos'
    and exists (
      select 1 from public.orders o
       where o.id::text = (storage.foldername(name))[1]
         and o.customer_id = auth.uid()
         and o.status not in ('cancelled', 'delivered', 'failed')
    )
    and public.order_photo_count((storage.foldername(name))[1]) < 12
  );
