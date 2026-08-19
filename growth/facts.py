#!/usr/bin/env python3
"""What is true about Crease, in one place, for the one job that needs it.

writer.py hands these to a model and tells it these are the only facts it may
state. Everything a laundry customer wants to know is a number — the price a
pound, the minimum, the courier fee, how far we come — and a model asked to
write a page about a local service without them will invent all four. An
invented price is not a typo: it is on a public page, it is what somebody
decides to book on, and the dispatcher will not honour it.

Mirrored by hand from apps/web/lib/tiers.ts and apps/web/lib/neighborhoods.ts.
If those change, this changes with them; `growth_daily.py facts` prints this
block so the drift is visible rather than discovered in a published page.
"""

BRAND = "Crease"
SITE = "https://creasenyc.com"
CITY = "Brooklyn"
BASE_NEIGHBORHOOD = "Clinton Hill"

# From apps/web/lib/tiers.ts (itself mirrored from services/dispatch/pricing.ts).
PRICE_PER_POUND = "$2.00"
MINIMUM = "$20"
MINIMUM_POUNDS = 10
COURIER_ROUND_TRIP = "$29.95"
COURIER_ONE_LEG = "$16.95"
RADIUS_MILES = 3

# The facts a guide may state, written as sentences because that is how they
# reach the page. Anything not on this list is not known and must not be
# written — including delivery times, turnaround promises, and any claim about
# what a competitor charges.
FACTS = [
    f"{BRAND} is a laundry pickup and delivery service in {CITY}, New York.",
    f"Wash and fold is {PRICE_PER_POUND} a pound, with a {MINIMUM} minimum "
    f"(about {MINIMUM_POUNDS} pounds).",
    f"There is one courier fee on top: {COURIER_ROUND_TRIP} for a round trip "
    f"(collected and delivered back), or {COURIER_ONE_LEG} if only one leg is needed.",
    f"Collection covers roughly {RADIUS_MILES} miles around {BASE_NEIGHBORHOOD}, "
    f"which is most of northwest and central {CITY}.",
    "The customer is charged the shop's scale weight, not an estimate.",
    "If the total comes to more than the estimate given at booking, nothing is "
    "charged until the customer approves it.",
    "The washing is done by a neighborhood laundromat, not a central warehouse.",
    "Booking happens on the website or in the iOS app; a driver collects from the door.",
    "Dry cleaning is not offered yet — only wash and fold.",
]

# Things a model reliably invents about a laundry service and must not.
FORBIDDEN = [
    "any turnaround time, same-day promise, or delivery window in hours",
    "any discount, subscription, referral offer, or first-order deal",
    "any named competitor, or any claim about what another service charges",
    "any review, rating, testimonial, customer name, or number of customers",
    "any phone number, street address, or opening hours",
    "any service not listed above — no dry cleaning, tailoring, shoe repair, "
    "commercial accounts, or hotel laundry",
    "any claim about being the cheapest, fastest, biggest, or best",
]


def block():
    """The facts, as the prompt sees them."""
    lines = ["FACTS (the only claims you may make about Crease):"]
    lines += [f"  - {f}" for f in FACTS]
    lines.append("")
    lines.append("NEVER state, imply, or invent:")
    lines += [f"  - {f}" for f in FORBIDDEN]
    return "\n".join(lines)
