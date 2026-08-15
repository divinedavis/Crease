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
 *
 * Nor does it learn what the database said. Postgrest answers in the schema's
 * own words — constraint names, column names, "new row violates row-level
 * security policy for table orders" — and the dispatcher relays Stripe's. None
 * of that helps a counter, and returned to anyone poking at a server action it
 * is a free map of the schema and the policies. So every failure that came
 * from below us is logged here with the ids needed to find it, and the browser
 * gets a sentence the shop can act on. Messages written for the shop in the
 * first place ('Add at least one item.') are returned as-is.
 */

export async function signIn(_prev: unknown, formData: FormData) {
  const db = await supabaseServer();
  const { error } = await db.auth.signInWithPassword({
    email: String(formData.get('email')),
    password: String(formData.get('password')),
  });
  if (error) {
    console.error('[portal] signIn failed', { status: error.status, error });
    // A lockout told as "wrong password" sends the counter round the loop that
    // caused it, so the throttle is the one case worth distinguishing. Every
    // other reason collapses into one answer: naming which half was wrong is
    // how an account list gets enumerated.
    if (error.status === 429) {
      return { error: 'Too many sign-in attempts. Wait a minute and try again.' };
    }
    return { error: 'Email or password is incorrect.' };
  }
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
    .select(
      'id, cleaner_id, service_type, service_tier, estimate_subtotal_cents, approval_threshold_cents, status',
    )
    .eq('id', orderId)
    .single();
  if (!order) return { error: 'order not found' };

  // The same condition orders/[id]/page.tsx uses to decide whether to render
  // the intake form at all — mirrored here because a server action is callable
  // by id whatever the page chose to draw. Without it a delivered, captured
  // order can be recounted: the line items are replaced, the status is forced
  // back to 'cleaning', and /settle takes a second, larger payment from a
  // customer who is already holding their clothes.
  const canIntake =
    ['at_cleaner', 'awaiting_approval', 'cleaning'].includes(order.status) ||
    (order.status === 'scheduled' && order.service_tier === 'return_only');
  if (!canIntake) {
    return { error: `This order can no longer be counted (status '${order.status}').` };
  }

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

  const entered = (services ?? []).map((s) => ({
    service: s,
    qty: Number(formData.get(`qty_${s.id}`) ?? 0),
  }));

  // The same ceilings the form's number inputs carry: 99 garments, 200 lb.
  // Enforced again here because `max` on an input is a hint to a browser and
  // nothing at all to a posted body — a qty of 1e9 bills five figures, and a
  // large enough one overflows numeric(8,2) and fails the insert instead.
  //
  // Rejected rather than clamped: a number this far out is a typo or an
  // attack, and quietly billing 99 of something nobody counted is its own
  // surprise on someone's card.
  for (const { service, qty } of entered) {
    if (!Number.isFinite(qty) || qty < 0) {
      return { error: `${service.label}: enter a number of ${service.unit === 'pound' ? 'pounds' : 'pieces'}.` };
    }
    const ceiling = service.unit === 'pound' ? 200 : 99;
    if (qty > ceiling) {
      return {
        error: `${service.label}: ${ceiling} ${service.unit === 'pound' ? 'lb' : 'pieces'} is the most one order can hold. Split it or call us.`,
      };
    }
  }

  const counted = entered.filter(({ qty }) => qty > 0);

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

  // The bag-check, not the bill: how many pieces the counter can see, next to
  // whatever number the customer wrote at booking. Optional — a blank on a
  // recount genuinely means "no count", so blank writes null rather than
  // preserving a number nobody stands behind.
  //
  // Validated up here with everything else. It used to be checked after the
  // delete below, which meant a typo in an optional field threw away the
  // intake that was already on the order.
  const rawItemCount = String(formData.get('item_count') ?? '').trim();
  const cleanerItemCount = rawItemCount === '' ? null : Math.round(Number(rawItemCount));
  if (cleanerItemCount !== null && !(cleanerItemCount >= 1 && cleanerItemCount <= 200)) {
    return { error: 'Item count must be a number between 1 and 200.' };
  }

  // Everything above this line is a read or a rejection. Nothing destructive
  // runs until the whole form has been accepted, because the delete is not
  // recoverable: a request that fails after it leaves the order with no
  // counted items and no record of what it used to hold.
  //
  // Re-counting replaces the previous intake rather than appending to it, so
  // a corrected count does not double the bill.
  await db.from('order_items').delete().eq('order_id', orderId);
  const { error: insertErr } = await db.from('order_items').insert(rows);
  if (insertErr) {
    console.error('[portal] saveIntake: order_items insert failed', { orderId }, insertErr);
    return { error: 'Could not save the count. Nothing was charged — try again.' };
  }

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

  const { error } = await db
    .from('orders')
    .update({
      // subtotal_cents is written by the dispatcher at settle, derived from the
      // line items above: money columns are service-role-only, and a total the
      // server recomputes can't disagree with the lines the customer was shown.
      cleaner_notes: String(formData.get('cleaner_notes') ?? '') || null,
      cleaner_item_count: cleanerItemCount,
      estimated_ready_at: estimatedReadyAt,
      status: 'cleaning',
    })
    .eq('id', orderId);
  if (error) {
    console.error('[portal] saveIntake: order update failed', { orderId }, error);
    return { error: 'Saved the count, but could not start the order. Try again.' };
  }

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
    // problem must not silently look like a successful intake. What Stripe
    // said goes to the log — the counter can neither read nor act on it, and
    // it is the customer's card that it describes.
    console.error('[portal] saveIntake: settle failed', { orderId }, err);
    revalidatePath(`/orders/${orderId}`);
    return {
      error: 'The count is saved, but the payment did not go through. Check with the customer before starting.',
    };
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
    console.error('[portal] markReady: dispatch call failed', { orderId }, err);
    return { error: 'Could not mark this order ready. Try again in a moment.' };
  }

  revalidatePath('/');
  revalidatePath(`/orders/${orderId}`);
  return { ok: true };
}

/** Leg 2. The cleaner presses this when the garments are bagged and on the rack. */
export async function requestReturnCourier(orderId: string) {
  // Read through the staff session first: callDispatch goes out on the internal
  // key, which does no per-shop authorization, so RLS here is what stops one
  // shop booking a courier on another shop's order. (Server actions are
  // directly invocable by id — client-side button gating is not a control.)
  const db = await supabaseServer();
  const { data: order } = await db.from('orders').select('id').eq('id', orderId).maybeSingle();
  if (!order) return { error: 'order not found' };

  try {
    await callDispatch(`/v1/orders/${orderId}/dispatch-return`);
  } catch (err) {
    console.error('[portal] requestReturnCourier: dispatch call failed', { orderId }, err);
    return { error: 'Could not book the return courier. Try again in a moment.' };
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
  if (error) {
    console.error('[portal] markCollected: order update failed', { orderId }, error);
    return { error: 'Could not close out this order. Try again.' };
  }

  revalidatePath('/');
  revalidatePath(`/orders/${orderId}`);
  return { ok: true };
}

/** Leg 1, by hand: the shop starting a paid order, or retrying one that failed. */
export async function retryPickupCourier(orderId: string) {
  // Ownership check through the staff RLS session before the internal-key call
  // — same reason as requestReturnCourier: stop cross-shop courier booking.
  const db = await supabaseServer();
  const { data: order } = await db.from('orders').select('id').eq('id', orderId).maybeSingle();
  if (!order) return { error: 'order not found' };

  try {
    await callDispatch(`/v1/orders/${orderId}/dispatch-pickup`);
  } catch (err) {
    console.error('[portal] retryPickupCourier: dispatch call failed', { orderId }, err);
    return { error: 'Could not book the pickup courier. Try again in a moment.' };
  }
  revalidatePath('/');
  revalidatePath(`/orders/${orderId}`);
  return { ok: true };
}
