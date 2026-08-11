'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase';
import { billableUnits, lineTotalCents } from '@/lib/pricing';
import { readyHoursFor } from '@/lib/ready';
import { callDispatch } from '@/lib/dispatch';

/**
 * All mutations live here so the dispatch shared secret stays server-side.
 * The browser never learns INTERNAL_API_KEY or the dispatch URL.
 */

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

  // Read on its own rather than embedded in the order: the shop's default is
  // what every service without its own turnaround inherits, and an embed that
  // comes back shaped differently than expected would quietly fall back to 48
  // — a promise the form had already shown the counter as two hours.
  const { data: shop } = await db
    .from('cleaners')
    .select('turnaround_hours')
    .eq('id', order.cleaner_id)
    .maybeSingle();

  // Filtered here as well as in the form. The form decides what is shown; this
  // decides what can be saved, and a posted quantity for another service's
  // item would otherwise bill a laundry rate against a dry cleaning order.
  const { data: services } = await db
    .from('service_items')
    .select('id, code, label, unit_price_cents, unit, minimum_units, turnaround_hours')
    .eq('cleaner_id', order.cleaner_id)
    .eq('service_type', order.service_type);

  const counted = (services ?? [])
    .map((s) => ({ service: s, qty: Number(formData.get(`qty_${s.id}`) ?? 0) }))
    .filter(({ qty }) => qty > 0 && Number.isFinite(qty));

  const rows = counted.map(({ service, qty }) => ({
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

  // Until now the customer has been carrying the shop's blanket turnaround,
  // set when the bag arrived. The count is the first moment anyone knows what
  // is actually in it, so the estimate is redone from the services counted —
  // a wash & fold load stops claiming two days the shop was never going to
  // take. The slowest line decides, and a service with no turnaround of its
  // own inherits the shop's.
  //
  // Measured from arrival, never from the count. The dispatcher recomputes this
  // the same way inside /settle a moment from now and its write is the one that
  // survives, so an anchor of Date.now() here is not a second opinion — it is a
  // number the customer never sees, persisted just long enough to be wrong if
  // the settle fails. Same anchor, same rule, one answer.
  const { data: arrival } = await db
    .from('delivery_legs')
    .select('completed_at, updated_at')
    .eq('order_id', orderId)
    .eq('leg', 'pickup')
    .eq('status', 'delivered')
    .order('attempt', { ascending: false })
    .limit(1)
    .maybeSingle();
  // A drop-off has no courier leg to ask: the bag arrives in the customer's own
  // hands at the moment the counter opens it.
  const arrivedAtMs = Date.parse(arrival?.completed_at ?? arrival?.updated_at ?? '') || Date.now();

  const readyHours = readyHoursFor(
    counted.map(({ service }) => service),
    shop?.turnaround_hours,
  );
  const estimatedReadyAt = new Date(arrivedAtMs + readyHours * 3600_000).toISOString();

  // The bag-check, not the bill: how many pieces the counter can see, next to
  // whatever number the customer wrote at booking. Optional — a blank on a
  // recount genuinely means "no count", so blank writes null rather than
  // preserving a number nobody stands behind.
  const rawItemCount = String(formData.get('item_count') ?? '').trim();
  const cleanerItemCount = rawItemCount === '' ? null : Math.round(Number(rawItemCount));
  if (cleanerItemCount !== null && !(cleanerItemCount >= 1 && cleanerItemCount <= 200)) {
    return { error: 'Item count must be a number between 1 and 200.' };
  }

  const { error } = await db
    .from('orders')
    .update({
      subtotal_cents: subtotal,
      cleaner_notes: String(formData.get('cleaner_notes') ?? '') || null,
      cleaner_item_count: cleanerItemCount,
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
  let paymentNote: string | undefined;
  try {
    const res = await callDispatch(`/v1/orders/${orderId}/settle`);
    needsApproval = Boolean(res.needsApproval);
    // The dispatcher says "nothing to capture" on the 200 rather than by
    // refusing, so it is read here and not in the catch. The wording has to
    // hold for every branch that sets it — an order whose fee was taken at
    // booking, and one already captured at an earlier intake — so it claims
    // only that no further money moves, not when the money moved.
    if (res.nothingToSettle) {
      paymentNote = 'Saved. Nothing further to charge — this order is already paid.';
    }
  } catch (err) {
    // The garments are already counted and the intake is saved; a payment
    // problem must not silently look like a successful intake.
    revalidatePath(`/orders/${orderId}`);
    return { error: `Intake saved, but payment failed: ${(err as Error).message}` };
  }

  // Read back rather than echoed: settling can move the order, and the shop
  // has to be told the promise the customer's app is actually showing, not the
  // one this request posted a moment earlier.
  const { data: saved } = await db
    .from('orders')
    .select('estimated_ready_at')
    .eq('id', orderId)
    .maybeSingle();

  revalidatePath('/');
  revalidatePath(`/orders/${orderId}`);
  return {
    ok: true,
    subtotal,
    needsApproval,
    paymentNote,
    readyAt: saved?.estimated_ready_at ?? estimatedReadyAt,
  };
}

export async function markReady(orderId: string) {
  const db = await supabaseServer();

  // Read through the staff session first, because the call below goes out on
  // the internal key and that key does not care whose shop this is. RLS is what
  // stops a counter at one location finishing another location's order.
  const { data: order } = await db.from('orders').select('id').eq('id', orderId).maybeSingle();
  if (!order) return { error: 'order not found' };

  // The write happens in the dispatcher rather than here, because of what hangs
  // off it: this is the transition the customer has to be told about hours
  // after they closed the app, and a push fired from a render has no ledger
  // behind it and no way to know a retry already sent it. The dispatcher makes
  // the same write — status and ready_at, which is a fact and not a promise —
  // guards the same statuses, and is idempotent from 'ready', so a double-click
  // at the counter is a success rather than an error in front of a customer.
  try {
    await callDispatch(`/v1/orders/${orderId}/ready`);
  } catch (err) {
    return { error: (err as Error).message };
  }

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

/**
 * How a pickup-only order ends. There is no leg 2 to book — the customer walks
 * in and takes the bag — so without this the order sits at 'ready' forever and
 * the only button on the screen books a courier they never paid for.
 *
 * 'delivered' is reused rather than given its own status: the bag reached the
 * customer, which is the only thing the word has ever meant here.
 */
export async function markCollected(orderId: string) {
  const db = await supabaseServer();
  const { data: order } = await db
    .from('orders')
    .select('status, service_tier')
    .eq('id', orderId)
    .single();

  if (!order) return { error: 'order not found' };
  if (order.service_tier !== 'pickup_only') {
    return { error: 'This order is delivered back by courier. Use "Send it back".' };
  }
  // Already closed is the outcome this button is for, so it is a success, not
  // an error. A double-click at the counter — or the backend having closed the
  // order out first — would otherwise put a failure in front of a shop that
  // just did the right thing, with the customer standing there holding the bag.
  if (order.status === 'delivered') {
    revalidatePath('/');
    revalidatePath(`/orders/${orderId}`);
    return { ok: true };
  }
  if (order.status !== 'ready') {
    return { error: `Cannot hand over from status '${order.status}'.` };
  }

  const { error } = await db.from('orders').update({ status: 'delivered' }).eq('id', orderId);
  if (error) return { error: error.message };

  revalidatePath('/');
  revalidatePath(`/orders/${orderId}`);
  return { ok: true };
}

/** Leg 1, by hand: the shop starting a paid order, or retrying one that failed. */
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
