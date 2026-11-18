/**
 * What the courier is told about the bag.
 *
 * Crease carries two kinds of load: wash & fold laundry, sold by the pound,
 * and dry cleaning, sold by the piece. A 25 lb laundry bag is not a shirt on a
 * hanger — the courier network uses weight and description to decide who can
 * take it (Nash filters out couriers whose vehicle cannot carry it), so the
 * weight we know goes out with every request instead of "Dry cleaning".
 *
 * Weight comes from the larger of the customer's accepted photo estimate and
 * the pounds on the order lines (the counter's weigh-in once the shop has
 * counted it). Pieces are never turned into a guessed weight: unknown stays
 * unknown rather than becoming a number a courier plans around.
 */

export interface ManifestOrder {
  short_code?: string | null;
  weight_estimate_lb?: number | string | null;
  order_items?: Array<{
    quantity: number | string | null;
    service_item?: { unit?: string | null } | null;
  }> | null;
}

export interface BagManifest {
  description: string;
  itemCount: number;
  weightLbs?: number;
}

export function bagManifest(order: ManifestOrder): BagManifest {
  let pounds = 0;
  let pieces = 0;
  for (const line of order.order_items ?? []) {
    const q = Number(line?.quantity);
    if (!Number.isFinite(q) || q <= 0) continue;
    if (line?.service_item?.unit === 'pound') pounds += q;
    else pieces += q;
  }

  const estimate = Number(order.weight_estimate_lb);
  const weight = Math.max(Number.isFinite(estimate) && estimate > 0 ? estimate : 0, pounds);
  const hasLaundry = weight > 0;
  const hasPieces = pieces > 0;

  const kind =
    hasLaundry && hasPieces
      ? 'Laundry bag + dry cleaning'
      : hasLaundry
        ? 'Laundry bag (wash & fold)'
        : 'Dry cleaning';
  const ref = order.short_code ? ` — order ${order.short_code}` : '';

  return {
    description: `${kind}${ref}`,
    // Things to carry, not garments-plus-pounds: a laundry bag is one item
    // however much it weighs.
    itemCount: Math.max(1, Math.ceil(pieces) + (hasLaundry ? 1 : 0)),
    ...(hasLaundry ? { weightLbs: Math.ceil(weight) } : {}),
  };
}
