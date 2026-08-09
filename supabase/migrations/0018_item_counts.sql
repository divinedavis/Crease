-- How many pieces each side says are in the bag.
--
-- The customer's number is written at booking, before anyone else has touched
-- the bag; the shop's is written at the counter. Both are optional — a
-- customer who didn't count isn't blocked from booking, and a paper-ticket
-- shop isn't forced to type one more number. When both exist they are the
-- earliest possible signal that something went missing in transit, which is
-- the one dispute a delivery company owns outright.
--
-- Deliberately not derived from the intake's billable lines: those price the
-- work, and a wash & fold line is pounds, not pieces. This is a bag-check.

alter table public.orders
  add column customer_item_count int
    check (customer_item_count between 1 and 200),
  add column cleaner_item_count int
    check (cleaner_item_count between 1 and 200);

comment on column public.orders.customer_item_count is
  'How many pieces the customer says they sent. Optional, written at booking.';
comment on column public.orders.cleaner_item_count is
  'How many pieces the shop counted in the bag. Optional, written at intake.';

notify pgrst, 'reload schema';
