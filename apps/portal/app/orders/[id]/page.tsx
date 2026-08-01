import Link from 'next/link';
import { notFound, redirect } from 'next/navigation';
import { currentStaff, supabaseServer } from '@/lib/supabase';
import { LEG_LABEL, STATUS_LABEL, money, statusTone } from '@/lib/status';
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

  const { data: services } = await db
    .from('service_items')
    .select('id, label, unit_price_cents')
    .eq('cleaner_id', order.cleaner_id)
    .eq('active', true)
    .order('sort_order');

  const initial: Record<string, number> = {};
  for (const item of order.order_items ?? []) {
    if (item.service_item_id) initial[item.service_item_id] = item.quantity;
  }

  const legs = [...(order.delivery_legs ?? [])].sort(
    (a: any, b: any) => +new Date(a.created_at) - +new Date(b.created_at),
  );

  const showIntake = ['at_cleaner', 'awaiting_approval', 'cleaning'].includes(order.status);

  return (
    <div className="shell">
      <LiveRefresh cleanerIds={[order.cleaner_id]} />

      <header className="top">
        <div>
          <h1>
            {order.short_code}{' '}
            <span className={`pill ${statusTone(order.status)}`}>
              {STATUS_LABEL[order.status] ?? order.status}
            </span>
          </h1>
          <div className="who">
            {(order.customer as any)?.full_name ?? 'Customer'}
            {(order.customer as any)?.phone && ` · ${(order.customer as any).phone}`}
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

      <ActionsPanel orderId={order.id} status={order.status} />

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
