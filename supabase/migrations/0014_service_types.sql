-- Two services, not one.
--
-- Wash & fold comes back in about two hours. Dry cleaning takes most of a
-- week. Until now turnaround lived on the cleaner, which quietly assumed a
-- shop does one thing at one speed — but the same counter does both, and the
-- gap between them is the whole difference between the two businesses.
--
-- It changes the product, not just the estimate. At two hours a round trip
-- fits inside one day, so both legs can be quoted and scheduled at booking:
-- "out at 9, back by 2." At a week they cannot, which is exactly why the
-- ready/schedule-return flow exists. One order model has to express both.
--
-- And it changes the economics. Dry cleaning is roughly monthly; laundry is
-- weekly. Same margin per order, four times the orders, which is the only
-- version of this business where acquisition cost pays back inside a year.

create type service_type as enum ('dry_clean', 'wash_fold', 'press');

-- Everything seeded so far is per-piece dry cleaning, so that is the backfill.
alter table service_items
  add column service_type service_type not null default 'dry_clean',
  -- Laundry is sold by weight and dry cleaning by the piece. Without this the
  -- app has no way to know whether "3" means three shirts or three pounds,
  -- and a per-pound price rendered as a per-item price is off by 10x.
  add column unit text not null default 'piece'
    check (unit in ('piece', 'pound')),
  -- Turnaround for this specific service. Null means "whatever the shop's
  -- default is" — a nullable override rather than a copied value, so a shop
  -- changing its overall speed does not leave stale per-item numbers behind.
  add column turnaround_hours integer
    check (turnaround_hours is null or turnaround_hours between 1 and 336),
  -- Wash & fold almost always carries a weight minimum. Charging for 4 lb
  -- when the shop bills a 15 lb floor makes every small order lose money.
  add column minimum_units numeric(6, 2) not null default 0
    check (minimum_units >= 0);

-- The same `code` now means different things for different services: a shirt
-- laundered and pressed is not a shirt washed by weight. The old uniqueness
-- assumption has to widen or the seeder starts colliding.
create unique index if not exists service_items_cleaner_code_type_key
  on service_items (cleaner_id, code, service_type);

alter table orders
  add column service_type service_type not null default 'dry_clean',
  -- Whether both legs were committed to at booking. A two-hour service can
  -- promise the return up front; a week-long one cannot, and recording which
  -- happened means the app never has to re-derive it from the turnaround.
  add column return_committed_at timestamptz;

comment on column orders.service_type is
  'Which service this order is. Drives turnaround, and therefore whether the '
  'return leg can be scheduled at booking or has to wait for the shop to mark '
  'it ready.';

comment on column service_items.turnaround_hours is
  'Overrides the cleaner default for this service. Null means inherit — do '
  'not copy the cleaner value in, or it goes stale when the shop changes.';

grant select on service_items to anon, authenticated;
