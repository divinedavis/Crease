import type { FastifyInstance } from 'fastify';
import type { SupabaseClient } from '@supabase/supabase-js';
import { readCanvassCounts } from './canvassCounts.js';

/**
 * The canvass funnel as a public counter.
 *
 * The portfolio tile on divinedavis.com wants to show how the Brooklyn
 * partner hunt is going — how many shops there are, how many have been walked
 * into, how many are worth going back to. Those numbers live in `prospects`,
 * which is the founder's street tool: RLS allowlists two logins and the notes
 * on it are about named businesses. None of that can be handed to a public
 * page.
 *
 * So this returns counts and nothing else. No name, address, phone or note
 * ever crosses this route — a caller learns that three shops are worth a
 * second visit, never which three. That is the whole reason it can be
 * unauthenticated.
 */

/** Long enough that a scraper cannot turn a page load into database load,
 *  short enough that a shop marked at the counter shows up on the site
 *  before the walk home. Five minutes since 2026-10-30: the list moves a few
 *  rows a week, and at one minute an open tab was ~1,400 refreshes a day. */
const TTL_MS = 5 * 60_000;

export type CanvassStats = {
  /** Every dry cleaner and laundromat mapped in Brooklyn. */
  total: number;
  dry_cleaners: number;
  laundromats: number;
  /** Walked into — `visited`, not merely known about. */
  contacted: number;
  interested: number;
  following_up: number;
  declined: number;
  /** When these counts were read, so a stale cache is visible rather than
   *  silently presented as current. */
  as_of: string;
};

async function readStats(db: SupabaseClient): Promise<CanvassStats> {
  // One query for all seven numbers (canvassCounts.ts). Counts only: this
  // route is not allowed to expose a single prospect row.
  const c = await readCanvassCounts(db);
  return {
    total: c.shops,
    dry_cleaners: c.dry_cleaners,
    laundromats: c.laundromats,
    contacted: c.contacted,
    interested: c.interested,
    following_up: c.following_up,
    declined: c.declined,
    as_of: new Date().toISOString(),
  };
}

export function registerCanvassRoutes(app: FastifyInstance, db: SupabaseClient) {
  let cached: CanvassStats | null = null;
  let cachedAt = 0;
  // Concurrent misses share one read rather than each opening their own fan of
  // seven queries — the shape a public endpoint gets hit in.
  let inflight: Promise<CanvassStats> | null = null;

  app.get('/public/canvass-stats', async (req, reply) => {
    // Aggregate, uncredentialed, and meant for a page on another domain, so a
    // wildcard costs nothing: there is no cookie or token for a hostile origin
    // to ride, and the body is already public the moment the tile renders it.
    reply.header('Access-Control-Allow-Origin', '*');
    reply.header('Cache-Control', 'public, max-age=300');

    const fresh = cached && Date.now() - cachedAt < TTL_MS;
    if (!fresh) {
      try {
        inflight ??= readStats(db).finally(() => {
          inflight = null;
        });
        cached = await inflight;
        cachedAt = Date.now();
      } catch (err) {
        // A database blip must not blank the tile. The last good answer is
        // still roughly true — the list moves a few rows a week — and `as_of`
        // says how old it is.
        req.log.error({ err }, 'canvass stats read failed');
        if (!cached) return reply.code(503).send({ ok: false, error: 'stats unavailable' });
      }
    }

    return cached;
  });
}
