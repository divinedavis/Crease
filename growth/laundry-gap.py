#!/usr/bin/env python3
"""Rank NYC neighbourhoods by how many households have no in-unit laundry.

There is no dataset that says "this apartment has a washer/dryer" — the census
does not ask, and the DCA laundromat licence list turns out to hold six rows.
So this builds a proxy from the building stock, which is the thing that
actually determines it.

The physics matter more than the vintage: a pre-war walk-up usually cannot get
in-unit laundry even if the owner wants it, because there is no venting, no
spare plumbing stack, and no room. A 2015 elevator building almost always has
hookups because it was cheaper to plumb them at construction. And a one- or
two-family house typically has a basement with a hookup, which is why the
outer boroughs score low despite being full of old housing.

    python3 growth/laundry-gap.py            # top neighbourhoods
    python3 growth/laundry-gap.py --borough BK

Calibrate against the NYC Housing and Vacancy Survey before trusting the
absolute numbers; the ranking is more robust than the percentages.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request

PLUTO = "https://data.cityofnewyork.us/resource/64uk-42ks.json"
ACS = "https://api.census.gov/data/2023/acs/acs5"

# Building-class first letters, per the Dept of Finance classification.
#   C = walk-up apartments      D = elevator apartments
#   A = one-family              B = two-family
#   R = condominium units       S = mixed residential/commercial
WALKUP = "C"
ELEVATOR = "D"
MIXED = "S"

BOROUGHS = {"MN": "Manhattan", "BX": "Bronx", "BK": "Brooklyn", "QN": "Queens", "SI": "Staten Island"}


def soql(select: str, where: str, group: str | None = None, limit: int = 5000) -> list[dict]:
    params = {"$select": select, "$where": where, "$limit": limit}
    if group:
        params["$group"] = group
    url = f"{PLUTO}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": "curl/8.7.1"})
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.load(r)


def value_per_unit() -> dict[str, float]:
    """Assessed value per residential unit, by ZIP — a proxy for ability to pay.

    The need for laundry delivery is near universal in old housing stock; the
    willingness to pay twenty dollars to avoid the errand is not. Ranking on
    need alone produces a launch list of the neighbourhoods least able to buy
    the product, which is the opposite of a customer map.

    The obvious source is ACS median household income, but the Census API now
    requires a key. Assessed value per unit comes from the same PLUTO query
    that is already running, needs no second credential, and tracks
    neighbourhood affluence closely enough to rank on.

    It is a proxy and behaves like one: assessment lags the market, and rent
    stabilisation depresses assessed value in exactly the pre-war stock this
    business targets. Treat the ordering as a shortlist to check, not a score.
    """
    rows = soql(
        "zipcode, sum(assesstot) AS v, sum(unitsres) AS u",
        "unitsres>0 AND zipcode IS NOT NULL AND assesstot>0",
        group="zipcode",
    )
    out = {}
    for r in rows:
        units = num(r.get("u"))
        if r.get("zipcode") and units > 0:
            out[r["zipcode"]] = num(r.get("v")) / units
    return out


def num(v) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--borough", choices=sorted(BOROUGHS), help="limit to one borough")
    ap.add_argument("--min-units", type=int, default=2000, help="ignore thin ZIPs")
    ap.add_argument("--top", type=int, default=20)
    ap.add_argument("--min-value", type=int, default=0, dest="min_income",
                    help="only ZIPs at or above this assessed value per unit")
    args = ap.parse_args()

    borough_clause = f"borough='{args.borough}' AND " if args.borough else ""

    # Every residential unit, by ZIP.
    total = {
        r["zipcode"]: num(r["u"])
        for r in soql("zipcode, sum(unitsres) AS u",
                      f"{borough_clause}unitsres>0 AND zipcode IS NOT NULL",
                      group="zipcode")
        if r.get("zipcode")
    }

    # Units in stock that almost certainly lacks in-unit laundry:
    #   - any walk-up apartment building, of any age
    #   - elevator buildings built before 1980, when in-unit was not standard
    #   - mixed residential/commercial, which is overwhelmingly old walk-up
    gap_where = (
        f"{borough_clause}unitsres>0 AND zipcode IS NOT NULL AND ("
        f"starts_with(bldgclass,'{WALKUP}') OR "
        f"starts_with(bldgclass,'{MIXED}') OR "
        f"(starts_with(bldgclass,'{ELEVATOR}') AND yearbuilt<1980 AND yearbuilt>0))"
    )
    gap = {
        r["zipcode"]: num(r["u"])
        for r in soql("zipcode, sum(unitsres) AS u", gap_where, group="zipcode")
        if r.get("zipcode")
    }

    wealth = value_per_unit()

    rows = []
    for zipcode, total_units in total.items():
        if total_units < args.min_units:
            continue
        income = wealth.get(zipcode, 0.0)
        if args.min_income and income < args.min_income:
            continue
        without = gap.get(zipcode, 0.0)
        rows.append((zipcode, without, total_units, without / total_units * 100, income))

    # Ranked by absolute households, not share: a 95% share of 3,000 units is a
    # worse place to launch than 70% of 40,000. Density is the whole business.
    rows.sort(key=lambda r: r[1], reverse=True)

    scope = BOROUGHS[args.borough] if args.borough else "New York City"
    print(f"\nHouseholds likely without in-unit laundry — {scope}")
    if args.min_income:
        print(f"(assessed value per unit ≥ ${args.min_income:,})")
    print(f"{'ZIP':<8}{'no in-unit':>12}{'all units':>12}{'share':>9}{'value/unit':>14}")
    for zipcode, without, total_units, share, income in rows[: args.top]:
        inc = f"${int(income):,}" if income else "—"
        print(f"{zipcode:<8}{int(without):>12,}{int(total_units):>12,}{share:>8.0f}%{inc:>14}")

    if not rows:
        print("  no ZIPs matched those filters")
        return 0
    citywide_gap = sum(r[1] for r in rows)
    citywide_all = sum(r[2] for r in rows)
    print(f"\n{'TOTAL':<8}{int(citywide_gap):>12,}{int(citywide_all):>12,}"
          f"{citywide_gap / citywide_all * 100:>8.0f}%")
    print("\nRanked by households, not share — density decides whether a courier")
    print("route works, and a high share of a small ZIP is not a market.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
