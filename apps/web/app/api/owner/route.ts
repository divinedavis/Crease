import { promises as fs } from 'node:fs';
import path from 'node:path';
import { NextResponse } from 'next/server';

/**
 * "This device is mine, stop counting it."
 *
 * A hand-kept list of owner IPs loses the moment a phone changes network, and
 * the traffic tile then reports the person building the site as an audience.
 * Visiting /?owner=1 registers whatever address the request came from, and the
 * cookie it sets re-registers automatically from every new network that device
 * later joins. NEMO's dashboard has worked this way for a year; this is the
 * same idea against an nginx log that records no cookies.
 *
 * /?owner=0 forgets the address again.
 */
const STORE = process.env.CREASE_OWNER_FILE ?? '/var/lib/crease/owner-ips.json';
const COOKIE = 'crease_owner';
const MAX_IPS = 50;
// An address is remembered for a fortnight, not forever.
//
// A marked device re-registers on every visit, so a machine still in use never
// falls off this list. What does fall off is the address it borrowed: an
// iPhone on iCloud Private Relay leaves through a Cloudflare or Fastly node
// shared with thousands of other people, and a permanent entry would go on
// hiding whichever stranger inherits it next week. Forgetting is the only
// thing that keeps this list about devices rather than about networks.
const TTL_DAYS = 14;

interface Entry {
  ip: string;
  at: string;
}

/** Tolerates the original shape, a bare array of addresses with no dates. */
function normalise(body: unknown, now: number): Entry[] {
  const raw = Array.isArray((body as any)?.ips) ? (body as any).ips : [];
  const cutoff = now - TTL_DAYS * 86400_000;
  const out: Entry[] = [];
  for (const item of raw) {
    if (typeof item === 'string') {
      out.push({ ip: item, at: new Date(now).toISOString() });
      continue;
    }
    const ip = String((item as any)?.ip ?? '');
    const at = String((item as any)?.at ?? '');
    if (!ip) continue;
    const seen = Date.parse(at);
    if (Number.isFinite(seen) && seen < cutoff) continue;
    out.push({ ip, at: Number.isFinite(seen) ? at : new Date(now).toISOString() });
  }
  return out;
}

function callerIp(request: Request): string | null {
  // nginx sets both; the left-most X-Forwarded-For entry is caller-controlled,
  // so X-Real-IP — which nginx writes itself from the socket — is the one to
  // trust. Getting this backwards is how an attacker adds anybody they like.
  const real = request.headers.get('x-real-ip');
  if (real && /^[0-9a-f.:]+$/i.test(real)) return real;
  return null;
}

async function read(now: number): Promise<Entry[]> {
  try {
    return normalise(JSON.parse(await fs.readFile(STORE, 'utf8')), now);
  } catch {
    return [];
  }
}

async function write(entries: Entry[]) {
  await fs.mkdir(path.dirname(STORE), { recursive: true });
  await fs.writeFile(STORE, JSON.stringify({ ips: entries.slice(-MAX_IPS) }, null, 2));
}

export async function GET(request: Request) {
  const on = new URL(request.url).searchParams.get('owner') !== '0';
  const ip = callerIp(request);
  if (!ip) return NextResponse.json({ ok: false, reason: 'no_ip' }, { status: 400 });

  const now = Date.now();
  const entries = await read(now);
  const others = entries.filter((e) => e.ip !== ip);
  // Re-registering refreshes the date, which is what keeps a device in use on
  // the list while the addresses it has stopped using drop off it.
  await write(on ? [...others, { ip, at: new Date(now).toISOString() }] : others);

  // Back to the page they were on, so the whole thing is one click and a
  // confirmation they can read rather than a JSON body.
  //
  // Built from the forwarded host, not request.url: behind the proxy the app
  // knows itself as localhost:3020, and redirecting there sends the visitor to
  // a machine that is not theirs.
  const host = request.headers.get('host') ?? 'creasenyc.com';
  const proto = request.headers.get('x-forwarded-proto') ?? 'https';
  const back = new URL(`${proto}://${host}/`);
  back.searchParams.set('owner_set', on ? '1' : '0');
  const res = NextResponse.redirect(back, { status: 303 });
  res.cookies.set(COOKIE, on ? '1' : '', {
    httpOnly: true,
    sameSite: 'lax',
    secure: true,
    path: '/',
    maxAge: on ? 60 * 60 * 24 * 365 * 5 : 0,
  });
  return res;
}
