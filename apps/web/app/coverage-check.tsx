'use client';

import { useActionState, useEffect, useState } from 'react';
import { checkCoverage, joinWaitlist, type CheckResult } from './actions';

/** A per-browser id so three tries at one address are not three households. */
function sessionRef(): string {
  if (typeof window === 'undefined') return '';
  const existing = window.localStorage.getItem('crease.session');
  if (existing) return existing;
  const made = Math.random().toString(36).slice(2) + Date.now().toString(36);
  window.localStorage.setItem('crease.session', made);
  return made;
}

/**
 * The question every visitor actually has.
 *
 * It is the first thing on the page rather than a footer form, because the
 * answer decides everything else they read — and because the asking is what
 * tells us where in Brooklyn to sign the next shop.
 */
export function CoverageCheck({ appStoreUrl }: { appStoreUrl: string | null }) {
  const [session, setSession] = useState('');
  useEffect(() => setSession(sessionRef()), []);

  const [result, check, checking] = useActionState<CheckResult | null, FormData>(
    checkCoverage,
    null,
  );

  return (
    <div className="check">
      <form action={check} className="check-row">
        <input
          type="text"
          name="address"
          required
          autoComplete="street-address"
          placeholder="Your street address, e.g. 251 Dekalb Ave"
          aria-label="Your street address in Brooklyn"
        />
        <input type="hidden" name="session" value={session} />
        <button type="submit" disabled={checking}>
          {checking ? 'Checking…' : 'Check my address'}
        </button>
      </form>

      {result && <Answer result={result} appStoreUrl={appStoreUrl} />}


    </div>
  );
}

function Answer({ result, appStoreUrl }: { result: CheckResult; appStoreUrl: string | null }) {
  const covered = result.status === 'covered';
  return (
    <div className={covered ? 'answer yes' : 'answer'}>
      <h3>
        {covered ? "We're in your neighborhood" : result.status === 'error' ? 'Try again' : 'Not yet'}
      </h3>
      <p>{result.message}</p>

      {covered ? (
        <div className="cta">
          <a href="/order">Start an order</a>
          {appStoreUrl && (
            <a className="ghost" href={appStoreUrl}>
              Get the iPhone app
            </a>
          )}
        </div>
      ) : (
        result.status !== 'error' && <Waitlist pingId={result.pingId} />
      )}
    </div>
  );
}

function Waitlist({ pingId }: { pingId?: string }) {
  const [state, join, joining] = useActionState<{ ok: boolean; message: string } | null, FormData>(
    joinWaitlist,
    null,
  );

  if (state?.ok) return <p className="fine">{state.message}</p>;

  return (
    <>
      <form action={join} className="check-row" style={{ marginTop: 12 }}>
        <input
          type="email"
          name="email"
          required
          autoComplete="email"
          placeholder="you@email.com"
          aria-label="Email address"
        />
        <input type="hidden" name="pingId" value={pingId ?? ''} />
        <button type="submit" disabled={joining}>
          {joining ? 'Saving…' : 'Tell me when you reach me'}
        </button>
      </form>
      {state && !state.ok && <p className="fine">{state.message}</p>}
    </>
  );
}
