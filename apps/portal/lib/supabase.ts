import { createServerClient, type CookieOptions } from '@supabase/ssr';
import { cookies } from 'next/headers';

/**
 * Request-scoped Supabase client carrying the staff member's session.
 *
 * Deliberately the anon key, never the service role: every read in the portal
 * runs through RLS, so a cleaner physically cannot query another shop's
 * orders even if a query forgets to filter. The service role stays in the
 * dispatch service where no browser can reach it.
 */
export async function supabaseServer() {
  const cookieStore = await cookies();
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => cookieStore.getAll(),
        setAll: (toSet: { name: string; value: string; options: CookieOptions }[]) => {
          try {
            toSet.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
          } catch {
            // Called from a Server Component, where cookies are read-only.
            // Middleware refreshes the session, so this is safe to swallow.
          }
        },
      },
    },
  );
}

/** Signed-in staff member plus the cleaners they work for. */
export async function currentStaff() {
  const db = await supabaseServer();
  const {
    data: { user },
  } = await db.auth.getUser();
  if (!user) return null;

  const { data: staff } = await db
    .from('cleaner_staff')
    .select('cleaner_id, role, cleaners(id, name, slug, turnaround_hours)')
    .eq('user_id', user.id);

  return { user, staff: staff ?? [] };
}
