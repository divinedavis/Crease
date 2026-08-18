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

function callerIp(request: Request): string | null {
  // nginx sets both; the left-most X-Forwarded-For entry is caller-controlled,
  // so X-Real-IP — which nginx writes itself from the socket — is the one to
  // trust. Getting this backwards is how an attacker adds anybody they like.
  const real = request.headers.get('x-real-ip');
  if (real && /^[0-9a-f.:]+$/i.test(real)) return real;
  return null;
}

async function read(): Promise<string[]> {
  try {
    const raw = await fs.readFile(STORE, 'utf8');
    const body = JSON.parse(raw);
    return Array.isArray(body.ips) ? body.ips.map(String) : [];
  } catch {
    return [];
  }
}

async function write(ips: string[]) {
  await fs.mkdir(path.dirname(STORE), { recursive: true });
  await fs.writeFile(STORE, JSON.stringify({ ips: ips.slice(-MAX_IPS) }, null, 2));
}

export async function GET(request: Request) {
  const on = new URL(request.url).searchParams.get('owner') !== '0';
  const ip = callerIp(request);
  if (!ip) return NextResponse.json({ ok: false, reason: 'no_ip' }, { status: 400 });

  const ips = await read();
  const next = on ? [...new Set([...ips, ip])] : ips.filter((x) => x !== ip);
  await write(next);

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
