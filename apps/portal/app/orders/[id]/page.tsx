import Link from 'next/link';
import { notFound, redirect } from 'next/navigation';
import { currentStaff, supabaseServer } from '@/lib/supabase';
import { LEG_LABEL, TIER_LABEL, money, statusLabel, statusTone } from '@/lib/status';
import { DEFAULT_TURNAROUND_HOURS, isPastDue, readyRangeLabel } from '@/lib/ready';
import { LiveRefresh } from '@/app/live-refresh';
import { ConfirmReturn } from './confirm-return';
import { IntakeForm } from './intake-form';
import { ActionsPanel } from './actions-panel';

export const dynamic = 'force-dynamic';

export default async function OrderPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const staff = await currentStaff();
  if (!staff) redirect('/login');

  const db = await supabaseServer();

  // RLS scopes this to shops the user staffs, so a guessed id 404s rather
  // than leaking another shop's customer.
  const { data: order } = await db
    .from('orders')
    .select(
      `*,
       customer:profiles!orders_customer_profile_fkey(full_name, phone),
       order_items(id, service_item_id, label, quantity, unit_price_cents),
       delivery_legs(id, leg, status, provider, courier_name, courier_vehicle,
                     tracking_url, fee_cents, attempt, last_error, created_at, completed_at)`,
    )
    .eq('id', id)
    .maybeSingle();

  if (!order) notFound();

  // Scoped to the service the customer actually booked. A shop's laundry and
  // dry cleaning share one price list, and showing both here would put a
  // per-pound rate in a per-garment quantity box — a 10x error that looks
  // like a normal number.
  const { data: services } = await db
    .from('service_items')
    .select('id, label, unit_price_cents, unit, minimum_units, turnaround_hours')
    .eq('cleaner_id', order.cleaner_id)
    .eq('service_type', order.service_type)
    .eq('active', true)
    .order('sort_order');

  // The shop's own speed, for the services that do not override it. Taken from
  // the staff record rather than re-queried: the session already carries every
  // shop this user works for.
  const shop = staff.staff.find((s) => s.cleaner_id === order.cleaner_id)?.cleaners as any;
  const shopTurnaroundHours = Number(shop?.turnaround_hours) || DEFAULT_TURNAROUND_HOURS;

  // The pickup window is spent the moment the bag is on the counter, so what
  // the customer is watching from here on is the ready estimate. Shown only
  // while it is still a promise — once ready_at exists it is a fact, and a
  // stale guess sitting next to it invites the counter to quote the wrong one.
  const readyRange = ['at_cleaner', 'awaiting_approval', 'cleaning'].includes(order.status)
    ? readyRangeLabel(order.estimated_ready_at)
    : null;
  const readyPastDue = readyRange !== null && isPastDue(order.estimated_ready_at);

  const initial: Record<string, number> = {};
  for (const item of order.order_items ?? []) {
    if (item.service_item_id) initial[item.service_item_id] = item.quantity;
  }

  const legs = [...(order.delivery_legs ?? [])].sort(
    (a: any, b: any) => +new Date(a.created_at) - +new Date(b.created_at),
  );

  // What the ready estimate is measured from, and the same leg the dispatcher
  // asks. A preview anchored on this render instead would read hours later than
  // the number saving actually writes, and the counter would watch the promise
  // jump the moment they pressed save.
  const arrivedAtMs =
    Date.parse(
      legs.filter((l: any) => l.leg === 'pickup' && l.status === 'delivered').pop()
        ?.completed_at ?? '',
    ) || Date.now();

  // A drop-off has no courier leg to carry it into 'at_cleaner' — the customer
  // walks it in — so the counter counting the bag is the event that proves it
  // arrived. Without this the order sits at 'scheduled' with nothing on the
  // screen that can move it, waiting on a driver that was never booked.
  // A return has nothing to count. The clothes are here already and already
  // paid for, so the counter confirms rather than prices — putting this tier
  // through the intake form asked a shop to bill garments it had been paid for
  // at its own till, and charged the customer for the cleaning twice.
  const isReturn = order.service_tier === 'return_only';
  const showConfirmReturn = isReturn && order.status === 'scheduled';
  const showIntake =
    !isReturn && ['at_cleaner', 'awaiting_approval', 'cleaning'].includes(order.status);

  return (
    <div className="shell">
      <LiveRefresh cleanerIds={[order.cleaner_id]} />

      <header className="top">
        <div>
          <h1>
            {order.short_code}{' '}
            <span className={`pill ${statusTone(order.status)}`}>
              {statusLabel(order.status, order.service_tier)}
            </span>
          </h1>
          <div className="who">
            {(order.customer as any)?.full_name ?? 'Customer'}
            {(order.customer as any)?.phone && ` · ${(order.customer as any).phone}`}
          </div>
          {/* Which ending this order has. Whether the bag leaves by courier or
              over the counter is not visible anywhere else on the screen, and
              guessing it wrong costs a courier fare nobody paid. */}
          <div style={{ color: 'var(--muted)', fontSize: 13, marginTop: 2 }}>
            {TIER_LABEL[order.service_tier] ?? order.service_tier}
          </div>
        </div>
        <Link href="/" className="btn" style={{ textDecoration: 'none' }}>
          Back to queue
        </Link>
      </header>

      {order.status === 'awaiting_approval' && (
        <div className="notice warn">
          Held for customer approval at {money(order.subtotal_cents)} against a{' '}
          {money(order.estimate_subtotal_cents)} estimate. You can start cleaning once they accept.
        </div>
      )}
      {order.status === 'failed' && (
        <div className="notice danger">
          A courier leg failed. {legs.find((l: any) => l.last_error)?.last_error ?? ''}
        </div>
      )}

      {readyRange && (
        <div
          className="card"
          style={{
            marginBottom: 20,
            display: 'flex',
            gap: 12,
            alignItems: 'center',
            justifyContent: 'space-between',
            flexWrap: 'wrap',
          }}
        >
          <div>
            <div style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 4 }}>
              Ready by — what the customer has been told
            </div>
            <div style={{ fontWeight: 600 }}>{readyRange}</div>
          </div>
          {readyPastDue && <span className="pill danger">Past due</span>}
        </div>
      )}

      {order.customer_notes && (
        <div className="card" style={{ marginBottom: 20 }}>
          <div style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 4 }}>
            From the customer
          </div>
          {order.customer_notes}
        </div>
      )}

      {showConfirmReturn && (
        <section className="group">
          <h2>Confirm this return</h2>
          <ConfirmReturn orderId={order.id} shortCode={order.short_code} />
        </section>
      )}

      {showIntake ? (
        <section className="group">
          <h2>Intake</h2>
          <IntakeForm
            orderId={order.id}
            services={services ?? []}
            initial={initial}
            estimateCents={order.estimate_subtotal_cents}
            thresholdCents={order.approval_threshold_cents}
            notes={order.cleaner_notes}
            shopTurnaroundHours={shopTurnaroundHours}
            // Arrival, not this render: it is what the saved estimate is
            // measured from, and passing it in also keeps the preview identical
            // before and after hydration — a client-side clock would differ
            // from the HTML it replaces by however long the page took to reach
            // the tablet.
            arrivedAtMs={arrivedAtMs}
            customerItemCount={order.customer_item_count ?? null}
            initialItemCount={order.cleaner_item_count ?? null}
          />
        </section>
      ) : (
        (order.order_items ?? []).length > 0 && (
          <section className="group">
            <h2>Counted</h2>
            <div className="card">
              <div className="intake">
                {order.order_items.map((i: any) => (
                  <div className="intake-row" key={i.id}>
                    <span>{i.label}</span>
                    <span style={{ textAlign: 'center' }}>×{i.quantity}</span>
                    <span className="line-total">{money(i.quantity * i.unit_price_cents)}</span>
                  </div>
                ))}
              </div>
              <div className="totals">
                <div className="grand">
                  <span>Total</span>
                  <span>{money(order.subtotal_cents)}</span>
                </div>
              </div>
              {/* Both sides' piece counts, once the counting is done. A
                  mismatch is worth a phone call before the courier is booked,
                  not after the customer opens the bag at home. */}
              {(order.cleaner_item_count != null || order.customer_item_count != null) && (
                <p
                  style={{
                    fontSize: 13,
                    marginTop: 12,
                    marginBottom: 0,
                    color:
                      order.cleaner_item_count != null &&
                      order.customer_item_count != null &&
                      order.cleaner_item_count !== order.customer_item_count
                        ? 'var(--danger-fg)'
                        : 'var(--muted)',
                  }}
                >
                  Bag check:
                  {order.cleaner_item_count != null && ` you counted ${order.cleaner_item_count}`}
                  {order.cleaner_item_count != null && order.customer_item_count != null && ' ·'}
                  {order.customer_item_count != null &&
                    ` customer says ${order.customer_item_count}`}
                  {order.cleaner_item_count != null &&
                    order.customer_item_count != null &&
                    order.cleaner_item_count !== order.customer_item_count &&
                    ' — the counts differ.'}
                </p>
              )}
            </div>
          </section>
        )
      )}

      <ActionsPanel
        orderId={order.id}
        status={order.status}
        serviceTier={order.service_tier}
        hasReturnWindow={Boolean(order.return_window_start)}
      />

      <section className="group" style={{ marginTop: 32 }}>
        <h2>Courier legs</h2>
        <div className="card">
          {legs.length === 0 ? (
            <div className="empty">No courier booked yet.</div>
          ) : (
            <div className="legs">
              {legs.map((l: any) => (
                <div className="leg" key={l.id}>
                  <span className="dir">
                    {l.leg}
                    {l.attempt > 1 && (
                      <span style={{ color: 'var(--muted)', fontWeight: 400 }}> #{l.attempt}</span>
                    )}
                  </span>
                  <span>
                    <span className={`pill ${l.status === 'failed' || l.status === 'returned' ? 'danger' : 'neutral'}`}>
                      {LEG_LABEL[l.status] ?? l.status}
                    </span>
                    {l.courier_name && (
                      <span style={{ color: 'var(--muted)' }}>
                        {' '}
                        · {l.courier_name}
                        {l.courier_vehicle && ` (${l.courier_vehicle})`}
                      </span>
                    )}
                    {l.last_error && (
                      <div style={{ color: 'var(--danger-fg)', fontSize: 13 }}>{l.last_error}</div>
                    )}
                  </span>
                  <span style={{ fontVariantNumeric: 'tabular-nums', color: 'var(--muted)' }}>
                    {money(l.fee_cents)}
                  </span>
                </div>
              ))}
            </div>
          )}
        </div>
      </section>
    </div>
  );
}
