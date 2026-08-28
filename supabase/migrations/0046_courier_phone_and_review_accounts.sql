-- Let the customer call the driver, and mark the accounts App Review uses.
--
-- Two unrelated-looking changes that arrive together because they are both
-- about what happens to a real courier on a real road.

-- ---------------------------------------------------------------------------
-- 1. courier_phone becomes readable
-- ---------------------------------------------------------------------------
-- Migration 0024 revoked it along with the rest of the leg PII on the grounds
-- that "neither client reads these columns". That was true then. The customer
-- now has a driver holding their clothes and no way to reach them: the detail
-- screen offers "Track the driver", which opens the carrier's map, and a
-- handoff code, and nothing that rings a phone.
--
-- What is exposed is not a courier's personal line. Uber Direct returns a
-- masked proxy number that routes to the driver only while the delivery is
-- live, which is why this is safe to show and why the app hides it once the
-- leg finishes — a dead proxy number is a tap that fails.
--
-- The rest of 0024's revocation stands: dropoff_phone, dropoff_address,
-- courier_lat/lng and the pickup phone remain unreadable to any client.
-- scrub_finished_leg_pii (0025/0028) already nulls courier_phone on finished
-- orders, so this widens what is visible without widening what is retained.
--
-- delivery_legs_read scopes rows to the order's own customer or the shop's
-- staff, and both of them are people who may legitimately need to ring the
-- driver carrying the bag.
grant select (courier_phone) on public.delivery_legs to authenticated;

-- ---------------------------------------------------------------------------
-- 2. profiles.is_review_account
-- ---------------------------------------------------------------------------
-- Uber Direct's credentials on this box are live, not sandbox, and it is first
-- in the provider chain. So an App Store reviewer following the review notes
-- and booking a pickup puts a real driver on a real Brooklyn street, at real
-- cost, to collect a bag that does not exist — and a second one two days later
-- to bring it back.
--
-- The dispatcher reads this flag and routes those orders to the simulated
-- carrier instead. A column rather than a list of emails in the service config
-- because it is the account that has the property, it is visible in the
-- database to anyone wondering why an order went to the mock, and it cannot
-- drift out of sync with a redeploy.
alter table public.profiles
  add column if not exists is_review_account boolean not null default false;

comment on column public.profiles.is_review_account is
  'Orders from this account are dispatched to the simulated carrier, never to a real one. For App Review and for demo walkthroughs.';

-- Deliberately NOT granted to authenticated. Migration 0032 column-locked
-- writes on this table to four columns, and this is not one of them, so the
-- customer app cannot set it — which matters, because an account that could
-- flip its own flag would be an account that books couriers nobody pays for.
-- Stated as an explicit revoke rather than left to the absence of a grant:
-- a future `grant update on public.profiles` would otherwise silently pick
-- this column up.
revoke update (is_review_account) on public.profiles from authenticated, anon;

-- The account the App Store review notes hand out. Matched on the auth user's
-- email rather than a hardcoded uuid so this migration says who it means.
update public.profiles p
   set is_review_account = true
  from auth.users u
 where u.id = p.id
   and u.email in ('testcustomer@crease.local', 'canvass@crease.local');
