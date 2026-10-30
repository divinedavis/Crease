import type { SupabaseClient } from '@supabase/supabase-js';

/** The canvass funnel, counted. Shared by the public tile and the owner
 *  dashboard so both read the same seven numbers from one query. */
export type CanvassCounts = {
  shops: number;
  dry_cleaners: number;
  laundromats: number;
  /** Walked into — `visited`, not merely known about. */
  contacted: number;
  interested: number;
  following_up: number;
  declined: number;
};

const KEYS: Array<keyof CanvassCounts> = [
  'shops',
  'dry_cleaners',
  'laundromats',
  'contacted',
  'interested',
  'following_up',
  'declined',
];

/** canvass_counts() jsonb -> numbers. A missing or non-numeric key reads as 0
 *  rather than NaN, so one odd value cannot blank a tile. */
export function parseCanvassCounts(raw: unknown): CanvassCounts {
  const row = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>;
  const out = {} as CanvassCounts;
  for (const k of KEYS) {
    const n = Number(row[k]);
    out[k] = Number.isFinite(n) ? n : 0;
  }
  return out;
}

/**
 * One round trip (supabase/migrations/0052_canvass_counts.sql). These used to
 * be seven head:true counts per refresh in each caller — ~330k queries on a
 * 479-row table by October 2026, most of the project's PostgREST traffic.
 */
export async function readCanvassCounts(db: SupabaseClient): Promise<CanvassCounts> {
  const { data, error } = await db.rpc('canvass_counts');
  if (error) throw new Error(`canvass counts failed: ${error.message}`);
  return parseCanvassCounts(data);
}
