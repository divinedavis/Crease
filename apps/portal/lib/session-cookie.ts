/**
 * How the staff session cookie travels, and how long it lives.
 *
 * Shared by the server client and the middleware because the two write the
 * same cookie: if they disagreed, every middleware refresh would quietly
 * rewrite the cookie the server client had just set with different flags.
 * Kept in its own module rather than in lib/supabase.ts so the middleware can
 * import it without pulling `next/headers` into the edge bundle.
 *
 * @supabase/ssr's defaults are a 400-day cookie with no `secure` flag. That is
 * a tablet on a shop counter staying signed in for over a year, and a session
 * token willing to ride a plain-http request if anything ever downgrades one.
 * A week is a generous shift; `secure` is on everywhere except local dev,
 * which has no https to serve it over.
 *
 * httpOnly is deliberately NOT set. app/live-refresh.tsx opens the realtime
 * subscription with createBrowserClient, which reads the session out of
 * document.cookie — turning httpOnly on would sign the browser client out and
 * kill live queue updates with no error anywhere. The tradeoff is accepted:
 * XSS in the portal is game over regardless, since the same script could just
 * drive the authenticated page directly.
 */
export const SESSION_COOKIE_OPTIONS = {
  secure: process.env.NODE_ENV === 'production',
  sameSite: 'lax' as const,
  maxAge: 60 * 60 * 24 * 7,
};
