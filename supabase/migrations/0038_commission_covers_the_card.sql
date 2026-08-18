-- Stop paying Stripe for the shop's half of the ticket.
--
-- Crease is merchant of record on the whole order: the capture is cleaning +
-- delivery, so Stripe takes 2.9% + 30c of all of it — including the cleaning
-- that is only passing through on its way to the shop. But the published
-- delivery price is solved against the card fee on the DELIVERY FEE alone
-- (services/dispatch/src/pricing.ts). The card fee on the cleaning was coming
-- out of the $2.80 that was supposed to be the whole margin.
--
-- What that actually cost, round trip, at 0% commission:
--
--     cleaning     $5     $33     $60   $96.59    $120     $200
--     kept       $2.66   $1.84   $1.06    $0.00  -$0.68   -$3.00
--
-- The better the customer, the less the order earned, and past ~$96 of
-- cleaning it lost money. Backwards, and invisible: nothing in the system ever
-- compared what an order collected to what it cost.
--
-- 290 bps is exactly Stripe's percentage, so it recovers precisely what the
-- pass-through costs and no more. It makes the margin flat at $2.80 for every
-- ticket size, which is what the pricing model always claimed:
--
--     cleaning     $5     $33     $60   $96.59    $120     $200
--     kept       $2.81   $2.80   $2.80    $2.80   $2.80    $2.80
--
-- This is cost recovery, not a cut of the shop's work, and it is the version
-- of "we take nothing from your cleaning" that is actually true — the previous
-- one had Crease quietly funding the card fee on their revenue.
--
-- A floor, not a rate: shops already negotiated above it keep what they were
-- given. The three seed shops stay at 2000 bps so the commission path is still
-- exercised by the payout tests.

alter table public.cleaners
  alter column commission_bps set default 290;

update public.cleaners
   set commission_bps = greatest(commission_bps, 290)
 where commission_bps < 290;

-- Nothing may be set below the card cost again. Naming Stripe's rate in a
-- constraint is deliberate: if the rate moves, this line is where the change
-- has to be acknowledged, rather than a shop silently going underwater.
alter table public.cleaners
  add constraint cleaners_commission_covers_card
  check (commission_bps >= 290);

comment on column public.cleaners.commission_bps is
  'Basis points withheld from the cleaning subtotal. The first 290 is not a '
  'cut — it is the Stripe percentage on the shop''s portion of a charge Crease '
  'is merchant of record for. Anything above it is margin.';

notify pgrst, 'reload schema';
