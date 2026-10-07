-- Photos a customer attaches to an order, and the language a shop reads notes in.
--
-- order-photos holds the handoff (custody) photo taken before the bag leaves
-- the house and any stain close-ups. They exist to settle "was it like that
-- when you took it" between a customer and a shop, so:
--  - private bucket; read only by the order's own customer and the staff of
--    the shop the order went to;
--  - a customer may add photos to their own order, never edit or delete one
--    (a custody record you can quietly replace is not a record);
--  - at most 12 per order and 3 MB each, JPEG/HEIC only, so the free plan's
--    1 GB cannot be filled from one account.
-- Paths are '<order_id>/<file>'.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('order-photos', 'order-photos', false, 3145728, array['image/jpeg', 'image/heic'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

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
    and (
      select count(*) from storage.objects x
       where x.bucket_id = 'order-photos'
         and (storage.foldername(x.name))[1] = (storage.foldername(name))[1]
    ) < 12
  );

drop policy if exists order_photos_read on storage.objects;
create policy order_photos_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'order-photos'
    and exists (
      select 1 from public.orders o
       where o.id::text = (storage.foldername(name))[1]
         and (o.customer_id = auth.uid() or public.is_cleaner_staff(o.cleaner_id))
    )
  );
-- No update or delete policy: nobody but the service role (retention) removes one.

-- The language the shop's counter reads. The app translates a customer's note
-- into it on the phone before sending, keeping the original alongside.
alter table public.cleaners
  add column if not exists notes_language text not null default 'en'
  check (notes_language ~ '^[a-z]{2}(-[A-Za-z]{2,4})?$');
grant select (notes_language) on public.cleaners to authenticated;
grant update (notes_language) on public.cleaners to authenticated;

notify pgrst, 'reload schema';
