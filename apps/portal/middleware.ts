import { createServerClient, type CookieOptions } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';
import { SESSION_COOKIE_OPTIONS } from '@/lib/session-cookie';

/**
 * Refreshes the Supabase session cookie on every request and bounces
 * signed-out visitors to /login. Without this the session silently expires
 * mid-shift and intake writes start failing RLS.
 */
export async function middleware(request: NextRequest) {
  let response = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      // The same options the server client writes with. This is the call that
      // rewrites the cookie on every request, so a mismatch here would undo
      // the flags on the very next page load. See lib/session-cookie.ts.
      cookieOptions: SESSION_COOKIE_OPTIONS,
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (toSet: { name: string; value: string; options: CookieOptions }[]) => {
          toSet.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          toSet.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
        },
      },
    },
  );

  const {
    data: { user },
  } = await supabase.auth.getUser();

  // /auth/callback is where Google returns to, carrying the code that becomes
  // the session. Bouncing it to /login for not having a session yet would make
  // signing in impossible — the one request that cannot require being signed
  // in already.
  const path = request.nextUrl.pathname;
  const isPublic = path.startsWith('/login') || path.startsWith('/auth/');

  // An OAuth code that arrives anywhere other than the callback is still a
  // valid code, and dropping it strands somebody on the sign-in page with no
  // error and no session — which is exactly what happened: the provider
  // returned to /login?code=... and the page it landed on had nothing to do
  // with it. Forward it to the one route that knows how to spend it.
  const code = request.nextUrl.searchParams.get('code');
  if (code && !path.startsWith('/auth/')) {
    const url = request.nextUrl.clone();
    url.pathname = '/auth/callback';
    return NextResponse.redirect(url);
  }

  if (!user && !isPublic) {
    const url = request.nextUrl.clone();
    url.pathname = '/login';

    // Behind nginx the standalone server resolves nextUrl against its own
    // listen address, so this redirect went out as localhost:3010 — a dead end
    // in the visitor's browser, which is what every signed-out visitor to
    // crease.divinedavis.com hit. Rebuild the origin — but never from
    // x-forwarded-host. Nothing strips that header, so it is caller-supplied:
    // trusting it turned every signed-out request into an open redirect to
    // whatever host an attacker put in it. PORTAL_PUBLIC_URL is the only
    // source a client cannot reach; the Host header is the fallback, and the
    // vhosts pin it to $host. nginx also rewrites Location as a second line
    // of defence.
    const configured = process.env.PORTAL_PUBLIC_URL?.trim().replace(/\/+$/, '');
    // A typo in the unit file should not 500 every signed-out request, so a
    // value that is not a bare origin is ignored rather than parsed.
    const base = configured && /^https?:\/\/[^/]+$/.test(configured) ? new URL(configured) : null;

    if (base) {
      url.protocol = base.protocol;
      url.host = base.host;
      // The host setter keeps the existing port when the new host omits one,
      // so 3010 survives unless it is cleared explicitly.
      url.port = base.port;
    } else {
      const host = request.headers.get('host');
      if (host) {
        url.protocol = `${request.headers.get('x-forwarded-proto') ?? 'https'}:`;
        url.host = host;
        url.port = '';
      }
    }
    return NextResponse.redirect(url);
  }

  return response;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)'],
};
