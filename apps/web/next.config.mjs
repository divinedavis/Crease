// The portal talks to exactly one origin it does not serve itself. Read from
// the same variable the browser client is built with so a project move cannot
// leave the policy pointing at the old one.
const supabaseOrigin = (() => {
  try {
    return new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? '').origin;
  } catch {
    // Not configured (a bare `next build` in CI): leave it out rather than
    // emitting a broken source expression.
    return '';
  }
})();

/**
 * The policy the app carries itself. Same values as the portal's, for the same
 * reasons — see apps/portal/next.config.mjs.
 *
 * These are set on the nginx vhost too, and were only set there — so the repo
 * said nothing about what the portal's headers are, and a vhost edited on the
 * box (or a second deployment target) silently ships different ones. Values
 * are deliberately identical to deploy/nginx-app-domains.conf: a doubled
 * header with the same value is harmless, whereas two different X-Frame-Options
 * make browsers pick the stricter one and break the page.
 *
 * HSTS stays nginx-only on purpose. It belongs to the TLS terminator, and the
 * app also answers on plain http over loopback where the header is meaningless.
 */
const securityHeaders = [
  { key: 'X-Frame-Options', value: 'SAMEORIGIN' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  // Geolocation is allowed: a customer on a phone asking "do you reach me"
  // should be able to answer with the button rather than typing their address.
  // Nothing else is used.
  {
    key: 'Permissions-Policy',
    value: 'accelerometer=(), camera=(), geolocation=(self), gyroscope=(), microphone=(), payment=(), usb=()',
  },
  {
    // Report-Only, and it stays that way until the reports come back empty.
    // Next inlines its bootstrap and hydration payload, so an enforced policy
    // without a per-request nonce takes the portal down on the first page —
    // which on a shift means intake stops. 'unsafe-inline' is here for the
    // same reason; the value of the header today is that the allowed origins
    // are written down in the repo and drift becomes visible.
    key: 'Content-Security-Policy-Report-Only',
    value: [
      "default-src 'self'",
      "base-uri 'self'",
      "object-src 'none'",
      "frame-ancestors 'self'",
      "form-action 'self'",
      "img-src 'self' data: blob:",
      "font-src 'self' data:",
      "style-src 'self' 'unsafe-inline'",
      "script-src 'self' 'unsafe-inline'",
      ["connect-src 'self'", supabaseOrigin].filter(Boolean).join(' '),
    ].join('; '),
  },
];

/** @type {import('next').NextConfig} */
export default {
  reactStrictMode: true,
  // The droplet is shared with five other sites and has roughly 1GB of
  // headroom. Standalone output ships only the traced dependencies, which
  // keeps the portal's resident footprint well below a full install.
  output: 'standalone',
  // Next's Server Action CSRF check compares Origin against the forwarded
  // host, which is caller-supplied behind this proxy — a request carrying
  // Origin: evil.tld and X-Forwarded-Host: evil.tld satisfied it. An explicit
  // allowlist takes the header out of the decision entirely.
  experimental: {
    serverActions: {
      // creasenyc.com is the name the business goes by; usecreaseapp.com is
      // kept because it is in the wild — links, the App Store record, and
      // every build already shipped. An origin missing from this list has its
      // server actions refused, which on this site means the coverage check
      // silently does nothing.
      allowedOrigins: [
        'creasenyc.com',
        'www.creasenyc.com',
        'usecreaseapp.com',
        'www.usecreaseapp.com',
      ],
    },
  },
  // Nothing gains from telling a scanner which framework version to look up.
  poweredByHeader: false,
  async headers() {
    return [{ source: '/:path*', headers: securityHeaders }];
  },
};
