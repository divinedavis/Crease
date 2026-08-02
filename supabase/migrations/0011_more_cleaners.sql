-- A second and third partner so the cleaner picker has something to pick.
-- With one shop the choice is invisible and the bug that hid it stayed hidden.
insert into public.cleaners (name, slug, phone, email, line1, city, state, postal_code, lat, lng, turnaround_hours)
values
  ('Fort Greene Cleaners', 'fort-greene-cleaners', '+15555550201', 'shop@fortgreene.local',
   '680 Fulton St', 'Brooklyn', 'NY', '11217', 40.6873, -73.9752, 24),
  ('Clinton Hill Dry Cleaning', 'clinton-hill-dry-cleaning', '+15555550202', 'shop@clintonhill.local',
   '400 Myrtle Ave', 'Brooklyn', 'NY', '11205', 40.6941, -73.9686, 48)
on conflict (slug) do update
  set lat = excluded.lat, lng = excluded.lng, line1 = excluded.line1;

-- Bedford was seeded before cleaners carried usable coordinates for ranking.
update public.cleaners set lat = 40.7141, lng = -73.9613 where slug = 'bedford-cleaners';

-- Every shop needs a price list, even though the customer settles that bill
-- directly — the portal reads it at intake.
insert into public.service_items (cleaner_id, code, label, unit_price_cents, sort_order)
select c.id, v.code, v.label, v.price, v.ord
from public.cleaners c
cross join (values
  ('shirt','Laundered shirt',349,0),
  ('pants','Pants / slacks',799,1),
  ('suit_2pc','Two-piece suit',1899,2),
  ('dress','Dress',1599,3),
  ('coat','Overcoat',2499,4)
) as v(code,label,price,ord)
where c.slug in ('fort-greene-cleaners','clinton-hill-dry-cleaning')
on conflict (cleaner_id, code) do nothing;

notify pgrst, 'reload schema';
