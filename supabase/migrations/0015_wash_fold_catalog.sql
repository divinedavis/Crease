-- Give every shop a laundry price list alongside the dry cleaning one.
--
-- Priced by the pound at NYC market rate, with the weight minimum shops
-- actually enforce. Without the minimum a 4 lb order bills $9.00 against a
-- $25.98 round trip, which is a loss dressed up as a sale.
--
-- Turnaround is where the two services separate: two hours for wash & fold
-- against the 24-48h these shops quote for dry cleaning. Bedding is the
-- exception and stays overnight, because a comforter does not dry in two
-- hours no matter what the counter says.

insert into public.service_items
  (cleaner_id, code, label, unit_price_cents, service_type, unit, turnaround_hours, minimum_units, sort_order)
select c.id, v.code, v.label, v.price, v.stype::service_type, v.unit, v.hrs, v.minu, v.ord
from public.cleaners c
cross join (values
  ('wash_fold',         'Wash & fold',          225, 'wash_fold', 'pound',  2, 15.0, 10),
  ('wash_fold_bedding', 'Comforter / bedding', 3499, 'wash_fold', 'piece', 24,  0.0, 11),
  ('press_shirt',       'Press only, shirt',    249, 'press',     'piece',  4,  0.0, 12)
) as v(code, label, price, stype, unit, hrs, minu, ord)
on conflict (cleaner_id, code, service_type) do update
  set unit_price_cents = excluded.unit_price_cents,
      turnaround_hours = excluded.turnaround_hours,
      minimum_units    = excluded.minimum_units;

notify pgrst, 'reload schema';
