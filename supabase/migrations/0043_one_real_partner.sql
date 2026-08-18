-- One partner, and it is a real one.
--
-- Bedford Cleaners, Clinton Hill Dry Cleaning and Fort Greene Cleaners were
-- invented — seeded so the cleaner picker had something to pick while the app
-- was being built, with phone numbers like +15555550201. They were also being
-- quoted to the public: creasenyc.com answered a real address with "Clinton
-- Hill Dry Cleaning is 0.31 miles away and takes pickups from your block",
-- which is a shop that does not exist offering a service it never agreed to.
--
-- Fulton Cleaners, 909 Fulton Street, is the only real one. So the service
-- area is what a courier can reach from her door: three miles, which is the
-- band the whole price sheet is built on.
--
-- Deactivated rather than deleted. Orders, legs and payouts reference these
-- rows, and the test data that proves the money path works would go with them.

update public.cleaners
   set active = false
 where slug in ('bedford-cleaners', 'clinton-hill-dry-cleaning', 'fort-greene-cleaners');

notify pgrst, 'reload schema';
