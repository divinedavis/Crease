-- What the courier actually costs on this order's route.
--
-- Delivery was priced from a flat per-tier table that no distance ever
-- reached: $29.95 for a round trip whether the shop was four blocks away or
-- six miles. Uber Direct is flat only under ~3 miles ($12.99/leg) and steps up
-- past it ($15.99/leg at 6mi), so a long round trip sold at $29.95 against
-- $31.98 of courier — a loss on every one, taken silently.
--
-- The dispatch service now buys one quote for the route before it charges, and
-- caches the per-leg cost here so pricing, settlement and the dispatch margin
-- check all read the same figure instead of each buying their own quote.
--
-- quoted_at is the freshness clock. A quote hours old is a number about a road
-- that was busy then, and re-pricing from it is guessing; past the window the
-- service re-quotes.

alter table public.orders
  add column quoted_leg_cost_cents int check (quoted_leg_cost_cents is null or quoted_leg_cost_cents >= 0),
  add column quoted_at             timestamptz;

comment on column public.orders.quoted_leg_cost_cents is
  'Carrier cost of ONE leg on this route, in cents, from a real quote. Written by the dispatch service.';

-- Deliberately NOT added to the authenticated UPDATE allowlist in 0021 — that
-- grant is a column allowlist, so a new column is withheld by default and no
-- revoke is needed here.
--
-- INSERT is still table-wide, so a customer's app could put a value in this
-- column when it creates the draft. That is safe by construction rather than
-- by permission: feeForCourierCost floors every result at the published tier
-- price, so a forged low cost cannot price a delivery below the published
-- price, and a forged high one only overcharges the forger. The service
-- overwrites the column from its own quote before it charges regardless.

notify pgrst, 'reload schema';
