import Link from 'next/link';
import { notFound, redirect } from 'next/navigation';
import { currentStaff, supabaseServer } from '@/lib/supabase';
import { LEG_LABEL, TIER_LABEL, money, statusLabel, statusTone } from '@/lib/status';
import { LiveRefresh } from '@/app/live-refresh';
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
                     tracking_url, fee_cents, attempt, last_error, created_at)`,
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

  // Pre-select the ready time this service actually takes. Wash & fold is two
  // hours and dry cleaning is two days; a dropdown that always opens on 48
  // means every laundry order is quoted five times too slow unless the
  // counter remembers to change it, and they will not.
  const turnarounds = (services ?? [])
    .map((s) => s.turnaround_hours)
    .filter((h): h is number => typeof h === 'number');
  const defaultReadyHours = turnarounds.length ? Math.min(...turnarounds) : 48;

  const initial: Record<string, number> = {};
  for (const item of order.order_items ?? []) {
    if (item.service_item_id) initial[item.service_item_id] = item.quantity;
  }

  const legs = [...(order.delivery_legs ?? [])].sort(
    (a: any, b: any) => +new Date(a.created_at) - +new Date(b.created_at),
  );

  // A drop-off has no courier leg to carry it into 'at_cleaner' — the customer
  // walks it in — so the counter counting the bag is the event that proves it
  // arrived. Without this the order sits at 'scheduled' with nothing on the
  // screen that can move it, waiting on a driver that was never booked.
  const showIntake =
    ['at_cleaner', 'awaiting_approval', 'cleaning'].includes(order.status) ||
    (order.status === 'scheduled' && order.service_tier === 'return_only');

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

      {order.customer_notes && (
        <div className="card" style={{ marginBottom: 20 }}>
          <div style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 4 }}>
            From the customer
          </div>
          {order.customer_notes}
        </div>
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
            defaultReadyHours={defaultReadyHours}
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
