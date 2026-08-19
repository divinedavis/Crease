#!/usr/bin/env python3
"""The tracked query universe — what "found in Brooklyn" actually means.

You cannot own a share of a market you have not written down, so this file
writes it down: the queries somebody types when they want laundry collected in
Brooklyn. Two very different things get measured against it.

  coverage  does a page on this site exist that actually targets this query?
            Computable today, by asking the running site for the page and
            reading its title and h1. It is a proxy, and it is labelled as one
            everywhere it is printed.
  position  where do we rank? Only Search Console answers that truthfully —
            scraping the results page is against Google's terms and is blocked
            anyway. Until the property is verified, `position` stays null.

Coverage is not rank. A page that exists and ranks 80th is `covered: true` and
worth nothing; the report never prints one where a reader would read the other.

The uncovered "explain" queries are also the guide queue: writer.py takes the
oldest uncovered one and writes the page that answers it. So this list is not
only a scoreboard — it is the roadmap, and the scout extends it.

Entries are never deleted. The year-end review is only worth reading if it
still shows the queries that were never cracked.
"""
import json
import os
import re
import urllib.error
import urllib.request

from . import ledger

HERE = os.path.dirname(os.path.abspath(__file__))
KEYWORDS_PATH = os.path.join(HERE, "keywords.json")

# The neighborhoods with their own page. Kept in step with
# apps/web/lib/neighborhoods.ts by hand — there is no runtime that reads both,
# and a stale entry here shows up immediately as an uncovered query rather than
# as silence.
CORE_AREAS = [
    ("Clinton Hill", "clinton-hill"), ("Prospect Heights", "prospect-heights"),
    ("Fort Greene", "fort-greene"), ("Bedford-Stuyvesant", "bedford-stuyvesant"),
    ("Park Slope", "park-slope"), ("Downtown Brooklyn", "downtown-brooklyn"),
    ("DUMBO", "dumbo"), ("Boerum Hill", "boerum-hill"),
    ("Crown Heights", "crown-heights"), ("Gowanus", "gowanus"),
    ("Carroll Gardens", "carroll-gardens"), ("Cobble Hill", "cobble-hill"),
    ("Red Hook", "red-hook"), ("Brooklyn Heights", "brooklyn-heights"),
    ("Williamsburg", "williamsburg"), ("Bushwick", "bushwick"),
    ("Greenpoint", "greenpoint"), ("Flatbush", "flatbush"),
]

# intent drives what a query is worth and which page should answer it:
#   buy     ready to book — the home page or an area page, and the only intent
#           that converts on the first visit
#   local   "near me" / a neighborhood name — an area page
#   explain a question — a guide. These earn links and AI citations rather than
#           orders, and they are the queue writer.py works through.
SEED = [
    # ---- buy
    ("buy", "laundry pickup and delivery brooklyn", "/"),
    ("buy", "wash and fold brooklyn", "/"),
    ("buy", "laundry service brooklyn", "/"),
    ("buy", "laundry delivery brooklyn", "/"),
    ("buy", "wash and fold delivery brooklyn", "/"),
    ("buy", "laundry pickup service nyc", "/"),
    ("buy", "same day laundry service brooklyn", "/"),
    ("buy", "laundry pickup near me", "/"),
    ("buy", "wash and fold near me", "/"),
    ("buy", "laundromat that picks up and delivers brooklyn", "/"),
    ("buy", "cheap laundry service brooklyn", "/"),
    ("buy", "dry cleaning pickup and delivery brooklyn", "/"),

    # ---- explain (the guide queue)
    ("explain", "how much does wash and fold cost", ""),
    ("explain", "how much does a load of laundry weigh", ""),
    ("explain", "wash and fold vs dry cleaning", ""),
    ("explain", "is laundry pickup and delivery worth it", ""),
    ("explain", "how does laundry pickup and delivery work", ""),
    ("explain", "how long does wash and fold take", ""),
    ("explain", "laundry cost per pound nyc", ""),
    ("explain", "how to do laundry without a washing machine in your apartment", ""),
    ("explain", "what does a laundromat charge per pound", ""),
    ("explain", "how much laundry fits in a bag", ""),
    ("explain", "do laundry services separate colors", ""),
    ("explain", "how to get laundry done in a walk up apartment", ""),
]


def load():
    try:
        with open(KEYWORDS_PATH) as f:
            return json.load(f)
    except Exception:
        return []


def save(kws):
    tmp = KEYWORDS_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(kws, f, indent=2)
        f.write("\n")
    os.replace(tmp, KEYWORDS_PATH)


def seed():
    """Create the universe if absent. Idempotent — never clobbers added queries.

    Seed-sourced rows are re-pointed at their current SEED target: retargeting
    a query here (say, once a guide exists to answer it) would otherwise do
    nothing, because the query already exists and is skipped, and the roadmap
    would drift from the ledger with no signal. A target the scout or the
    writer chose is its own and is left alone.
    """
    kws = load()
    by_query = {k["query"]: k for k in kws}
    rows = list(SEED)
    for name, slug in CORE_AREAS:
        rows.append(("local", f"laundry pickup {name.lower()}", f"/laundry-pickup/{slug}"))
        rows.append(("local", f"wash and fold {name.lower()}", f"/laundry-pickup/{slug}"))

    retargeted = 0
    for intent, query, target in rows:
        existing = by_query.get(query)
        if existing is None:
            kws.append({"query": query, "intent": intent, "target": target,
                        "source": "seed", "added": ledger.today(),
                        "covered": None, "position": None,
                        "impressions": None, "clicks": None})
            by_query[query] = kws[-1]
            continue
        if existing.get("source") == "seed" and existing.get("target") != target:
            existing["target"] = target
            existing["intent"] = intent
            # The old verdict was about a different page and is no longer an
            # answer to anything. "Unknown until re-checked" beats carrying a
            # `covered: true` earned by a page this query no longer points at.
            existing["covered"] = None
            existing["coverage_detail"] = f"retargeted to {target or '(none)'}, not re-checked"
            retargeted += 1
    if retargeted:
        print(f"  keywords: retargeted {retargeted} seed queries", flush=True)
    save(kws)
    return kws


# Restatements collapse to one form so "nyc" and "new york" are not tracked as
# two queries. Share is a percentage of this list; letting rephrasings inflate
# the denominator would make the number meaningless.
_ALIASES = {"nyc": "newyork", "new": "", "york": "newyork",
            "bk": "brooklyn", "bklyn": "brooklyn",
            "laundromat": "laundry", "laundromats": "laundry",
            "washing": "wash", "washed": "wash", "folded": "fold",
            "pickup": "pick", "picks": "pick", "delivers": "delivery",
            "delivered": "delivery", "apartments": "apartment",
            "costs": "cost", "pounds": "pound", "lb": "pound", "lbs": "pound"}
# Only genuinely contentless words. "near", "cheap", "same day" and "worth"
# stay: they are what separate a booking query from a price question from a
# comparison, and collapsing them merges queries that want different pages.
_NOISE = {"a", "an", "the", "is", "my", "of", "to", "and", "i", "does", "do",
          "in", "it", "your", "you"}


def _fingerprint(q):
    toks = []
    for t in re.split(r"[^a-z0-9]+", (q or "").lower()):
        if not t:
            continue
        t = _ALIASES.get(t, t)
        if t and t not in _NOISE:
            toks.append(t)
    return frozenset(toks)


def add(query, intent, target="", source="scout", note=""):
    kws = load()
    q = (query or "").strip().lower()
    if not q or any(k["query"] == q for k in kws):
        return None
    fp = _fingerprint(q)
    if fp and any(_fingerprint(k["query"]) == fp for k in kws):
        return None
    kws.append({"query": q, "intent": intent, "target": target, "source": source,
                "added": ledger.today(), "note": note, "covered": None,
                "position": None, "impressions": None, "clicks": None})
    save(kws)
    return q


def set_target(query, target):
    kws = load()
    for k in kws:
        if k["query"] == query:
            k["target"] = target
            k["covered"] = None
            k["coverage_detail"] = "newly targeted, not yet re-checked"
            save(kws)
            return k
    return None


def _tokens(s):
    return [t for t in re.split(r"[^a-z0-9]+", (s or "").lower()) if len(t) > 2]


STOP = {"the", "and", "for", "how", "what", "out", "much", "can", "you", "your",
        "are", "that", "does", "with", "without", "into", "near"}


def _fetch(base, path, timeout=10):
    url = base.rstrip("/") + (path if path.startswith("/") else "/" + path)
    req = urllib.request.Request(url, headers={
        # The site rate-limits and bot-filters by user agent; say who this is
        # rather than borrowing a browser string.
        "user-agent": "crease-growth/1.0 (+https://creasenyc.com)",
        "host": "creasenyc.com"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(200_000).decode("utf-8", "replace")


def check_coverage(base):
    """For each query, does a page exist whose title or h1 targets it?

    Asks the running site rather than reading files, because these pages are
    rendered by Next at request time and there is no HTML on disk to read.

    Deliberately shallow. It catches the real failure mode — a query nobody
    wrote a page for — without pretending to predict rank.
    """
    kws = load()

    # Guard: if the site is not answering, every query comes back uncovered and
    # a single bad morning erases real coverage history. Prove the home page
    # renders before writing anything.
    try:
        home = _fetch(base, "/")
    except Exception as e:
        raise RuntimeError(f"{base} did not serve the home page ({e}) — refusing to "
                           f"overwrite coverage with false negatives")
    if "crease" not in home.lower():
        raise RuntimeError(f"{base} served something that is not this site — refusing to "
                           f"overwrite coverage")

    cache = {"/": home}
    changed = 0
    for k in kws:
        target = k.get("target") or ""
        if not target:
            k["covered"] = False
            k["coverage_detail"] = "no page targets this query yet"
            k["coverage_checked"] = ledger.today()
            continue
        if target not in cache:
            try:
                cache[target] = _fetch(base, target)
            except urllib.error.HTTPError as e:
                cache[target] = "" if e.code == 404 else None
            except Exception:
                cache[target] = None
        html = cache[target]
        if html is None:
            # Unreachable is not uncovered. Leave the previous verdict alone.
            k["coverage_detail"] = "target unreachable this run; verdict unchanged"
            continue
        covered, detail = False, "no page at target"
        if html:
            low = html.lower()
            head = " ".join(re.findall(r"<title[^>]*>(.*?)</title>", low, re.S)
                            + re.findall(r"<h1[^>]*>(.*?)</h1>", low, re.S))
            head = re.sub(r"<[^>]+>", " ", head)
            toks = [t for t in _tokens(k["query"]) if t not in STOP]
            hit_head = sum(1 for t in toks if t in head)
            hit_body = sum(1 for t in toks if t in low)
            if toks and hit_head >= max(2, len(toks) // 2):
                covered, detail = True, "targeted by title/h1"
            elif toks and hit_body >= len(toks):
                covered, detail = True, "all terms present in body only (weak)"
            else:
                detail = f"page exists, {hit_body}/{len(toks)} terms present"
        if k.get("covered") != covered:
            changed += 1
        k["covered"] = covered
        k["coverage_detail"] = detail
        k["coverage_checked"] = ledger.today()
    save(kws)
    return kws, changed


def guide_queue(limit=20):
    """Uncovered `explain` queries, oldest first — the writer's work list."""
    return [k for k in load()
            if k.get("intent") == "explain" and not k.get("covered")
            and not (k.get("target") or "")][:limit]


def summary():
    kws = load()
    total = len(kws)
    covered = sum(1 for k in kws if k.get("covered"))
    by_intent = {}
    for k in kws:
        c = by_intent.setdefault(k.get("intent", "?"), {"total": 0, "covered": 0})
        c["total"] += 1
        c["covered"] += 1 if k.get("covered") else 0
    ranked = [k for k in kws if k.get("position")]
    top10 = sum(1 for k in ranked if (k.get("position") or 99) <= 10)
    top3 = sum(1 for k in ranked if (k.get("position") or 99) <= 3)
    return {
        "total": total,
        "covered": covered,
        "coverage_pct": round(100.0 * covered / total, 1) if total else 0.0,
        "by_intent": by_intent,
        # ranked_known is the denominator that says whether the SITE moved;
        # `total` is the one that says how far there is left to go. Reading
        # share_pct without it makes a growing keyword list look like a decline.
        "ranked_known": len(ranked),
        "top10": top10,
        "top3": top3,
        "share_pct": round(100.0 * top10 / total, 1) if total and ranked else None,
        "gaps": [k["query"] for k in kws if not k.get("covered")][:40],
    }
