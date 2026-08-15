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
// scripts/courier-pricing.mjs). The dispatch service recomputes the fee from
// the order's service_tier before charging and overwrites the row so every
// downstream total is consistent.
export const DELIVERY_FEE_CENTS: Record<string, number> = {
  round_trip: 2995,
  return_only: 1995,
  pickup_only: 1995,
};

/**
 * Kept from the refund when a customer cancels after a courier has been
 * engaged.
 *
 * Cancelling is free right up until someone is assigned; after that the carrier
 * bills for the aborted job and the card processor keeps its cut of the
 * original capture whatever happens next. Returning the full fee there means
 * every book-watch-cancel cycle costs Crease real money, which is a loop a
 * customer can run all day. This is the floor of what that cycle actually
 * costs, not a penalty.
 */
export const CANCELLATION_FEE_CENTS = 600;

/** The authoritative delivery fee for a service tier, in cents. Throws on an
 *  unknown tier rather than guessing a price. */
export function deliveryFeeCents(tier: string | null | undefined): number {
  const fee = tier ? DELIVERY_FEE_CENTS[tier] : undefined;
  if (fee === undefined) {
    throw new Error(`unknown service tier '${tier}' — cannot price delivery`);
  }
  return fee;
}
