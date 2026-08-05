-- Weights are not whole numbers.
--
-- `quantity` was an integer because every service was priced per garment and
-- you cannot hand in half a shirt. Wash & fold is priced per pound, and a
-- scale reads 17.4 — which an integer column silently truncates to 17,
-- undercharging by the fraction on every laundry order forever.
--
-- Two decimals matches what a shop scale actually shows. PostgREST emits
-- numeric as a JSON number rather than a string, so the portal's arithmetic
-- keeps working without a cast.

alter table order_items
  alter column quantity type numeric(8, 2) using quantity::numeric(8, 2);

alter table order_items
  add constraint order_items_quantity_positive check (quantity > 0);

comment on column order_items.quantity is
  'Garments for per-piece services, pounds for per-pound ones. The unit lives '
  'on the service_item, not here.';

notify pgrst, 'reload schema';
