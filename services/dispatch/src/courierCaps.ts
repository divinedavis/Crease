/**
 * A ceiling on what real couriers this service can buy in a rolling day.
 *
 * Uber Direct's credentials on the production box are live, it is first in the
 * chain, and a leg costs around thirteen dollars. Nothing bounded that. The
 * per-order underwater check catches an order that loses money; it cannot see
 * the four hundredth order a stuck retry loop has dispatched this afternoon,
 * and the spend is real money leaving a real card rather than an API quota
 * that simply stops answering.
 *
 * Kept apart from the dispatcher and free of I/O so the judgement can be
 * tested directly, which matters more here than usual: every branch below is a
 * decision about someone's clothes, and the expensive ones are the branches
 * that are hard to reach on purpose.
 */

export type LegType = 'pickup' | 'return';

export interface DispatchedLeg {
  provider?: string | null;
  provider_delivery_id?: string | null;
  fee_cents?: number | null;
}

export interface CourierCaps {
  maxLegsPerDay: number;
  maxCentsPerDay: number;
}

/**
 * Whether a leg row ever actually reached a carrier.
 *
 * Anything with a provider delivery id plainly did. So did a row that names a
 * provider: the claim is inserted as 'pending' and only takes a carrier's name
 * once one has quoted it, and a create whose response was lost may still have
 * put a courier on the road — a half-written row like that has to count even
 * though the carrier never got named on it.
 */
export function reachedCarrier(l: DispatchedLeg): boolean {
  if (l.provider_delivery_id) return true;
  return Boolean(l.provider) && l.provider !== 'pending' && l.provider !== 'none';
}

export interface CapDecision {
  /** Why this leg must not be dispatched, or null to go ahead. */
  refusal: string | null;
  /** Set whenever a limit was passed, including when we dispatch anyway. */
  exceeded: boolean;
  legsToday: number;
  centsToday: number;
}

const OK: CapDecision = { refusal: null, exceeded: false, legsToday: 0, centsToday: 0 };

export function courierCapDecision(args: {
  leg: LegType;
  /** True when the winning provider is the simulator. */
  simulated: boolean;
  /** What this leg is about to cost. */
  feeCents: number;
  /** Every leg dispatched in the trailing window, real and simulated. */
  recentLegs: DispatchedLeg[];
  limits: CourierCaps;
}): CapDecision {
  const { leg, simulated, feeCents, recentLegs, limits } = args;

  // The simulator costs nothing, and capping it would mean a review session
  // hitting a limit that exists to bound real spend.
  if (simulated) return OK;

  const { maxLegsPerDay, maxCentsPerDay } = limits;
  if (!(maxLegsPerDay > 0) && !(maxCentsPerDay > 0)) return OK;

  // Only what actually reached a carrier spends the budget: a quote that never
  // became a delivery, and a leg that failed before dispatch, cost nothing.
  // 'mock' is excluded by name as well as by the simulated flag above, because
  // this list is rows from the database rather than live provider objects.
  const spent = recentLegs.filter((l) => l.provider !== 'mock' && reachedCarrier(l));
  const legsToday = spent.length + 1;
  const centsToday = spent.reduce((n, l) => n + (l.fee_cents ?? 0), 0) + feeCents;

  const exceeded =
    (maxLegsPerDay > 0 && legsToday > maxLegsPerDay) ||
    (maxCentsPerDay > 0 && centsToday > maxCentsPerDay);
  if (!exceeded) return { refusal: null, exceeded: false, legsToday, centsToday };

  // A RETURN leg is never refused. The shop is holding that customer's
  // clothes, and a bag stranded on a counter to save thirteen dollars is the
  // worse outcome by a distance — the same judgement dispatchLeg's underwater
  // check already makes, for the same reason. A cap that can hold laundry
  // hostage is a cap that will one day hold laundry hostage.
  if (leg === 'return') return { refusal: null, exceeded: true, legsToday, centsToday };

  // A pickup is refused outright: the clothes are still in the customer's own
  // hallway, the order fails cleanly, and they are told to try later — the
  // ordinary shape of a booking that could not find a courier.
  return {
    refusal:
      'daily courier limit reached — no pickup can be booked until it resets or the cap is raised',
    exceeded: true,
    legsToday,
    centsToday,
  };
}
