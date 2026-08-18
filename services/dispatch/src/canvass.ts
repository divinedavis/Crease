import type { FastifyInstance } from 'fastify';
import type { SupabaseClient } from '@supabase/supabase-js';

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
 *  before the walk home. */
const TTL_MS = 60_000;

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
  // head:true counts server-side: seven cheap round trips instead of pulling
  // five hundred rows of a table this route is not allowed to expose. It also
  // stays exact if the list outgrows PostgREST's row cap, which a
  // select-and-count-here implementation would silently truncate at.
  const count = async (apply: (q: any) => any) => {
    const { count: n, error } = await apply(
      db.from('prospects').select('id', { count: 'exact', head: true }),
    );
    if (error) throw new Error(`prospect count failed: ${error.message}`);
    return n ?? 0;
  };

  const [total, dryCleaners, laundromats, contacted, interested, followingUp, declined] =
    await Promise.all([
      count((q) => q),
      count((q) => q.eq('kind', 'dry_cleaner')),
      count((q) => q.eq('kind', 'laundromat')),
      count((q) => q.eq('visited', true)),
      count((q) => q.eq('outcome', 'interested')),
      count((q) => q.eq('outcome', 'follow_up')),
      count((q) => q.eq('outcome', 'declined')),
    ]);

  return {
    total,
    dry_cleaners: dryCleaners,
    laundromats: laundromats,
    contacted,
    interested,
    following_up: followingUp,
    declined,
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
    reply.header('Cache-Control', 'public, max-age=60');

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
