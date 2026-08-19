#!/usr/bin/env python3
"""Yesterday, measured, and written into the ledger.

Two sources, and the split is the whole point:

  the nginx log    who came. Server-side, so an ad-blocker cannot hide a
                   visitor and a tag cannot be fired by a crawler. See
                   traffic.py for the filtering, which is most of the work.
  the dispatcher   what they did — addresses checked, pickups requested,
                   orders placed. Read over loopback from the service that owns
                   that schema, rather than this process holding Crease's
                   service-role key for the sake of a dozen counts.

Traffic without the funnel is vanity: a morning that doubles visitors and moves
no addresses through the coverage check has not sold anything, and the daily
report should be able to say so.

Two shapes of series are written:

  __site__ rows      the site as a whole. `visitors` and `organic_visitors` are
                     per-day counts; the dispatcher's numbers are CUMULATIVE
                     totals, suffixed `_total`, because that API answers "since
                     when" and not "yesterday". A day's change is the difference
                     between two rows, and deriving it that way survives a
                     morning the cron did not run — a stored daily delta would
                     silently be a two-day delta.
  per-technique rows `owned_visitors`, the visitors whose first human request
                     was under one of that technique's URL prefixes. This is
                     what review.py judges a technique on, so a technique that
                     declares no prefixes is judged on a site-wide metric
                     instead and never on this.
"""
import datetime
import json
import os
import urllib.error
import urllib.request

from . import ledger, traffic

DISPATCH_URL = os.environ.get("CREASE_DISPATCH_URL", "http://127.0.0.1:8011")
INTERNAL_KEY = os.environ.get("CREASE_INTERNAL_KEY", "") or os.environ.get("INTERNAL_API_KEY", "")


def yesterday():
    """The log stamps UTC, so the day boundary is UTC. Said out loud because
    the cron is pinned to America/New_York and the two disagree by five hours —
    a run at 05:20 ET reads a day that ended at 20:00 ET the evening before."""
    return (datetime.datetime.now(datetime.timezone.utc).date()
            - datetime.timedelta(days=1)).isoformat()


def dispatch_stats(range_="all", timeout=20):
    """The funnel, from the service that owns it. Returns None if unreachable.

    None and zero are different answers and the report prints them differently:
    a dispatcher that is down is an outage, and a dispatcher reporting no orders
    is a Tuesday.
    """
    if not INTERNAL_KEY:
        return None
    req = urllib.request.Request(
        f"{DISPATCH_URL}/v1/stats/dashboard?range={range_}",
        headers={"x-crease-key": INTERNAL_KEY})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            doc = json.loads(r.read().decode())
    except Exception:
        return None
    return doc.get("stats") if doc.get("ok") else None


def collect(day=None):
    """Read everything for one day. Pure — writes nothing."""
    day = day or yesterday()
    rows, counters = traffic.read_day(day)
    v = traffic.visits(rows)
    stats = dispatch_stats()

    per_technique = {}
    for t in ledger.active():
        prefixes = t.get("prefixes") or []
        if not prefixes:
            continue
        keys = set()
        for path, ks in v["_by_path_keys"].items():
            if any(path == p.rstrip("/") or path.startswith(p) for p in prefixes):
                keys |= ks
        per_technique[t["slug"]] = len(keys)

    out = {
        "date": day,
        "visitors": v["visitors"],
        "pageviews": v["pageviews"],
        "organic_visitors": v["organic_visitors"],
        "top_paths": dict(list(v["by_path"].items())[:15]),
        "filtered": counters,
        "per_technique": per_technique,
        "funnel": None,
    }
    if stats:
        demand = stats.get("demand") or {}
        orders = stats.get("orders") or {}
        requests_ = stats.get("requests") or {}
        out["funnel"] = {
            "coverage_checks_total": demand.get("checks", 0),
            "in_area_checks_total": demand.get("in_area", 0),
            "emails_left_total": demand.get("with_email", 0),
            "requests_total": requests_.get("total", 0),
            "orders_total": orders.get("total", 0),
            "orders_paid_total": orders.get("paid", 0),
            "orders_delivered_total": orders.get("delivered", 0),
        }
    return out


def collect_and_record(day=None):
    """Read one day and append it to the ledger. Idempotent per day."""
    data = collect(day)
    day = data["date"]
    for metric in ("visitors", "pageviews", "organic_visitors"):
        ledger.record_result(day, "__site__", metric, data[metric],
                             {"filtered": data["filtered"]} if metric == "visitors" else None)
    if data["funnel"]:
        for metric, value in data["funnel"].items():
            ledger.record_result(day, "__site__", metric, value)
    for slug, n in data["per_technique"].items():
        ledger.record_result(day, slug, "owned_visitors", n)
    ledger.set_state("last_measure", {"date": day, "visitors": data["visitors"],
                                      "funnel_read": bool(data["funnel"])})
    return data


def delta(metric, days=1):
    """Change in a cumulative `*_total` series over the last `days` of rows.

    Returns None when there are not two rows to compare — an honest "unknown"
    rather than a zero that reads as "nothing happened".
    """
    s = ledger.series("__site__", metric)
    if len(s) < 2:
        return None
    recent = s[-1][1]
    prior = s[max(0, len(s) - 1 - days)][1]
    return recent - prior


def recent(metric, days=7):
    """[(date, value), …] for the last `days` rows of a site-wide series."""
    return ledger.series("__site__", metric)[-days:]
