import Link from 'next/link';
import { redirect } from 'next/navigation';
import { currentStaff, supabaseServer } from '@/lib/supabase';
import { BOARD, money, statusLabel, statusTone } from '@/lib/status';
import { isPastDue } from '@/lib/ready';
import { LiveRefresh } from './live-refresh';
import { signOut } from './actions';

export const dynamic = 'force-dynamic';

/** Rows shown before a long queue folds behind "show more". */
const FOLD_AT = 6;

/** Statuses where the garments are physically in the shop's custody. */
const IN_SHOP = ['at_cleaner', 'awaiting_approval', 'cleaning', 'ready'];

const anchorId = (title: string) => 'q-' + title.toLowerCase().replace(/[^a-z0-9]+/g, '-');

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
       pickup_window_end, return_window_end, estimated_ready_at, created_at,
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

  // The glanceable layer: the counts a shop reads between customers, plus the
  // one money number that means anything mid-shift — the value of what is
  // physically on the racks right now. Estimates stand in until a bag is
  // counted, which is exactly the promise the customer was shown.
  const tiles = columns
    .filter(({ col, inCol }) => col.tile && (col.tone !== 'danger' || inCol.length > 0))
    .map(({ col, inCol }) => ({
      title: col.title,
      tone: col.tone ?? 'neutral',
      count: inCol.length,
      href: `#${anchorId(col.title)}`,
    }));
  const inShopCents = rows
    .filter((o) => IN_SHOP.includes(o.status))
    .reduce((n, o) => n + (o.subtotal_cents ?? o.estimate_subtotal_cents ?? 0), 0);

  const orderRow = (o: (typeof rows)[number]) => {
    const counted = (o.order_items ?? []).reduce((n: number, i: any) => n + i.quantity, 0);
    return (
      <Link href={`/orders/${o.id}`} className="order-row" key={o.id}>
        <span className="code">{o.short_code}</span>
        <span>
          <div className="who">{(o.customer as any)?.full_name ?? 'Customer'}</div>
          <div className="sub">
            {counted > 0 ? `${counted} garment${counted === 1 ? '' : 's'}` : 'Not counted yet'}
            {' · '}
            <span className={`pill ${statusTone(o.status)}`}>
              {statusLabel(o.status, o.service_tier)}
            </span>
            {/* Only on the rack. Everything else is waiting on someone who is
                not the shop, and flagging those would put a red pill on work
                nobody here can move. */}
            {o.status === 'cleaning' && isPastDue(o.estimated_ready_at) && (
              <>
                {' · '}
                <span className="pill danger">Past due</span>
              </>
            )}
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
  };

  return (
    <div className="shell">
      <LiveRefresh cleanerIds={cleanerIds} />

      <header className="top">
        <div>
          <h1>{shopName}</h1>
          <div className="who">{staff.user.email}</div>
        </div>
        <div className="row-actions">
          <Link href="/settings" className="btn">
            Settings
          </Link>
          <form action={signOut}>
            <button type="submit">Sign out</button>
          </form>
        </div>
      </header>

      {cleanerIds.length === 0 && (
        <div className="notice warn">
          This account is not linked to a shop yet. Contact your Crease account manager.
        </div>
      )}

      {cleanerIds.length > 0 && (
        <div className="stats">
          {tiles.map((t) => (
            <a className="stat" href={t.href} key={t.title}>
              <span className="stat-num">
                <i className={`dot ${t.tone}`} aria-hidden />
                {t.count}
              </span>
              <span className="stat-label">{t.title}</span>
            </a>
          ))}
          <div className="stat">
            <span className="stat-num">{money(inShopCents)}</span>
            <span className="stat-label">In the shop</span>
          </div>
        </div>
      )}

      <div className="board">
        {columns.map(({ col, inCol }) => {
          // "Needs attention" is noise when empty; the working columns are not.
          if (inCol.length === 0 && !col.empty) return null;

          const heading = (
            <>
              {col.title}
              {inCol.length > 0 && ` · ${inCol.length}`}
            </>
          );

          // Not this counter's work: present, countable, folded away.
          if (col.background) {
            return (
              <details className="panel background" id={anchorId(col.title)} key={col.title}>
                <summary>
                  <h2>{heading}</h2>
                </summary>
                <div className="queue">{inCol.map(orderRow)}</div>
              </details>
            );
          }

          return (
            <section className="panel" id={anchorId(col.title)} key={col.title}>
              <h2>{heading}</h2>
              {inCol.length === 0 ? (
                <div className="empty">{col.empty}</div>
              ) : (
                <div className="queue">
                  {inCol.slice(0, FOLD_AT).map(orderRow)}
                  {inCol.length > FOLD_AT && (
                    <details className="more">
                      <summary>Show {inCol.length - FOLD_AT} more</summary>
                      {inCol.slice(FOLD_AT).map(orderRow)}
                    </details>
                  )}
                </div>
              )}
            </section>
          );
        })}
      </div>
    </div>
  );
}
