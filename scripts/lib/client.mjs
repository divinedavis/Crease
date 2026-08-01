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
  return { env, db: await makeClient(env.SUPABASE_SERVICE_ROLE_KEY, env.SUPABASE_URL) };
}
