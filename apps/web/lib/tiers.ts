/**
 * The published price sheet, mirrored from services/dispatch/src/pricing.ts.
 *
 * Every one of these is solved from courier cost plus card fee plus the target
 * margin — a round trip buys two Brooklyn legs at $12.99, a single leg buys
 * one. If that file changes, this changes with it: a website quoting a price
 * the dispatcher will not honour is worse than a website quoting nothing.
 *
 * A plain module rather than a member of actions.ts, because a 'use server'
 * file may only export async functions. Exporting this array from there built
 * cleanly and threw on the first request — the kind of failure only running
 * the thing finds.
 */
export interface Tier {
  id: string;
  name: string;
  blurb: string;
  priceCents: number;
  etaMinutes: number | null;
}

export const TIERS: Tier[] = [
  {
    id: 'round_trip',
    name: 'Round trip',
    blurb: 'We collect it now and deliver it back when it’s ready',
    priceCents: 2995,
    etaMinutes: 30,
  },
  {
    id: 'pickup_only',
    name: 'Pickup only',
    blurb: 'We collect it, you fetch it from the shop',
    priceCents: 1695,
    etaMinutes: 20,
  },
  {
    id: 'return_only',
    name: 'Return only',
    blurb: 'It’s already at the shop — we bring it home',
    priceCents: 1695,
    etaMinutes: null,
  },
];
