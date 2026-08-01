'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase';

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
    .select('id, cleaner_id, estimate_subtotal_cents, approval_threshold_cents, status')
    .eq('id', orderId)
    .single();
  if (!order) return { error: 'order not found' };

  const { data: services } = await db
    .from('service_items')
    .select('id, code, label, unit_price_cents')
    .eq('cleaner_id', order.cleaner_id);

  const rows = (services ?? [])
    .map((s) => ({ service: s, qty: Number(formData.get(`qty_${s.id}`) ?? 0) }))
    .filter(({ qty }) => qty > 0)
    .map(({ service, qty }) => ({
      order_id: orderId,
      service_item_id: service.id,
      label: service.label,
      quantity: qty,
      unit_price_cents: service.unit_price_cents,
    }));

  if (rows.length === 0) return { error: 'Add at least one garment.' };

  // Re-counting replaces the previous intake rather than appending to it, so
  // a corrected count does not double the bill.
  await db.from('order_items').delete().eq('order_id', orderId);
  const { error: insertErr } = await db.from('order_items').insert(rows);
  if (insertErr) return { error: insertErr.message };

  const subtotal = rows.reduce((n, r) => n + r.quantity * r.unit_price_cents, 0);

  const { error } = await db
    .from('orders')
    .update({
      subtotal_cents: subtotal,
      cleaner_notes: String(formData.get('cleaner_notes') ?? '') || null,
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

  const { error } = await db.from('orders').update({ status: 'ready' }).eq('id', orderId);
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
