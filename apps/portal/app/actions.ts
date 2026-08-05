'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase';
import { billableUnits, lineTotalCents } from '@/lib/pricing';

/**
 * All mutations live here so the dispatch shared secret stays server-side.
 * The browser never learns INTERNAL_API_KEY or the dispatch URL.
 */

const DISPATCH_URL = process.env.DISPATCH_URL ?? 'http://localhost:8080';

async function callDispatch(path: string) {
  const res = await fetch(`${DISPATCH_URL}${path}`, {
    method: 'POST',
    headers: {
      'x-crease-key': process.env.INTERNAL_API_KEY!,
      'content-type': 'application/json',
    },
    body: '{}',
    cache: 'no-store',
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(json.error ?? `dispatch returned ${res.status}`);
  return json;
}

export async function signIn(_prev: unknown, formData: FormData) {
  const db = await supabaseServer();
  const { error } = await db.auth.signInWithPassword({
    email: String(formData.get('email')),
    password: String(formData.get('password')),
  });
  if (error) return { error: error.message };
  redirect('/');
}

export async function signOut() {
  const db = await supabaseServer();
  await db.auth.signOut();
  redirect('/login');
}

/**
 * Intake: replace the line items with what the cleaner actually counted and
 * reprice the order.
 *
 * This is the step that makes dry cleaning different from food delivery — the
 * order has no real price until someone opens the bag. If the count comes in
 * far enough over the customer's estimate we stop and ask rather than
 * surprising them, using the per-order approval threshold.
 */
export async function saveIntake(orderId: string, _prev: unknown, formData: FormData) {
  const db = await supabaseServer();

  const { data: order } = await db
    .from('orders')
    .select('id, cleaner_id, service_type, estimate_subtotal_cents, approval_threshold_cents, status')
    .eq('id', orderId)
    .single();
  if (!order) return { error: 'order not found' };

  // Filtered here as well as in the form. The form decides what is shown; this
  // decides what can be saved, and a posted quantity for another service's
  // item would otherwise bill a laundry rate against a dry cleaning order.
  const { data: services } = await db
    .from('service_items')
    .select('id, code, label, unit_price_cents, unit, minimum_units')
    .eq('cleaner_id', order.cleaner_id)
    .eq('service_type', order.service_type);

  const rows = (services ?? [])
    .map((s) => ({ service: s, qty: Number(formData.get(`qty_${s.id}`) ?? 0) }))
    .filter(({ qty }) => qty > 0 && Number.isFinite(qty))
    .map(({ service, qty }) => ({
      order_id: orderId,
      service_item_id: service.id,
      label: service.label,
      // The weight minimum is applied here, not trusted from the form. Two
      // decimals because that is what the column holds and what a scale reads.
      quantity: Math.round(billableUnits(service, qty) * 100) / 100,
      unit_price_cents: service.unit_price_cents,
    }));

  if (rows.length === 0) return { error: 'Add at least one item.' };

  // Re-counting replaces the previous intake rather than appending to it, so
  // a corrected count does not double the bill.
  await db.from('order_items').delete().eq('order_id', orderId);
  const { error: insertErr } = await db.from('order_items').insert(rows);
  if (insertErr) return { error: insertErr.message };

  // Rounded per line, not once at the end: a fractional weight times a cent
  // price gives fractional cents, and a non-integer subtotal fails the column.
  // The minimum is already folded into r.quantity, so this must not reapply it.
  const subtotal = rows.reduce(
    (n, r) => n + lineTotalCents({ unit_price_cents: r.unit_price_cents }, r.quantity),
    0,
  );

  // The shop is the only party that knows how long the work takes, so this is
  // where a real estimate enters the system. Until it does, the customer is
  // told nothing rather than told a guess.
  const readyHours = Number(formData.get('ready_hours') ?? 0);
  const estimatedReadyAt =
    readyHours > 0 ? new Date(Date.now() + readyHours * 3600_000).toISOString() : null;

  const { error } = await db
    .from('orders')
    .update({
      subtotal_cents: subtotal,
      cleaner_notes: String(formData.get('cleaner_notes') ?? '') || null,
      estimated_ready_at: estimatedReadyAt,
      status: 'cleaning',
    })
    .eq('id', orderId);
  if (error) return { error: error.message };

  // Settling decides whether this can be charged silently or has to go back to
  // the customer — the card network, not the portal, is the authority on how
  // much we are allowed to take. The dispatcher moves the order to
  // 'awaiting_approval' if the count came in above the hold.
  let needsApproval = false;
  try {
    const res = await callDispatch(`/v1/orders/${orderId}/settle`);
    needsApproval = Boolean(res.needsApproval);
  } catch (err) {
    // The garments are already counted and the intake is saved; a payment
    // problem must not silently look like a successful intake.
    revalidatePath(`/orders/${orderId}`);
    return { error: `Intake saved, but payment failed: ${(err as Error).message}` };
  }

  revalidatePath('/');
  revalidatePath(`/orders/${orderId}`);
  return { ok: true, subtotal, needsApproval };
}

export async function markReady(orderId: string) {
  const db = await supabaseServer();
  const { data: order } = await db.from('orders').select('status').eq('id', orderId).single();

  // Guard the transition here as well as in the dispatcher — a cleaner
  // marking an unpriced order ready would send a courier for garments that
  // were never counted.
  if (!order || !['cleaning', 'awaiting_approval'].includes(order.status)) {
    return { error: `Cannot mark ready from status '${order?.status ?? 'unknown'}'.` };
  }

  // ready_at is a fact, not a promise. It is what unlocks the customer
  // choosing a delivery time, so it must only be set when the clothes are
  // genuinely finished — not when they were estimated to be.
  const { error } = await db
    .from('orders')
    .update({ status: 'ready', ready_at: new Date().toISOString() })
    .eq('id', orderId);
  if (error) return { error: error.message };

  revalidatePath('/');
  revalidatePath(`/orders/${orderId}`);
  return { ok: true };
}

/** Leg 2. The cleaner presses this when the garments are bagged and on the rack. */
export async function requestReturnCourier(orderId: string) {
  try {
    await callDispatch(`/v1/orders/${orderId}/dispatch-return`);
  } catch (err) {
    return { error: (err as Error).message };
  }
  revalidatePath('/');
  revalidatePath(`/orders/${orderId}`);
  return { ok: true };
}

/** Retry a leg that failed or came back undelivered. */
export async function retryPickupCourier(orderId: string) {
  try {
    await callDispatch(`/v1/orders/${orderId}/dispatch-pickup`);
  } catch (err) {
    return { error: (err as Error).message };
  }
  revalidatePath('/');
  revalidatePath(`/orders/${orderId}`);
  return { ok: true };
}
