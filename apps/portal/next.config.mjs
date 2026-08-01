/** @type {import('next').NextConfig} */
export default {
  reactStrictMode: true,
  // The droplet is shared with five other sites and has roughly 1GB of
  // headroom. Standalone output ships only the traced dependencies, which
  // keeps the portal's resident footprint well below a full install.
  output: 'standalone',
};
