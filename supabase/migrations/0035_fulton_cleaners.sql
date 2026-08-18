-- Fulton Cleaners, 909 Fulton Street — the first real Brooklyn shop in the
-- picker, so the booking flow can be walked end to end against an address
-- that exists instead of three seeded placeholders.
--
-- She is 'follow_up' on the canvass list, not a signed partner, and the two
-- questions she asked at the counter are the two this row cannot answer: how
-- she gets paid, and how the price is set. So:
--
--   * commission_bps is 0, not the 2000 default. Taking a fifth of the
--     cleaning off a shop that never agreed to a commission is not a test, it
--     is a mistake waiting to be discovered in a payout.
--   * The prices below are the same NYC market rates the seed shops carry.
--     They are NOT her price list. When she gives one, this row is updated and
--     the estimate the customer sees becomes hers.
--   * The contact number is the founder's, deliberately. A courier sent to
--     this address has to reach somebody who knows about the order, and that
--     is not the shop until she has agreed to take deliveries.
--
-- Coordinates come from the canvass row (OpenStreetMap), so the distance the
-- picker sorts on is the real one.

insert into public.cleaners
  (name, slug, phone, email, line1, city, state, postal_code, lat, lng,
   turnaround_hours, commission_bps, active)
values
  ('Fulton Cleaners', 'fulton-cleaners', '+17176599140', null,
   '909 Fulton Street', 'Brooklyn', 'NY', '11238', 40.683389, -73.967130,
   48, 0, true)
on conflict (slug) do update
  set line1 = excluded.line1,
      lat   = excluded.lat,
      lng   = excluded.lng,
      phone = excluded.phone,
      active = excluded.active;

-- Dry cleaning, by the piece.
insert into public.service_items
  (cleaner_id, code, label, unit_price_cents, service_type, unit, turnaround_hours, minimum_units, sort_order)
select c.id, v.code, v.label, v.price, v.stype::service_type, v.unit, v.hrs, v.minu, v.ord
from public.cleaners c
cross join (values
  ('shirt',              'Laundered shirt',      349, 'dry_clean', 'piece', null,  0.0,  0),
  ('pants',              'Pants / slacks',       799, 'dry_clean', 'piece', null,  0.0,  1),
  ('suit_2pc',           'Two-piece suit',      1899, 'dry_clean', 'piece', null,  0.0,  2),
  ('dress',              'Dress',               1599, 'dry_clean', 'piece', null,  0.0,  3),
  ('coat',               'Overcoat',            2499, 'dry_clean', 'piece', null,  0.0,  4),
  -- "also cleans" in her canvass note: she does laundry too, so the wash &
  -- fold list ships with her, priced and floored like every other shop.
  ('wash_fold',          'Wash & fold',          225, 'wash_fold', 'pound',    2, 15.0, 10),
  ('wash_fold_bedding',  'Comforter / bedding', 3499, 'wash_fold', 'piece',   24,  0.0, 11),
  ('press_shirt',        'Press only, shirt',    249, 'press',     'piece',    4,  0.0, 12)
) as v(code, label, price, stype, unit, hrs, minu, ord)
where c.slug = 'fulton-cleaners'
on conflict (cleaner_id, code, service_type) do update
  set unit_price_cents = excluded.unit_price_cents,
      turnaround_hours = excluded.turnaround_hours,
      minimum_units    = excluded.minimum_units;

notify pgrst, 'reload schema';
