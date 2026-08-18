#!/usr/bin/env node
/**
 * Load a borough's canvassing list into `prospects`.
 *
 *   node scripts/seed-prospects.mjs
 *
 * Reads growth/prospects/seed.json (built from OpenStreetMap — see
 * growth/prospects/README.md for the query). Idempotent: rows upsert on
 * osm_id, and the working columns — visited, outcome, notes — are never
 * touched on a reseed. A fresher OSM pull must not erase a month of
 * door-knocking.
 *
 * Seed rows may carry `borough`; without it the column defaults to Brooklyn,
 * which is what every row seeded before the expansion roadmap is.
 */
import { readFileSync } from 'node:fs';
import { adminClient, ROOT } from './lib/client.mjs';
import { join } from 'node:path';

const rows = JSON.parse(readFileSync(join(ROOT, 'growth/prospects/seed.json'), 'utf8'));
const { db } = await adminClient();

let done = 0;
for (let i = 0; i < rows.length; i += 100) {
  const batch = rows.map(({ osm_id, kind, name, address, zip, phone, lat, lng, neighborhood, borough }) => ({
    osm_id, kind, name, address, zip, phone, lat, lng, neighborhood,
    // Written on every row, not just the ones that carry it: PostgREST rejects
    // a bulk upsert whose objects don't all have the same keys (PGRST102), so
    // "omit when absent" would break the batch the first time a seed file
    // mixed them. Brooklyn is the right default — it is what every row seeded
    // before the expansion roadmap is.
    borough: borough ?? 'Brooklyn',
  })).slice(i, i + 100);
  const { error } = await db.from('prospects').upsert(batch, { onConflict: 'osm_id' });
  if (error) throw new Error(error.message);
  done += batch.length;
}
console.log(`${done} prospects upserted`);

// full_service prefills only where nobody has answered yet. The OSM guess
// must never overwrite what a canvasser learned at the counter, so it lands
// exclusively on NULL rows — and is therefore excluded from the upsert above.
for (const value of [true, false]) {
  const ids = rows.filter((r) => r.full_service === value).map((r) => r.osm_id);
  if (!ids.length) continue;
  const { error } = await db.from('prospects')
    .update({ full_service: value })
    .in('osm_id', ids)
    .is('full_service', null);
  if (error) throw new Error(error.message);
}
console.log('full_service prefilled where unknown');

const { count } = await db.from('prospects').select('*', { count: 'exact', head: true });
console.log(`${count} total in table`);
