# Insurance & liability

Not legal or insurance advice — this is the shape of the problem and the
vocabulary to take to a broker. Use a broker who writes for the **garment care
industry**, not a general small-business agent; the coverage that matters here
is a specialty line most agents will not name unprompted.

## Why this is the real risk

In a food delivery marketplace a lost order costs you the order. Here, a lost
order can cost you a $3,000 wedding dress, and the customer's claim is against
**you**, not against the carrier. Three facts stack badly:

1. **You take custody of goods you do not own.** That is a bailment, and it is
   a different legal posture from selling someone a service.
2. **Carrier liability is capped far below garment value.** Uber Direct's
   coverage per delivery is a few hundred dollars at most (confirm the exact
   figure in your agreement — it is negotiated, and it has changed over time).
   A bag of five suits exceeds it comfortably.
3. **The goods change hands twice per order**, plus the days at the plant. Loss
   can happen in four distinct custody windows and each one has a different
   party holding the bag.

The `declaredValueMaxCents` cap in the dispatcher config exists because of
point 2: declaring a higher value does not buy you more coverage, it only
raises the carrier's quote.

## Coverage you actually need

| Coverage | What it does | Priority |
|---|---|---|
| **Bailee's customer insurance** | Covers customers' property while in your care, custody and control — the single most important line for this business. Dry cleaners carry it; as the party holding the goods, so must you. | Essential |
| **Commercial general liability (CGL)** | Bodily injury / property damage, $1M per occurrence / $2M aggregate is the standard ask. Partners and landlords will require a certificate. | Essential |
| **Tech E&O + cyber liability** | You are a software platform holding addresses, phone numbers and payment tokens. Covers breach response and claims that the platform itself failed (dispatched to the wrong address, lost an order). Usually sold bundled. | Essential |
| **Motor truck cargo / transit** | Goods in transit. Partly redundant with bailee's depending on how the policy is written — ask specifically whether your bailee's form covers goods *in transit with a third-party courier*, because many do not. | Ask explicitly |
| **Crime / employee dishonesty** | Theft by your own staff. Cheap; add it once you have employees. | When staffed |
| **Workers' compensation** | Required by New York law once you have W-2 employees. Uber's couriers are not yours, so they do not trigger it — your own staff do. | When staffed |
| **Hired & non-owned auto** | Only if you or an employee ever drives for the business. Not triggered by pure Uber Direct dispatch. | Situational |

## The gap to close

Ask the broker one question directly, and get the answer in writing:

> Does this bailee's form cover customer goods while in transit in the vehicle
> of a third-party independent courier that I do not employ or control?

That specific window — garments in an Uber courier's back seat — is where a
generic policy is most likely to have a hole, and it is a third of the
lifecycle of every order.

## Contractual limits you should set anyway

Insurance is the backstop; contracts are the first line.

- **Cap per-item liability in your terms of service.** The industry norm is a
  multiple of the cleaning charge — the Drycleaning & Laundry Institute's Fair
  Claims Guide is the reference the trade uses. Put a number in the ToS, make
  it visible at checkout, and it becomes the ceiling on most disputes.
- **Require partner cleaners to carry their own bailee's coverage** and to name
  you as an additional insured. Get the certificate before their first order.
- **Allocate loss by custody window** in the cleaner agreement: in transit
  (leg 1), at the plant, in transit (leg 2). Say who eats it in each.
- **Offer declared-value upsell** for high-value pieces rather than silently
  carrying the risk. A gown gets a checkbox and a fee, not a surprise.

## Why the schema supports this

- `order_items.photo_path` — intake photos are evidence. Damage and loss
  disputes are the highest-frequency claim in garment care, and a timestamped
  photo at intake resolves most of them before they become claims.
- Signature verification on both customer-side handoffs (`waypoints()` in
  `orders.ts`) — a name on the handoff is the cheapest evidence there is.
- `undeliverable_action: 'return'` on every Uber leg — garments are never left
  on a doorstep, which removes the entire "it was stolen off my step" claim
  category.

## Rough budget

Highly dependent on limits, state, and volume — treat as an order of magnitude,
not a quote. For a pre-revenue operation in NY, expect the CGL + bailee's +
tech E&O bundle to land in the low four figures per year, rising with order
volume and declared limits. Get three quotes; the spread on bailee's coverage
between carriers is wide because few of them want to write it.
