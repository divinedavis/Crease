'use client';

import { createBrowserClient } from '@supabase/ssr';
import { useActionState, useState } from 'react';
import { signIn } from '../actions';
import { SESSION_COOKIE_OPTIONS } from '@/lib/session-cookie';

export default function LoginPage() {
  const [state, action, pending] = useActionState(signIn, null);
  const [googling, setGoogling] = useState(false);

  // One tap, no password to type on a counter tablet. The password form stays
  // underneath for the shop account, which has no Google identity.
  async function withGoogle() {
    setGoogling(true);
    const supabase = createBrowserClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      { cookieOptions: SESSION_COOKIE_OPTIONS },
    );
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: `${window.location.origin}/auth/callback` },
    });
    if (error) setGoogling(false);
  }

  const params = typeof window === 'undefined' ? null : new URLSearchParams(window.location.search);
  const oauthError = params?.get('error');

  return (
    <div className="shell" style={{ maxWidth: 400, paddingTop: 80 }}>
      <h1 style={{ fontSize: 22, marginBottom: 4 }}>Crease</h1>
      <p style={{ color: 'var(--muted)', marginTop: 0, marginBottom: 28 }}>Cleaner portal</p>

      <div className="card" style={{ marginBottom: 14 }}>
        {oauthError === 'not_staff' && (
          <div className="notice danger">
            That Google account isn&rsquo;t attached to a shop yet. Ask Crease to add it.
          </div>
        )}
        {oauthError === 'exchange_failed' && (
          <div className="notice danger">Google sign-in didn&rsquo;t complete. Try again.</div>
        )}
        {oauthError === 'wrong_host' && (
          <div className="notice danger">
            Google sent you back to a different address than you started from, so the sign-in
            couldn&rsquo;t be completed here. Start again from{' '}
            <a href="https://portal.creasenyc.com/login">portal.creasenyc.com</a>.
          </div>
        )}
        <button
          type="button"
          className="primary"
          onClick={withGoogle}
          disabled={googling}
          style={{ width: '100%' }}
        >
          {googling ? 'Opening Google…' : 'Continue with Google'}
        </button>
      </div>

      <form action={action} className="card">
        {state?.error && <div className="notice danger">{state.error}</div>}
        <div className="field">
          <label htmlFor="email">Email</label>
          <input id="email" name="email" type="email" autoComplete="username" required autoFocus />
        </div>
        <div className="field">
          <label htmlFor="password">Password</label>
          <input
            id="password"
            name="password"
            type="password"
            autoComplete="current-password"
            required
          />
        </div>
        <button className="primary" type="submit" disabled={pending} style={{ width: '100%' }}>
          {pending ? 'Signing in…' : 'Sign in'}
        </button>
      </form>

      <p style={{ color: 'var(--muted)', fontSize: 13, marginTop: 20 }}>
        Google is the quickest way in. The email and password below are for shop accounts that
        have no Google identity — created by Crease, so ask if you need access.
      </p>
    </div>
  );
}
