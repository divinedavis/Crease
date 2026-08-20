#!/usr/bin/env python3
"""Is Google actually indexing this site, and if not, how far did it get?

Impressions cannot answer that. An impression needs two independent things —
the page is in the index, AND somebody typed a query it could answer — so zero
impressions on a three-week-old site is consistent with "not indexed" and with
"indexed, nobody searched". Those two have opposite responses, and on a site
this new almost everything is zero, so the ambiguity is total.

The URL Inspection API returns Google's own coverage state per URL, which is
the direct measurement. Find A Crib has had this since 2026-08-17; this is the
same instrument pointed at a site small enough not to need any of its
machinery.

**No sampling here, deliberately.** Find A Crib inspects a stratified, stable
cohort because it publishes ~47,600 pages against a 2,000/day quota. This
sitemap is 31 URLs. The whole corpus fits in one run with room to spare, so
every URL is read every time and there is no cohort to keep stable, no
stratification to get wrong, and no sampling error to reason about.

Output is public URLs and Google's public opinion of them — no PII — so
index_status.json is tracked in git.

Needs the Search Console key, so it runs on the droplet only. When there is no
key it raises NotConnected like its neighbour rather than inventing a state:
"not measured" and "not indexed" must never render as the same thing.
"""
import datetime
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

from . import ledger, searchconsole

SITE_URL = os.environ.get("CREASE_SC_SITE", "https://creasenyc.com/")
SITEMAP = os.environ.get("CREASE_SITEMAP", "https://creasenyc.com/sitemap.xml")
INSPECT_API = "https://searchconsole.googleapis.com/v1/urlInspection/index:inspect"

HERE = os.path.dirname(os.path.abspath(__file__))
STATUS_PATH = os.path.join(HERE, "index_status.json")

# Google's quota is 2,000 inspections/day and 600/minute per property. A cap
# well above this sitemap is still worth having: the guides technique adds a
# page a day, and an engine that silently starts costing 2,000 calls because a
# sitemap grew is the kind of thing that is only noticed in a bill.
MAX_URLS = int(os.environ.get("CREASE_INDEX_MAX", "300"))
PACE_SECONDS = 0.4        # ~150/min against a 600/min ceiling

# Google's coverageState strings are prose and have changed wording before, so
# match on the substring that carries the meaning rather than on equality.
# Vocabulary lifted from Find A Crib's indexstatus.py, including the lesson
# that cost it three weeks: without the "unknown to google" needle, the single
# most decision-relevant state falls into a catch-all bucket and is invisible.
_STATE_BUCKETS = (
    ("indexed", ("submitted and indexed", "indexed, not submitted")),
    ("crawled_not_indexed", ("crawled - currently not indexed",
                             "crawled — currently not indexed")),
    ("discovered_not_indexed", ("discovered - currently not indexed",
                                "discovered — currently not indexed")),
    # Not merely un-indexed — never fetched at all. The discriminator is that a
    # never-seen URL also carries no lastCrawlTime and an unspecified fetch
    # state; Google has been observed relabelling long-known URLs "unknown"
    # while they keep their crawl time. Check that split before reading this
    # bucket as "never discovered".
    ("unknown_to_google", ("unknown to google",)),
    ("duplicate", ("duplicate", "alternate page")),
    ("excluded_noindex", ("noindex",)),
    ("blocked", ("blocked", "robots.txt")),
    ("redirect", ("redirect",)),
    ("not_found", ("not found", "404", "soft 404")),
)
BUCKETS = [b for b, _ in _STATE_BUCKETS] + ["other", "unknown"]


def bucket(state):
    if not state:
        return "unknown"
    s = state.strip().lower()
    for name, needles in _STATE_BUCKETS:
        if any(nd in s for nd in needles):
            return name
    return "other"


def sitemap_urls(url=None, timeout=20):
    """Every <loc> in the sitemap, in document order."""
    req = urllib.request.Request(url or SITEMAP,
                                 headers={"User-Agent": "crease-growth/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        root = ET.fromstring(r.read())
    ns = "{http://www.sitemaps.org/schemas/sitemap/0.9}"
    return [e.text.strip() for e in root.iter(ns + "loc") if e.text]


def inspect(token, url, timeout=30):
    """One URL Inspection call. Returns (record, error_string)."""
    body = json.dumps({"inspectionUrl": url, "siteUrl": SITE_URL,
                       "languageCode": "en-US"}).encode()
    req = urllib.request.Request(
        INSPECT_API, data=body,
        headers={"Authorization": "Bearer " + token,
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            payload = json.loads(r.read())
    except urllib.error.HTTPError as e:
        return None, "HTTP %d: %s" % (e.code, e.read().decode("utf-8", "replace")[:200])
    except Exception as e:
        return None, "%s: %s" % (type(e).__name__, e)
    idx = ((payload.get("inspectionResult") or {}).get("indexStatusResult") or {})
    state = idx.get("coverageState")
    rec = {
        "state": state,
        "bucket": bucket(state),
        "verdict": idx.get("verdict"),
        "crawled": (idx.get("lastCrawlTime") or "")[:10] or None,
        "fetch": idx.get("pageFetchState"),
        "checked": datetime.date.today().isoformat(),
    }
    # A Google-chosen canonical that differs from the submitted URL means the
    # page is indexed under somebody else's address and will never serve under
    # its own. Recorded only when it actually differs, so the common case costs
    # no bytes.
    gc = idx.get("googleCanonical")
    if gc and gc.rstrip("/") != url.rstrip("/"):
        rec["google_canonical"] = gc
    return rec, None


def load():
    try:
        with open(STATUS_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def run(limit=None, dry_run=False):
    """Inspect every sitemap URL and write index_status.json."""
    key = searchconsole.load_key()          # raises NotConnected without one
    token = searchconsole.access_token(key)
    urls = sitemap_urls()
    capped = len(urls) > (limit or MAX_URLS)
    urls = urls[: (limit or MAX_URLS)]

    pages, errors = {}, []
    for i, u in enumerate(urls):
        rec, err = inspect(token, u)
        if err:
            errors.append({"url": u, "error": err})
            # A quota refusal is not a per-URL problem and retrying the other
            # 30 just burns the rest of it. Stop and report what was read.
            if "429" in err or "RESOURCE_EXHAUSTED" in err:
                errors.append({"url": "(stopped)", "error": "quota exhausted"})
                break
        else:
            pages[u] = rec
        if i + 1 < len(urls):
            time.sleep(PACE_SECONDS)

    counts = {b: 0 for b in BUCKETS}
    for rec in pages.values():
        counts[rec["bucket"]] = counts.get(rec["bucket"], 0) + 1
    read = len(pages)
    fetched = sum(counts[b] for b in
                  ("indexed", "crawled_not_indexed", "duplicate",
                   "excluded_noindex", "redirect", "not_found"))
    doc = {
        "updated": datetime.date.today().isoformat(),
        "site": SITE_URL,
        "sitemap_urls": len(sitemap_urls()) if capped else read + len(
            [e for e in errors if e["url"] != "(stopped)"]),
        "inspected": read,
        "buckets": counts,
        # Two different denominators, because they answer different questions.
        # accept_pct is "of everything we published"; accept_of_fetched is "of
        # what Google actually looked at" — the second is the one that says
        # whether the pages are good enough, the first mixes that up with
        # whether Google has got round to them yet.
        "accept_pct": round(100.0 * counts["indexed"] / read, 1) if read else None,
        "accept_of_fetched": round(100.0 * counts["indexed"] / fetched, 1) if fetched else None,
        "capped": capped,
        "errors": errors[:10],
        "pages": pages,
    }
    if not dry_run:
        tmp = STATUS_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(doc, f, indent=1, sort_keys=True)
        os.replace(tmp, STATUS_PATH)
    return doc


def summary(doc=None):
    """One compact block for the report and the dashboard."""
    d = doc or load()
    if not d:
        return {"measured": False}
    b = d.get("buckets") or {}
    return {
        "measured": True,
        "updated": d.get("updated"),
        "sitemap_urls": d.get("sitemap_urls"),
        "inspected": d.get("inspected"),
        "indexed": b.get("indexed", 0),
        "crawled_not_indexed": b.get("crawled_not_indexed", 0),
        "discovered_not_indexed": b.get("discovered_not_indexed", 0),
        "unknown_to_google": b.get("unknown_to_google", 0),
        "accept_pct": d.get("accept_pct"),
        "accept_of_fetched": d.get("accept_of_fetched"),
        "errors": len(d.get("errors") or []),
    }


if __name__ == "__main__":
    print(json.dumps(summary(run()), indent=2))
