import { createServerClient, type CookieOptions } from '@supabase/ssr';
import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';
import { SESSION_COOKIE_OPTIONS } from '@/lib/session-cookie';
import { publicOrigin } from '@/lib/public-origin';

/**
 * Where Google sends somebody back to.
 *
 * The OAuth code is exchanged here, server-side, and the session lands in the
 * same cookie the password flow writes — so everything downstream (middleware,
 * RLS, the realtime client) is unchanged and there is exactly one kind of
 * session in this app.
 *
 * Being signed in is not being allowed in: the portal shows one shop's
 * customers, their addresses and their handoff PINs, and RLS scopes that by
 * cleaner_staff. A Google account nobody has added to a shop gets a page that
 * says so rather than an empty queue that looks broken.
 */
export async function GET(request: Request) {
  const url = new URL(request.url);
  const code = url.searchParams.get('code');
  // Behind the proxy the app knows itself as localhost:3010, so the browser has
  // to be sent back to a real origin. Take it from PORTAL_PUBLIC_URL rather
  // than the Host header: this route is where a freshly authenticated visitor
  // lands, and a redirect built from a caller-supplied header would hand that
  // visitor to whatever host the caller named. middleware.ts and
  // settings/actions.ts already resolve it this way; this route did not.
  const origin = publicOrigin(request.headers);

  if (!code) {
    return NextResponse.redirect(`${origin}/login?error=missing_code`);
  }

  const jar = await cookies();
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookieOptions: SESSION_COOKIE_OPTIONS,
      cookies: {
        getAll: () => jar.getAll(),
        setAll: (toSet: { name: string; value: string; options: CookieOptions }[]) => {
          toSet.forEach(({ name, value, options }) => jar.set(name, value, options));
        },
      },
    },
  );

  const { error } = await supabase.auth.exchangeCodeForSession(code);
  if (error) {
    // The most common cause is not a bad code but a code redeemed on the wrong
    // host: PKCE stores its verifier in a cookie on the origin the flow began
    // from, so a provider that returns to a different one arrives with a valid
    // code and no way to prove it asked for it. Say which host is complaining,
    // because that is the whole diagnosis.
    console.error('[portal] oauth exchange failed', {
      host,
      reason: error.message,
      hasVerifierCookie: jar.getAll().some((c) => c.name.includes('code-verifier')),
    });
    const why = jar.getAll().some((c) => c.name.includes('code-verifier'))
      ? 'exchange_failed'
      : 'wrong_host';
    return NextResponse.redirect(`${origin}/login?error=${why}`);
  }

  // Signed in, but is this person staff anywhere? RLS answers honestly: a
  // stranger sees zero shops, and zero shops is a locked door, not an empty
  // shift.
  const { data: staff } = await supabase.from('cleaner_staff').select('cleaner_id').limit(1);
  if (!staff || staff.length === 0) {
    await supabase.auth.signOut();
    return NextResponse.redirect(`${origin}/login?error=not_staff`);
  }

  return NextResponse.redirect(origin + '/');
}
