#!/usr/bin/env node
/**
 * Load the Brooklyn canvassing list into `prospects`.
 *
 *   node scripts/seed-prospects.mjs
 *
 * Reads growth/prospects/seed.json (built from OpenStreetMap — see
 * growth/prospects/README.md for the query). Idempotent: rows upsert on
 * osm_id, and the working columns — visited, outcome, notes — are never
 * touched on a reseed. A fresher OSM pull must not erase a month of
 * door-knocking.
 */
import { readFileSync } from 'node:fs';
import { adminClient, ROOT } from './lib/client.mjs';
import { join } from 'node:path';

const rows = JSON.parse(readFileSync(join(ROOT, 'growth/prospects/seed.json'), 'utf8'));
const { db } = await adminClient();

let done = 0;
for (let i = 0; i < rows.length; i += 100) {
  const batch = rows.map(({ osm_id, kind, name, address, zip, phone, lat, lng, neighborhood }) => ({
    osm_id, kind, name, address, zip, phone, lat, lng, neighborhood,
  })).slice(i, i + 100);
  const { error } = await db.from('prospects').upsert(batch, { onConflict: 'osm_id' });
  if (error) throw new Error(error.message);
  done += batch.length;
}
console.log(`${done} prospects upserted`);

const { count } = await db.from('prospects').select('*', { count: 'exact', head: true });
console.log(`${count} total in table`);
