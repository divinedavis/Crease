-- Laundry first. Dry cleaning waits.
--
-- Crease is going to market as wash & fold pickup and delivery at $2.00 a
-- pound with a $20 minimum, and dry cleaning comes back once laundry is
-- onboarded. Two reasons that ordering is right, and both are already written
-- down in this repo: laundry is weekly where dry cleaning is monthly, which is
-- four times the orders from the same customer; and a laundry price is a rate
-- anybody can quote from the doorstep, while dry cleaning is a per-garment
-- price list that every shop keeps differently.
--
-- The prices being replaced were placeholders — invented so the app had
-- something to render before a real shop had given a real number. A quote is a
-- promise, and quoting an invented one on a live site is the sort of thing
-- that gets discovered at a counter by a customer.
--
-- $20 minimum is expressed as a 10 lb floor because that is what the column
-- holds, and at $2.00/lb the two are the same sentence: minimum_units is the
-- weight billed for when the bag comes in lighter.

-- The real rate, everywhere it is quoted.
update public.service_items
   set unit_price_cents = 200,
       minimum_units    = 10.0,
       active           = true
 where service_type = 'wash_fold'
   and unit = 'pound';

-- Everything else stops being offered. Not deleted: dry cleaning is the next
-- service, not a mistake, and its rows carry the shape a real price list will
-- be poured into. Deactivating leaves them out of every menu the app, the site
-- and the portal build, because all three filter on active.
update public.service_items
   set active = false
 where service_type in ('dry_clean', 'press');

-- Bedding is priced per piece and is part of laundry, but $34.99 was invented
-- too. Off until a shop gives a number.
update public.service_items
   set active = false
 where service_type = 'wash_fold'
   and unit = 'piece';

-- A new order is a laundry order now. The column defaulted to 'dry_clean',
-- which after this migration is a service no shop publishes an active price
-- for — and the insert policy from 0037 refuses exactly that, so the default
-- would have made every order that relied on it fail.
alter table public.orders
  alter column service_type set default 'wash_fold';

notify pgrst, 'reload schema';
