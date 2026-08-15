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
      allowedOrigins: ['portal.usecreaseapp.com', 'crease.divinedavis.com'],
    },
  },
  // Nothing gains from telling a scanner which framework version to look up.
  poweredByHeader: false,
};
