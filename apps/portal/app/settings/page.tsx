import Link from 'next/link';
import { redirect } from 'next/navigation';
import { currentStaff, supabaseServer } from '@/lib/supabase';
import { hoursByDay } from '@/lib/hours';
import { ShopDetailsForm, HoursForm, PayoutPanel } from './settings-forms';

export const dynamic = 'force-dynamic';

/**
 * The shop's own facts: where couriers are sent, when they may arrive, and
 * where the money goes. One page because a cleaner sets these once at
 * onboarding and then only when something in the real world changes.
 */
export default async function SettingsPage({
  searchParams,
}: {
  searchParams: Promise<{ payouts?: string }>;
}) {
  const staff = await currentStaff();
  if (!staff) redirect('/login');

  const cleanerId = staff.staff[0]?.cleaner_id;
  const db = await supabaseServer();
  const { data: shop } = cleanerId
    ? await db
        .from('cleaners')
        .select(
          `id, name, phone, email, line1, line2, city, state, postal_code,
           turnaround_hours, hours, stripe_account_id, payouts_enabled`,
        )
        .eq('id', cleanerId)
        .maybeSingle()
    : { data: null };

  const { payouts } = await searchParams;

  return (
    <div className="shell">
      <header className="top">
        <div>
          <h1>Settings</h1>
          <div className="who">{shop?.name ?? staff.user.email}</div>
        </div>
        <Link href="/" className="btn">
          Back to orders
        </Link>
      </header>

      {!shop ? (
        <div className="notice warn">
          This account is not linked to a shop yet. Contact your Crease account manager.
        </div>
      ) : (
        <>
          {payouts === 'done' && (
            <div className="notice ok">
              Stripe onboarding finished. Press “Check status” below to confirm payouts are on.
            </div>
          )}
          {payouts === 'expired' && (
            <div className="notice warn">
              That Stripe link expired before onboarding finished. Start it again below.
            </div>
          )}

          <ShopDetailsForm shop={shop} />
          <HoursForm
            cleanerId={shop.id}
            byDay={Object.fromEntries(hoursByDay(shop.hours))}
          />
          <PayoutPanel
            cleanerId={shop.id}
            hasAccount={Boolean(shop.stripe_account_id)}
            payoutsEnabled={Boolean(shop.payouts_enabled)}
          />
        </>
      )}
    </div>
  );
}
