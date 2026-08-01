/** @type {import('next').NextConfig} */
export default {
  reactStrictMode: true,
  // The dispatch key and service-role key must never reach the browser bundle;
  // every write goes through a server action.
  serverExternalPackages: [],
};
