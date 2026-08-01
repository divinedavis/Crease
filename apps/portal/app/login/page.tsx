'use client';

import { useActionState } from 'react';
import { signIn } from '../actions';

export default function LoginPage() {
  const [state, action, pending] = useActionState(signIn, null);

  return (
    <div className="shell" style={{ maxWidth: 400, paddingTop: 80 }}>
      <h1 style={{ fontSize: 22, marginBottom: 4 }}>Crease</h1>
      <p style={{ color: 'var(--muted)', marginTop: 0, marginBottom: 28 }}>Cleaner portal</p>

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
        Shop accounts are created by Crease. Ask your account manager if you need access.
      </p>
    </div>
  );
}
