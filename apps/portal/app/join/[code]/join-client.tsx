'use client';

import { createBrowserClient } from '@supabase/ssr';
import { useActionState, useState } from 'react';
import { claimShop } from '../actions';
import { JOIN_COOKIE } from '@/lib/join';
import { SESSION_COOKIE_OPTIONS } from '@/lib/session-cookie';

/**
 * Google sign-in that comes back to this join page instead of the queue.
 *
 * The code rides in a short-lived cookie rather than in redirectTo: the
 * callback URL Supabase is allowed to return to stays exactly the one the
 * login page already uses, and the callback only ever turns that cookie into
 * a /join/<12 hex> path (lib/join.ts), so it cannot become an open redirect.
 */
export function GoogleJoinButton({ code }: { code: string }) {
  const [busy, setBusy] = useState(false);

  async function go() {
    setBusy(true);
    const secure = window.location.protocol === 'https:' ? '; Secure' : '';
    document.cookie = `${JOIN_COOKIE}=${code}; Max-Age=900; Path=/; SameSite=Lax${secure}`;
    const supabase = createBrowserClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      { cookieOptions: SESSION_COOKIE_OPTIONS },
    );
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: `${window.location.origin}/auth/callback` },
    });
    if (error) setBusy(false);
  }

  return (
    <button type="button" className="primary" onClick={go} disabled={busy} style={{ width: '100%' }}>
      {busy ? 'Opening Google…' : 'Continue with Google'}
    </button>
  );
}

type Defaults = {
  name: string;
  line1: string;
  city: string;
  state: string;
  postal_code: string;
  phone: string;
};

export function JoinForm({ code, email, defaults }: { code: string; email: string; defaults: Defaults }) {
  const [state, action, pending] = useActionState(claimShop.bind(null, code), null);

  return (
    <form action={action} className="card">
      <p style={{ marginTop: 0, color: 'var(--muted)' }}>
        Signed in as <strong>{email}</strong>. This login will run your shop on Crease.
      </p>
      {state?.error && <div className="notice danger">{state.error}</div>}

      <div className="field">
        <label htmlFor="name">Shop name</label>
        <input id="name" name="name" defaultValue={defaults.name} required maxLength={120} />
      </div>
      <div className="field">
        <label htmlFor="phone">Shop phone</label>
        <input id="phone" name="phone" type="tel" inputMode="tel" defaultValue={defaults.phone} required />
      </div>
      <div className="field">
        <label htmlFor="line1">Street address</label>
        <input id="line1" name="line1" defaultValue={defaults.line1} required autoComplete="address-line1" />
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1.2fr', gap: 10 }}>
        <div className="field">
          <label htmlFor="city">City</label>
          <input id="city" name="city" defaultValue={defaults.city} required />
        </div>
        <div className="field">
          <label htmlFor="state">State</label>
          <input id="state" name="state" defaultValue={defaults.state} required maxLength={2} />
        </div>
        <div className="field">
          <label htmlFor="postal_code">ZIP</label>
          <input id="postal_code" name="postal_code" inputMode="numeric" defaultValue={defaults.postal_code} required maxLength={5} />
        </div>
      </div>

      <h3 style={{ marginBottom: 6 }}>Wash &amp; fold</h3>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
        <div className="field">
          <label htmlFor="price_per_lb">Price per lb ($)</label>
          <input id="price_per_lb" name="price_per_lb" inputMode="decimal" placeholder="1.25" required />
        </div>
        <div className="field">
          <label htmlFor="minimum_lbs">Minimum lbs</label>
          <input id="minimum_lbs" name="minimum_lbs" inputMode="decimal" placeholder="10" />
        </div>
        <div className="field">
          <label htmlFor="turnaround_hours">Ready in (hours)</label>
          <input id="turnaround_hours" name="turnaround_hours" inputMode="numeric" defaultValue="24" />
        </div>
      </div>

      <button className="primary" type="submit" disabled={pending} style={{ width: '100%', marginTop: 8 }}>
        {pending ? 'Signing up…' : 'Sign up my shop'}
      </button>
      <p style={{ color: 'var(--muted)', fontSize: 13, marginBottom: 0 }}>
        Customers won’t see your shop until Crease switches it on. You can change any of this later in
        Settings.
      </p>
    </form>
  );
}
