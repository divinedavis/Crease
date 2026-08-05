import Link from 'next/link';
import { redirect } from 'next/navigation';
import { currentStaff, supabaseServer } from '@/lib/supabase';
import { BOARD, money, statusLabel, statusTone } from '@/lib/status';
import { LiveRefresh } from './live-refresh';
import { signOut } from './actions';

export const dynamic = 'force-dynamic';

export default async function QueuePage() {
  const staff = await currentStaff();
  if (!staff) redirect('/login');

  const cleanerIds = staff.staff.map((s) => s.cleaner_id);
  const db = await supabaseServer();

  // RLS already restricts this to the shops this user staffs; the explicit
  // filter is for the query planner and for a readable intent, not security.
  const { data: orders } = await db
    .from('orders')
    .select(
      `id, short_code, status, service_tier, subtotal_cents, estimate_subtotal_cents,
       pickup_window_end, return_window_end, created_at,
       customer:profiles!orders_customer_profile_fkey(full_name),
       order_items(quantity)`,
    )
    .in('cleaner_id', cleanerIds.length ? cleanerIds : ['00000000-0000-0000-0000-000000000000'])
    .not('status', 'in', '(delivered,cancelled)')
    .order('created_at', { ascending: true });

  const rows = orders ?? [];
  const shopName = (staff.staff[0]?.cleaners as any)?.name ?? 'Your shop';

  // The first column that claims a row keeps it. Filtering each column
  // independently would draw a drop-off under both "Expecting a drop-off" and
  // "Waiting on a courier" — the same bag twice, once with a driver attached
  // that nobody booked.
  const columns = BOARD.map((col) => ({ col, inCol: [] as typeof rows }));
  for (const o of rows) {
    columns
      .find(
        ({ col }) => col.statuses.includes(o.status) && (!col.tier || col.tier === o.service_tier),
      )
      ?.inCol.push(o);
  }

  return (
    <div className="shell">
      <LiveRefresh cleanerIds={cleanerIds} />

      <header className="top">
        <div>
          <h1>{shopName}</h1>
          <div className="who">{staff.user.email}</div>
        </div>
        <form action={signOut}>
          <button type="submit">Sign out</button>
        </form>
      </header>

      {cleanerIds.length === 0 && (
        <div className="notice warn">
          This account is not linked to a shop yet. Contact your Crease account manager.
        </div>
      )}

      {columns.map(({ col, inCol }) => {
        // "Needs attention" is noise when empty; the working columns are not.
        if (inCol.length === 0 && !col.empty) return null;

        return (
          <section className="group" key={col.title}>
            <h2>
              {col.title}
              {inCol.length > 0 && ` · ${inCol.length}`}
            </h2>

            {inCol.length === 0 ? (
              <div className="card empty">{col.empty}</div>
            ) : (
              <div className="queue">
                {inCol.map((o) => {
                  const counted = (o.order_items ?? []).reduce(
                    (n: number, i: any) => n + i.quantity,
                    0,
                  );
                  return (
                    <Link href={`/orders/${o.id}`} className="order-row" key={o.id}>
                      <span className="code">{o.short_code}</span>
                      <span>
                        <div className="who">
                          {(o.customer as any)?.full_name ?? 'Customer'}
                        </div>
                        <div className="sub">
                          {counted > 0
                            ? `${counted} garment${counted === 1 ? '' : 's'}`
                            : 'Not counted yet'}
                          {' · '}
                          <span className={`pill ${statusTone(o.status)}`}>
                            {statusLabel(o.status, o.service_tier)}
                          </span>
                        </div>
                      </span>
                      <span className="money">
                        {money(o.subtotal_cents ?? o.estimate_subtotal_cents)}
                        {o.subtotal_cents == null && (
                          <div className="sub" style={{ fontWeight: 400 }}>
                            est.
                          </div>
                        )}
                      </span>
                    </Link>
                  );
                })}
              </div>
            )}
          </section>
        );
      })}
    </div>
  );
}
