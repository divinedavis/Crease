import { createClient } from '@supabase/supabase-js';

/**
 * The service-role client, server-side only.
 *
 * The web site has no accounts and no sessions — somebody checking whether we
 * reach their street is not asked to sign in for the privilege. So the writes
 * it makes are made with the service key from a server action, never from the
 * browser, and the only table it touches is demand_pings.
 */
export function serviceClient() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return null;
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
