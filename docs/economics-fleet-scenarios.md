# Owned fleet economics: driver + van, ± owning the supply side

Modeled 2026-08-27. Extends `reference_crease_unit_economics` (courier-network
model) with three scenarios where Crease owns the vehicle instead of renting
legs from Uber Direct.

Every order count below is **hypothetical**. Production as of 2026-08-24 has
133 orders across 2 accounts, both owner test accounts, and 0 organic search
demand. See `project_crease_demand_baseline`.

## The shared line: what one driver + one van costs per day

| line | $/day | basis |
|---|---:|---|
| Driver, 8h @ $22 + ~20% burden | 211 | Indeed NYC avg $26.13, ZipRecruiter $20.19; burden = FICA 7.65% + NY UI + WC class 7231 (~$6.33/$100) + DBL/PFL |
| Cargo van lease, $750/mo | 34 | Ram ProMaster NYC $738/mo; commercial range $450–1,300 |
| Commercial auto insurance, $4,500/yr | 17 | NYC small delivery van $2,800–5,000/yr; NY runs 35–55% over national |
| Garage, $400/mo | 18 | Brooklyn monthly parking $250–500 |
| Fuel, 60 mi @ 15 mpg | 14 | |
| Maintenance @ $0.15/mi | 9 | |
| Parking tickets, ~0.75/day @ $65 | 49 | Stipulated Fine Program double-park $65; $115 unenrolled |
| Bailee's / goods-in-custody, $1,200/yr | 5 | see `docs/insurance.md` |
| Routing, phone, tolls | 3 | |
| **Total** | **360** | ≈ $7,900/mo at 22 days |

**Capacity:** 4–5 handoffs/hr (a bag handed over by a person, not a porch drop)
× 7.5 productive hours = **30–37 legs/day**. Model uses 34. Industry says 8–14
stops/hr on dense urban parcel routes, but 56% of a driver's day is parking and
walking — Brooklyn bag handoffs are the slow end.

Tickets are the sleeper line: at $49/day they cost more than the van lease.

## Scenario A — the van replaces Uber Direct, product unchanged

Revenue is still the trip fee only. 50/50 tier mix: round trip $29.95 net
$28.78 (2 legs), one-leg $16.95 net $16.16 (1 leg) → blended **$22.47 net,
1.5 legs/order**. Van capacity = 34 / 1.5 = **22 orders/day**.

**Break-even = 360 / 22.47 = 16 orders/day (24 legs).**

| orders/day | legs | net rev | van cost | profit/day | same volume on Uber Direct |
|---:|---:|---:|---:|---:|---:|
| 5 | 8 | 112 | 360 | **−248** | +15 |
| 10 | 15 | 225 | 360 | **−135** | +30 |
| 16 | 24 | 360 | 360 | **0** | +48 |
| 22 (max) | 33 | 494 | 360 | **+134** | +66 |

At full capacity every working day: **+$3,484/mo**, ≈ $3,100 after stack and
admin overhead. That is the ceiling for one van, ~$37k/yr.

The structural point: **couriers are variable cost, a driver is fixed.** Below
16 orders/day you are paying $360 a day for work that Uber Direct would do for
less. Crease has never had 16 orders in a day from a stranger.

## Scenario B — plus you own a laundromat

Now you sell the cleaning, not just the trip. This is the change that matters.

Brooklyn laundromat baseline, from live broker listings (gross $420k–$625k,
SDE $130k–$186k, asking $520k–$1.2M, one listing at $8,700/mo rent):

| monthly | $ |
|---|---:|
| Revenue ($480k/yr) | 40,000 |
| Utilities @ 25% of revenue | −10,000 |
| Rent | −8,700 |
| Attendant labor | −7,000 |
| Insurance / maintenance / supplies / card fees | −3,500 |
| **Net** | **+10,800** |

Per delivered order, with your own store doing the work:

| line | $ |
|---|---:|
| Trip fee (round trip) | 29.95 |
| Cleaning, 22 lb @ $2.25/lb delivery tier | 49.50 |
| Marginal processing: ~20 min labor $5.70 + utilities $0.35/lb $7.70 + supplies $1.50 | −14.90 |
| Card fee on $79.45 | −2.60 |
| **Contribution / order** | **61.95** |

Wash-and-fold needs both legs → 2 legs/order → capacity **17 orders/day**.

**Break-even = 360 / 61.95 = 5.8 orders/day.**

| orders/day | contribution | van | profit/day | /mo (26d) |
|---:|---:|---:|---:|---:|
| 5 | 310 | 360 | −50 | −1,300 |
| 8 | 496 | 360 | +136 | +3,530 |
| 12 | 743 | 360 | +383 | +9,960 |
| 17 (max) | 1,053 | 360 | +693 | +18,020 |

Combined at 12 orders/day: 10,800 + 9,960 = **$20,760/mo ($249k/yr)**. Less SBA
7(a) debt on a $600k acquisition at 10.5% / 10 yr (−$8,100/mo) → **$12,660/mo,
≈ $152k/yr**.

Break-even falls 16 → 6 orders/day. **Owning the supply side is worth ~$32 an
order.** Every prior Crease model was fighting for $2.80.

It also dissolves constraint #1 in `project_crease`: no courier will hold goods
for two days, but *your own store will*. You control turnaround, so drop-by-9 /
back-by-6 collapses two route passes into one.

## Scenario C — put the laundromat inside a coffee shop in Fort Greene

Three businesses on one lease.

**Rent.** Fort Greene retail ≈ $61/sf/yr (374 Myrtle Ave, listed). A combo
needs ~2,200 sf (laundry 1,200–1,500, café 600–800, back-of-house). That is
**$134k/yr ≈ $11,200/mo + NNN**, against $8,700 for a plain laundromat lease.

**Café layer.** A strong independent NYC café grosses ~$500k/yr; a
laundry-anchored one with a captive but narrow street draw is more like
$250–320k. Model $280k/yr = $23,300/mo, at industry ratios: COGS 30%, labor 32%,
misc 6% → **+$7,440/mo before rent**. Note labor overlaps: one person can work
the counter and take wash-and-fold intake in slow hours, cutting ~$3,000/mo off
the laundromat's attendant line.

Combined, at 12 delivery orders/day:

| line | $/mo |
|---|---:|
| Laundry revenue | 40,000 |
| Café revenue | 23,300 |
| Delivery trip fees (12 × 26 × $29.95) | 9,346 |
| Delivery cleaning revenue (12 × 26 × $49.50) | 15,444 |
| **Revenue** | **88,090** |
| Laundry + delivery utilities | −13,900 |
| Café COGS | −7,000 |
| Labor (laundry 4,000 shared + café 7,460 + delivery processing 1,780) | −13,240 |
| Driver + van | −9,360 |
| Rent 2,200 sf @ $61 + NNN | −12,500 |
| Insurance / maintenance / supplies / card fees | −6,200 |
| **Operating profit** | **+25,890** |
| SBA debt, ~$900k buy + buildout @ 10.5% / 10 yr | −12,150 |
| **Net** | **+13,740/mo ≈ $165k/yr** |

Roughly Scenario B's net on twice the revenue and ~$300k more capital at risk.
**The café does not buy margin — it buys three other things:**

1. **Demand.** Crease's actual problem is that nothing reaches the page: 0
   `pickup_requests` ever, 0 Search Console impressions across 30 area pages. A
   Myrtle Ave counter is an acquisition channel you don't have to buy.
2. **Dwell time.** ~40 min wash + ~45 min dry is a captive café customer per
   laundry customer, and café traffic backfills the hours machines sit idle.
3. **Rent absorption.** Laundromats are rent-light (~9% of revenue); a café at
   ~12% on the same slab is how you afford Fort Greene rent rather than
   Brownsville rent.

### Regulatory, checkable before signing anything

- **Retail laundry license: no longer required.** Local Law 80 of 2021 repealed
  the DCWP retail laundry license. Pricing-transparency and signage rules still
  apply.
- **Industrial Laundry License may still bite.** DCWP requires it if you launder
  for other businesses *or* run a laundry service "in connection with any
  commercial business." A café and a laundry under one entity is exactly the
  fact pattern to get an opinion on — and it is also what a commercial Crease
  tier (hotels, Airbnb, restaurants) would trigger.
- **DOHMH / Health Code Article 81.** Food service needs adequate separation, no
  lint or dryer exhaust over food prep, separate handwash. Expect a partition
  and independent ventilation — a design cost, not a blocker.
- **DOB.** Gas dryer exhaust, make-up air, possible sprinkler. Both uses are
  Use Group 6, as-of-right in the C1/C2 overlays that cover most of Fort
  Greene's commercial frontage — verify the specific lot on ZoLa.

### The number that moves everything

Utilities at 25% of revenue is the planning figure; the observed range is
15–40%. Old machines or a bad gas meter push it to 40% and eat the entire net
in Scenario C. Diligence the last 24 months of utility bills before the price.

## Capital and reversibility

| scenario | capital | reversible? |
|---|---|---|
| A — van + driver | ~$5k (deposit, first month) | yes, walk away in 30 days |
| B — + laundromat | $520k–$775k (Brooklyn listings, $130k–$186k SDE) | slow; asset resells |
| C — + café buildout in Fort Greene | ~$900k–$1.1M | least; buildout is sunk |

C gets cheaper if you buy an operating laundromat and add the café into
adjacent square footage rather than building both from raw space.

## Sources

Wages: Indeed, Glassdoor, ZipRecruiter NYC delivery driver, 2026. Van lease:
Edmunds/TrueCar NYC, Wilmar fleet. Insurance: MoneyGeek, RefineRisk NYC
delivery. Tickets: NYC DOF Stipulated Fine Program. Laundromat P&L:
ProjectionHub, BizBuySell/HedgeStone Brooklyn listings. Wash-and-fold pricing:
BK Laundry, Speedy Fresh, Laundry on Keap. Café ratios: Toast, VantaInsights.
Rent: CityFeet 374 Myrtle Ave. Licensing: NYC MyCity Business, PlanetLaundry on
Local Law 80 of 2021.
