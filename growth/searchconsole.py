#!/usr/bin/env python3
"""Rank, when Google will tell us — and an honest silence when it will not.

Everything else in this engine measures whether we *tried*: a page exists, a
link was added, a URL was submitted. This is the only module that can say
whether any of it *worked*, because position is a fact only Google holds.
Scraping the results page is against its terms and is blocked anyway.

**creasenyc.com is not verified in Search Console yet.** Until it is, every
function here returns `measured: False` and the engine runs on coverage, which
is a proxy and is labelled as one everywhere it is printed. That is deliberate:
the alternative — inventing a position, or treating "no data" as "position 0" —
would make review.py retire pages for failing a measurement that never ran.

To connect it (technique `search_console` in the ledger, one manual step):

  1. Add creasenyc.com in Search Console as a URL-prefix property and verify
     it. The site already serves /robots.txt and a sitemap, so the HTML-file or
     DNS method both work.
  2. Add the service account's client_email as a **Full** user on the property.
     A Restricted user cannot read Search Analytics.
  3. Put the service-account JSON on the droplet and point SC_KEY_FILE at it.

The account that reads findacrib.com is not reused: one property's key held by
two engines means revoking either revokes both.
"""
import base64
import datetime
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

from . import keywords, ledger

SITE_URL = os.environ.get("CREASE_SC_SITE", "https://creasenyc.com/")
SCOPE = "https://www.googleapis.com/auth/webmasters.readonly"
TOKEN_URI = "https://oauth2.googleapis.com/token"
API = ("https://searchconsole.googleapis.com/webmasters/v3/sites/"
       + urllib.parse.quote(SITE_URL, safe="") + "/searchAnalytics/query")

HERE = os.path.dirname(os.path.abspath(__file__))
PAGES_PATH = os.path.join(HERE, "gsc_pages.json")


class NotConnected(Exception):
    """No key, no property, or no permission. Not an error — a state."""


def load_key():
    path = os.environ.get("SC_KEY_FILE")
    if path and os.path.exists(path):
        try:
            with open(path) as f:
                return json.load(f)
        except Exception as e:
            raise NotConnected(f"SC_KEY_FILE unreadable: {e}")
    blob = os.environ.get("SC_KEY_JSON")
    if blob:
        try:
            return json.loads(blob)
        except Exception as e:
            raise NotConnected(f"SC_KEY_JSON unparseable: {e}")
    raise NotConnected("no service-account key (set SC_KEY_FILE or SC_KEY_JSON)")


def _b64(d):
    return base64.urlsafe_b64encode(d).rstrip(b"=")


def access_token(key):
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding
    except ImportError:
        raise NotConnected("python3-cryptography is not installed on this host")
    now = int(time.time())
    header = _b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = _b64(json.dumps({
        "iss": key["client_email"], "scope": SCOPE, "aud": TOKEN_URI,
        "iat": now, "exp": now + 3600}).encode())
    signing_input = header + b"." + claims
    private = serialization.load_pem_private_key(key["private_key"].encode(), password=None)
    sig = _b64(private.sign(signing_input, padding.PKCS1v15(), hashes.SHA256()))
    assertion = (signing_input + b"." + sig).decode()
    data = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": assertion}).encode()
    try:
        with urllib.request.urlopen(TOKEN_URI, data=data, timeout=30) as r:
            return json.loads(r.read().decode())["access_token"]
    except urllib.error.HTTPError as e:
        raise NotConnected(f"token exchange failed: {e.read().decode('utf-8', 'replace')[:200]}")


def _query(token, body):
    req = urllib.request.Request(
        API, data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode()).get("rows", [])
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:200]
        if e.code in (403, 404):
            raise NotConnected(f"property {SITE_URL} not readable by this account: {detail}")
        raise


def collect(days=28):
    """Pull positions for the tracked queries and per-page impressions.

    Search Console lags two to three days, so the window is wide on purpose: a
    three-day window on a site with this little traffic returns almost nothing
    and the share number swings on noise.

    Returns a dict; raises NotConnected if the property is not wired up, which
    the caller reports rather than treats as a failure.
    """
    key = load_key()
    token = access_token(key)
    end = datetime.date.today() - datetime.timedelta(days=2)
    start = end - datetime.timedelta(days=days)
    base = {"startDate": start.isoformat(), "endDate": end.isoformat(), "rowLimit": 5000}

    by_query = {}
    for row in _query(token, {**base, "dimensions": ["query"]}):
        q = (row.get("keys") or [""])[0].lower()
        by_query[q] = {"position": round(row.get("position", 0), 1),
                       "impressions": int(row.get("impressions", 0)),
                       "clicks": int(row.get("clicks", 0))}

    pages = []
    for row in _query(token, {**base, "dimensions": ["page"]}):
        pages.append({"url": (row.get("keys") or [""])[0],
                      "impressions": int(row.get("impressions", 0)),
                      "clicks": int(row.get("clicks", 0)),
                      "position": round(row.get("position", 0), 1)})

    # Write positions back onto the tracked queries. Only queries we track: the
    # rest is real data, but it is not the universe the goal is a share of.
    kws = keywords.load()
    matched = 0
    for k in kws:
        hit = by_query.get(k["query"])
        if hit:
            k.update(position=hit["position"], impressions=hit["impressions"],
                     clicks=hit["clicks"], position_checked=ledger.today())
            matched += 1
    keywords.save(kws)

    doc = {"checked": ledger.today(), "window": [start.isoformat(), end.isoformat()],
           "pages": pages, "queries_matched": matched,
           "queries_total_in_gsc": len(by_query)}
    tmp = PAGES_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    os.replace(tmp, PAGES_PATH)

    # Recorded as a series so review.py and the report can read visibility per
    # technique without re-querying, and so today's number has a yesterday.
    ledger.record_result(ledger.today(), "__site__", "serving_pages", len(pages))
    ledger.record_result(ledger.today(), "__site__", "search_impressions",
                         sum(p["impressions"] for p in pages))
    ledger.record_result(ledger.today(), "__site__", "search_clicks",
                         sum(p["clicks"] for p in pages))
    return doc


def load_pages():
    try:
        with open(PAGES_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def _path(url):
    try:
        return urllib.parse.urlparse(url).path or "/"
    except Exception:
        return ""


def recent_visibility(slug, since=None, window=7):
    """How visible one technique's own URLs are in search.

    review.py uses this to tell "invisible" from "served but not clicked" —
    two states that look identical in a visitor count of zero and need opposite
    responses. `measured: False` means Search Console has never answered, and
    review.py must not retire anything on the strength of it.
    """
    out = {"measured": False, "pages": 0, "impressions": 0, "best_position": None}
    doc = load_pages()
    if not doc.get("pages"):
        return out
    t = ledger.get(slug) or {}
    prefixes = t.get("prefixes") or []
    if not prefixes:
        return out
    out["measured"] = True
    best = None
    for p in doc["pages"]:
        path = _path(p["url"])
        if not any(path == pref.rstrip("/") or path.startswith(pref) for pref in prefixes):
            continue
        out["pages"] += 1
        out["impressions"] += p["impressions"]
        if p["position"] and (best is None or p["position"] < best):
            best = p["position"]
    out["best_position"] = best
    return out


def status():
    """One line for the report: connected, or exactly what is missing."""
    try:
        key = load_key()
    except NotConnected as e:
        return {"connected": False, "why": str(e)}
    try:
        access_token(key)
    except NotConnected as e:
        return {"connected": False, "why": str(e), "account": key.get("client_email")}
    doc = load_pages()
    return {"connected": True, "account": key.get("client_email"),
            "last_checked": doc.get("checked"), "serving_pages": len(doc.get("pages") or [])}
