-- What an order actually earned, as opposed to what it was supposed to.
--
-- Every number needed for this already existed and nothing had ever put them
-- in one place: delivery_legs.fee_cents is what a carrier really billed,
-- payments.captured_cents is what the customer really paid, payouts.
-- amount_cents is what the shop really got. Nothing compared them, so an
-- underwater tier would have surfaced as a bank balance rather than a row —
-- which is exactly how the card fee on the cleaning went unnoticed.
--
-- Costs are the recorded ones, never the modelled ones. A leg that reached a
-- carrier and came back with no fee falls back to the flat rate, because an
-- engaged courier cost SOMETHING and counting it as zero is the flattering
-- error rather than the safe one.
--
-- Service-role only. It joins payouts and payments, which no customer and no
-- shop may read across.

create or replace view public.order_margin
with (security_invoker = true) as
select
  o.id                       as order_id,
  o.short_code,
  o.status,
  o.service_tier,
  o.service_type,
  o.cleaner_id,
  c.name                     as cleaner_name,
  o.created_at,
  coalesce(p.captured_cents, 0)                       as captured_cents,
  coalesce(o.subtotal_cents, o.estimate_subtotal_cents, 0) as cleaning_cents,
  o.delivery_fee_cents,
  -- Stripe's cut of the WHOLE capture, cleaning included. The line the
  -- pricing model was missing.
  case when coalesce(p.captured_cents, 0) > 0
       then round(p.captured_cents * 0.029) + 30
       else 0 end                                     as card_fee_cents,
  coalesce(legs.courier_cents, 0)                     as courier_cents,
  coalesce(legs.leg_count, 0)                         as legs_billed,
  coalesce(po.amount_cents, 0)                        as payout_cents,
  coalesce(p.captured_cents, 0)
    - case when coalesce(p.captured_cents, 0) > 0
           then round(p.captured_cents * 0.029) + 30 else 0 end
    - coalesce(legs.courier_cents, 0)
    - coalesce(po.amount_cents, 0)                    as realized_margin_cents
from public.orders o
join public.cleaners c on c.id = o.cleaner_id
left join lateral (
  select
    sum(case
          when l.fee_cents is not null and l.fee_cents > 0 then l.fee_cents
          -- Engaged but unpriced: the flat Brooklyn leg, mirroring
          -- FLAT_RATE_LEG_COST_CENTS in pricing.ts.
          when l.provider is not null and l.provider <> 'pending' then 1299
          else 0
        end) as courier_cents,
    count(*) filter (where l.provider is not null and l.provider <> 'pending') as leg_count
  from public.delivery_legs l
  where l.order_id = o.id
    and l.status not in ('cancelled', 'failed')
) legs on true
left join lateral (
  select captured_cents from public.payments
  where order_id = o.id and kind = 'primary'
  order by created_at desc limit 1
) p on true
left join lateral (
  select amount_cents from public.payouts
  where order_id = o.id and status = 'paid'
  limit 1
) po on true;

-- New objects are granted to anon by default in this schema; a margin ledger
-- is the last thing that should inherit that.
revoke all on public.order_margin from anon, authenticated;
grant select on public.order_margin to service_role;

comment on view public.order_margin is
  'Realized per-order economics from recorded amounts only. Service role only: '
  'joins payments and payouts, which neither a customer nor a shop may read.';

notify pgrst, 'reload schema';
