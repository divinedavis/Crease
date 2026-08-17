/**
 * Shared setup for the operational scripts.
 *
 * Two things every one of them needs and got wrong separately:
 *
 *  - reading the deployed .env, which lives next to the service rather than
 *    next to the script;
 *  - constructing a Supabase client that survives Node 20. supabase-js builds
 *    a RealtimeClient eagerly, and Node 20 has no global WebSocket, so a bare
 *    createClient() throws at import on the droplet even though none of these
 *    scripts subscribe to anything. The droplet is shared with five other
 *    sites, so supplying `ws` is the fix — not upgrading Node under them.
 */
import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

export function readEnv(relPath) {
  return Object.fromEntries(
    readFileSync(join(ROOT, relPath), 'utf8')
      .split('\n')
      .filter((l) => l.includes('=') && !l.startsWith('#'))
      // .trim() so this also parses xcconfig files, which pad the '=' with
      // spaces; dotenv-style .env files are unaffected.
      .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
  );
}

async function transport() {
  if (typeof globalThis.WebSocket !== 'undefined') return undefined;
  try {
    return (await import('ws')).default;
  } catch {
    // Only reachable on Node < 22 without ws installed; realtime is unused
    // here, so let supabase-js raise its own error if it ever needs one.
    return undefined;
  }
}

// The live stack, named exactly. The Supabase project ref appears in every
// form of its URL (<ref>.supabase.co, db.<ref>.supabase.co, the pooler host),
// so match the ref itself rather than a hostname.
const PROD_PROJECT_REF = 'xfhmquvybdnrmcigflxy';
const PROD_HOSTS = new Set([
  'api.usecreaseapp.com',
  'portal.usecreaseapp.com',
  // Still a live alias serving iOS builds in the field, so it is production
  // even though nothing new points at it.
  'crease.divinedavis.com',
]);

/** What makes this value production, or null if nothing does. */
function productionReason(value) {
  if (!value) return null;
  let hostname;
  try {
    // IPv6 hostnames come back bracketed, and '[::1]' is not '::1'.
    hostname = new URL(value).hostname.replace(/^\[|\]$/g, '');
  } catch {
    // Not a URL we can parse — fall back to the ref, which is distinctive
    // enough that its presence anywhere in the string means production.
    return value.includes(PROD_PROJECT_REF) ? `production project ${PROD_PROJECT_REF}` : null;
  }
  if (hostname.includes(PROD_PROJECT_REF)) return `production project ${PROD_PROJECT_REF}`;
  if (PROD_HOSTS.has(hostname)) return `production host ${hostname}`;
  return null;
}

/**
 * Refuse to aim a service-role credential at the *live* stack by accident.
 *
 * The deploy rsyncs this whole repo onto the droplet, where
 * services/dispatch/.env is production — so `node scripts/e2e-money.mjs`
 * typed in that directory books couriers, moves money and rewrites real
 * customers' orders with the production service-role key, and nothing on the
 * command line hints at it.
 *
 * This used to demand localhost, but there is no local Supabase stack in this
 * repo (supabase/ is migrations only, no config.toml), so every run of
 * rls-check.mjs, seed.mjs and the e2e scripts needed CREASE_ALLOW_PROD=1 —
 * which teaches the operator to export it in their shell profile, and then the
 * guard is gone and the RLS regression suite is what is actually off. So name
 * the one stack that must never be hit by accident and let everything else —
 * localhost, a branch/preview project, a future staging box — run unflagged.
 */
export function assertNotProduction(env) {
  if (process.env.CREASE_ALLOW_PROD === '1') return;
  // CREASE_BASE is what the e2e scripts actually fetch when it is set, so it
  // is the value worth checking rather than the PUBLIC_URL it overrides.
  const hits = [
    ['SUPABASE_URL', env.SUPABASE_URL],
    ['PUBLIC_URL', process.env.CREASE_BASE ?? env.PUBLIC_URL],
  ]
    .map(([name, value]) => [name, value, productionReason(value)])
    .filter(([, , reason]) => reason !== null);
  if (hits.length === 0) return;

  throw new Error(
    `refusing to build a service-role client against production: ${hits
      .map(([name, value, reason]) => `${name}=${value} is the ${reason}`)
      .join('; ')}. ` +
      'These scripts create, mutate and cancel real orders and payments. ' +
      'Set CREASE_ALLOW_PROD=1 to do that on purpose.',
  );
}

export async function makeClient(key, url) {
  const ws = await transport();
  return createClient(url, key, {
    auth: { persistSession: false },
    ...(ws ? { realtime: { transport: ws } } : {}),
  });
}

/** Service-role client from the dispatch service's own .env. */
export async function adminClient() {
  const env = readEnv('services/dispatch/.env');
  assertNotProduction(env);
  return { env, db: await makeClient(env.SUPABASE_SERVICE_ROLE_KEY, env.SUPABASE_URL) };
}
