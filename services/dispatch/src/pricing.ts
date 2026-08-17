// Server-authoritative delivery pricing.
//
// The customer's app inserts orders — including delivery_fee_cents — directly
// into Supabase, and the orders RLS check validates only ownership, not which
// columns or values a customer may write. So the fee on the row is
// client-controlled and must NEVER be trusted for charging: a customer could
// insert delivery_fee_cents = 1 and be charged a cent for a real courier.
//
// These are the published flat per-tier prices (mirror of
// apps/ios/Crease/Features/Pickup/ServiceOption.swift; see also
// scripts/courier-pricing.mjs). They are a FLOOR, not the whole answer — see
// feeForCourierCost below, which raises them when the actual route costs more
// than the flat-rate one they were derived from.
export const DELIVERY_FEE_CENTS: Record<string, number> = {
  round_trip: 2995,
  return_only: 1995,
  pickup_only: 1995,
};

/** Courier trips Crease pays for, per tier. The whole margin turns on this. */
export const LEGS_BY_TIER: Record<string, number> = {
  round_trip: 2,
  return_only: 1,
  pickup_only: 1,
};

/**
 * Card processing, which comes out of the fee before any of it is Crease's.
 *
 * Stripe returns none of this on a refund — not the percentage and not the
 * fixed part — which is why it also shows up in the cancellation retention
 * below rather than only in the pricing.
 */
export const STRIPE_PERCENT_BPS = 290;
export const STRIPE_FIXED_CENTS = 30;

/** What the processor keeps on a charge of this size. */
export function cardFeeCents(chargedCents: number): number {
  if (chargedCents <= 0) return 0;
  return Math.round((chargedCents * STRIPE_PERCENT_BPS) / 10_000) + STRIPE_FIXED_CENTS;
}

/**
 * The measured flat courier rate this pricing was built on: $12.99 a leg in
 * Brooklyn, essentially flat under three miles (scripts/courier-pricing.mjs,
 * live Uber Direct quotes 2026-08-01).
 *
 * Used as the fallback cost of a leg whose real price we never learned — an
 * engaged courier cost *something*, and this is the best estimate of it.
 */
export const FLAT_RATE_LEG_COST_CENTS = 1299;

/**
 * What Crease must clear on an order after the courier and the card.
 *
 * Not a target plucked out of the air: it is exactly what the published
 * round-trip price earns at the flat rate ($29.95 − $25.98 − $1.17 = $2.80).
 * Setting it here means a flat-rate route reprices to precisely the published
 * price and nothing changes for the common case — only routes that cost more
 * than the flat rate move, which is the entire point.
 */
export const TARGET_MARGIN_CENTS = Number(process.env.TARGET_MARGIN_CENTS ?? 280);

/** Courier trips for a tier. Throws rather than guessing an unknown tier. */
export function legsForTier(tier: string | null | undefined): number {
  const legs = tier ? LEGS_BY_TIER[tier] : undefined;
  if (legs === undefined) {
    throw new Error(`unknown service tier '${tier}' — cannot count courier legs`);
  }
  return legs;
}

/** Round up to the next .95, so a computed price still reads like a price. */
function toNext95(cents: number): number {
  return Math.ceil((cents + 5) / 100) * 100 - 5;
}

/**
 * The fee a tier must carry for a route whose courier legs cost this much.
 *
 * Solves fee − courier − cardFee(fee) ≥ TARGET_MARGIN for fee, then rounds up
 * to a presentable number and floors at the published price. It never returns
 * less than the published price: a route cheaper than the flat rate is margin,
 * not a discount to pass on, and undercutting the number in the App Store
 * screenshots would be its own problem.
 *
 * This is what stops a six-mile round trip from being sold at $29.95 against
 * $31.98 of courier — a $3.20 loss on every one, which is what shipped before
 * anything looked at the distance.
 */
export function feeForCourierCost(
  tier: string | null | undefined,
  perLegCourierCents: number | null | undefined,
): number {
  const floor = deliveryFeeCents(tier);

  // No usable quote — the carrier was down, had no coverage, or this is a
  // provider that does not price on distance. Fall back to the published
  // price rather than inventing one; a booking must not fail on a quote.
  if (!Number.isFinite(perLegCourierCents as number) || (perLegCourierCents as number) <= 0) {
    return floor;
  }

  const courier = (perLegCourierCents as number) * legsForTier(tier);
  // fee(1 − pct) ≥ courier + fixed + margin
  const numerator = courier + STRIPE_FIXED_CENTS + TARGET_MARGIN_CENTS;
  const denominator = 1 - STRIPE_PERCENT_BPS / 10_000;
  return Math.max(floor, toNext95(Math.ceil(numerator / denominator)));
}

/**
 * The published price for a service tier, in cents. Throws on an unknown tier
 * rather than guessing a price.
 *
 * This is the floor and the fallback. Anything that actually charges a
 * customer should go through feeForCourierCost with a real quote where one is
 * available.
 */
export function deliveryFeeCents(tier: string | null | undefined): number {
  const fee = tier ? DELIVERY_FEE_CENTS[tier] : undefined;
  if (fee === undefined) {
    throw new Error(`unknown service tier '${tier}' — cannot price delivery`);
  }
  return fee;
}

/**
 * The least a cancellation can keep once a courier has been engaged.
 *
 * A floor, not the fee itself. It exists for the leg whose real cost never
 * came back from the carrier at all, so that something is still retained
 * rather than nothing.
 */
export const MIN_CANCELLATION_FEE_CENTS = 600;

/** Shape of a leg row, as much of it as the retention math reads. */
export interface EngagedLeg {
  fee_cents?: number | null;
  provider?: string | null;
  provider_delivery_id?: string | null;
}

/**
 * Did this leg ever become somebody's job — and therefore somebody's bill?
 *
 * Mirrors reachedCarrier in orders.ts: 'pending' is the placeholder a claim
 * carries until a quote comes back and 'none' is a refusal recorded before any
 * claim, so neither cost anything. A provider_delivery_id means a courier was
 * dispatched even if the row never got the carrier's name written on it.
 */
function billedByCarrier(l: EngagedLeg): boolean {
  if (l.provider_delivery_id) return true;
  return Boolean(l.provider) && l.provider !== 'pending' && l.provider !== 'none';
}

/**
 * Kept from the refund when a customer cancels after a courier has been
 * engaged.
 *
 * Cancelling is free right up until someone is assigned; after that the carrier
 * bills for the aborted job and the card processor keeps its cut of the
 * original capture whatever happens next. Returning the full fee there means
 * every book-watch-cancel cycle costs Crease real money, which is a loop a
 * customer can run all day.
 *
 * This is the floor of what that cycle actually costs, not a penalty — which
 * is why it is computed from the legs that were really dispatched rather than
 * being a flat $6. A flat $6 against a $12.99 leg plus $1.17 of card fee lost
 * about $8 on every cancelled round trip, and on an order where both legs had
 * been engaged it lost twice that. voidOrder clamps whatever comes back here to
 * the money actually held, so an over-estimate cannot refund a negative amount.
 */
export function cancellationRetainCents(input: {
  legs: readonly EngagedLeg[];
  capturedCents: number;
}): number {
  const courier = input.legs
    .filter(billedByCarrier)
    // A leg that reached a carrier with no fee on the row still cost money —
    // the create response is where fee_cents comes from, and a lost response
    // is exactly the case where a courier is out driving unrecorded. Charging
    // zero for it would be the wrong way round.
    .reduce((n, l) => n + (l.fee_cents ?? FLAT_RATE_LEG_COST_CENTS), 0);

  // Nothing was engaged: the caller should not have been in this branch, but
  // retaining a courier's fee for a courier nobody called is not ours to keep.
  if (courier <= 0) return 0;

  return Math.max(MIN_CANCELLATION_FEE_CENTS, courier + cardFeeCents(input.capturedCents));
}
