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

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '0.0.0.0']);

/** Whether a URL points at this machine. An absent value points nowhere. */
function isLocalTarget(value) {
  if (!value) return true;
  try {
    // IPv6 hostnames come back bracketed, and '[::1]' is not '::1'.
    return LOCAL_HOSTS.has(new URL(value).hostname.replace(/^\[|\]$/g, ''));
  } catch {
    return false;
  }
}

/**
 * Refuse to aim a service-role credential at a live stack by accident.
 *
 * The deploy rsyncs this whole repo onto the droplet, where
 * services/dispatch/.env is *production* — so `node scripts/e2e-money.mjs`
 * typed in that directory books couriers, moves money and rewrites real
 * customers' orders with the production service-role key, and nothing on the
 * command line hints at it. Localhost is the only target that needs no
 * thought; anything else has to be asked for out loud.
 */
export function assertLocalTarget(env) {
  if (process.env.CREASE_ALLOW_PROD === '1') return;
  // CREASE_BASE is what the e2e scripts actually fetch when it is set, so it
  // is the value worth checking rather than the PUBLIC_URL it overrides.
  const remote = [
    ['SUPABASE_URL', env.SUPABASE_URL],
    ['PUBLIC_URL', process.env.CREASE_BASE ?? env.PUBLIC_URL],
  ].filter(([, value]) => !isLocalTarget(value));
  if (remote.length === 0) return;

  throw new Error(
    `refusing to build a service-role client: ${remote
      .map(([name, value]) => `${name}=${value}`)
      .join(', ')} is not localhost. ` +
      'Set CREASE_ALLOW_PROD=1 to run this against a non-local stack on purpose.',
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
  assertLocalTarget(env);
  return { env, db: await makeClient(env.SUPABASE_SERVICE_ROLE_KEY, env.SUPABASE_URL) };
}
