#!/usr/bin/env python3
"""Who actually visited creasenyc.com, out of the nginx log.

Counted from the server's own log rather than a JavaScript tag: an ad-blocker
cannot hide a visitor and a tag cannot be fired by a crawler. That trade buys
honesty on the human side and hands back the whole bot problem, which is what
almost all of this file is.

The filters are the ones the owner dashboard already uses (crease_metrics.py in
the Find-A-Crib repo, which renders that dashboard). **The two copies must be
kept in step**: they read the same log and are quoted side by side, so a rule
that exists in one and not the other shows up as two different numbers for the
same day and no way to tell which is wrong. They are duplicated rather than
imported because they live in different repositories on different deploy
cadences, and a cron that dies when the other repo moves is worse than a rule
written twice.

On this site's first day, 62 "visitors" were counted and not one was a person:
scanners probing /.env and /wp-admin behind ordinary Chrome and Safari strings,
a LeakIX prober, and the owner's own browser automation. The user-agent string
is the honest half of the problem; the rules below are the rest.
"""
import datetime
import gzip
import json
import os
import re
import socket

ACCESS_LOG = os.environ.get("CREASE_ACCESS_LOG", "/var/log/nginx/creasenyc.access.log")
HOSTS = {"creasenyc.com", "www.creasenyc.com", "usecreaseapp.com", "www.usecreaseapp.com"}

# Deliberately broad. A crawler counted as a visitor is a lie the ledger then
# repeats every day and reviews act on; a person wrongly excluded is one visit,
# once.
BOT = re.compile(
    r"bot|crawl|spider|slurp|bing|yandex|baidu|duckduck|semrush|ahrefs|mj12|dotbot|"
    r"petal|bytespider|facebookexternalhit|whatsapp|telegram|preview|monitor|uptime|"
    r"curl|wget|python-requests|okhttp|headless|lighthouse|pingdom|scanner|nuclei",
    re.I,
)

# A page view is a page. Chunks, images and the robots file are not visits, and
# counting them turns one reader into thirty.
ASSET = re.compile(
    r"^/(?:_next/|assets/|favicon|robots\.txt|sitemap\.xml|.*\.(?:svg|png|jpg|ico|css|js|map|txt)$)")

# Nobody looking for a laundry service asks for /.env. One of these from an
# address marks everything it did that day as a scan, not a visit.
PROBE = re.compile(
    r"\.env|/wp-|/admin|\.git|graphql|phpmyadmin|/vendor|/actuator|/telescope|"
    r"\.aws|/config\.json|/config/|/backend/|/\.well-known/security|xmlrpc|"
    r"/owa/|/autodiscover|\.php$",
    re.I,
)

# Where a customer cannot be. Blunt on purpose: this also drops a real person
# on a VPN, which for a neighborhood laundry service is a rounding error
# against counting a crawler as demand. First octets match as prefixes.
DATACENTER_PREFIXES = (
    "158.69.", "167.114.", "51.222.", "51.79.", "51.91.", "57.128.", "139.99.",
    "141.94.", "149.202.", "51.68.", "51.75.", "51.83.", "54.36.", "54.37.",
    "34.", "35.",
    "54.", "52.", "18.", "3.", "44.", "56.", "98.87.", "174.129.", "100.24.",
    "100.25.", "100.26.", "107.20.", "184.72.", "184.73.",
    "164.90.", "167.172.", "165.227.", "104.236.", "159.203.", "165.22.",
    "178.128.", "134.209.", "146.190.", "144.126.", "138.68.", "142.93.",
    "143.198.", "157.245.", "161.35.", "159.65.", "159.89.", "68.183.",
    "20.", "40.", "13.", "152.233.",
    "43.", "47.",
    "5.9.", "95.216.", "168.119.", "116.202.", "49.12.", "78.46.", "88.99.",
    "62.210.", "51.15.", "163.172.", "212.83.",
    "172.236.", "172.237.", "45.79.", "45.33.", "139.144.", "170.187.",
    "146.75.", "151.101.", "199.232.",
    "149.57.", "146.70.", "149.88.", "185.254.", "62.93.", "89.187.",
    "138.199.", "143.244.", "156.146.", "185.156.", "37.19.",
    "165.225.", "216.73.", "104.129.",
    "103.196.", "45.88.", "136.0.74.", "149.19.255.", "205.169.39.",
    "216.38.230.", "194.36.25.", "192.253.209.", "204.101.161.", "23.27.145.",
    "89.248.", "80.82.", "198.44.138.", "111.248.200.", "104.164.218.",
)

# The prefix table is a list somebody has to maintain. The network's own name
# is the durable tell: a rack in Ashburn answers to ec2-….amazonaws.com, a
# phone in Brooklyn answers to something with verizon, spectrum or t-mobile.
#
# Deliberately not matched: "cloud", "relay", "proxy". iCloud Private Relay is
# how a large share of iPhone owners browse and it exits through Cloudflare,
# Akamai and Fastly under names carrying all three words. Excluding those
# excludes exactly the Brooklyn customer this site is for.
HOSTING_PTR = re.compile(
    r"amazonaws|googleusercontent|google\.com$|azure|cloudapp|digitalocean|"
    r"linode|vultr|ovh\.|hetzner|scaleway|online\.net|contabo|hostinger|"
    r"leaseweb|datapacket|m247|datacamp|choopa|quadranet|colocrossing|tzulo|"
    r"servers\.com|hosting|vps|dedicated|tor-exit",
    re.I,
)

# A browser a year behind is not a browser. Chrome ships a major version every
# four weeks and updates itself; the scan waves here wear Chrome 42, 45, 79, 83
# and 92 while claiming to be Windows desktops. Bump when it starts excluding
# people — deliberately about a year behind stable (151 in August 2026).
STALE_CHROME = 135
CHROME_VERSION = re.compile(r"Chrome/(\d+)")

# /?owner=1 leaves a cookie and nginx logs it as the last field of every
# request (since 2026-08-19). A device carrying it is the owner's, on whatever
# network it is on — the failure an address list can never cover, because a
# phone on Private Relay or a hotspot changes address between visits.
OWNER_COOKIE = "1"
OWNER_FILE = os.environ.get("CREASE_OWNER_FILE", "/var/lib/crease/owner-ips.json")
OWNER_TTL_DAYS = 14

# Shared with the dashboard on purpose — one resolver cache for the box. Both
# writers replace it atomically, so the worst case is one losing the other's
# additions, which costs a repeated lookup and nothing else.
PTR_FILE = os.environ.get("CREASE_PTR_FILE", "/var/lib/crease/ptr-cache.json")
PTR_LOOKUPS_PER_RUN = 120

LINE = re.compile(
    r'^(?P<host>\S+) (?P<ip>\S+) \S+ \S+ \[(?P<ts>[^\]]+)\] '
    r'"(?P<method>\S+) (?P<path>\S+) [^"]*" (?P<status>\d{3}) \S+ '
    r'"(?P<ref>[^"]*)" "(?P<ua>[^"]*)"'
    # nginx appends $request_time, $upstream_response_time and the owner cookie
    # after this, each added on a different day. All optional, so a line from
    # before any of them still parses against the same expression.
    r'(?: \S+(?: \S+(?: "(?P<owner>[^"]*)")?)?)?'
)

SEARCH_REFERRER = re.compile(
    r"^https?://(?:[a-z0-9-]+\.)*(google|bing|duckduckgo|yahoo|ecosia|brave|"
    r"startpage|qwant|baidu|yandex)\.", re.I)


def owner_ips():
    ips = {ip.strip() for ip in os.environ.get("CREASE_OWNER_IPS", "").split(",") if ip.strip()}
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=OWNER_TTL_DAYS)
    try:
        with open(OWNER_FILE) as f:
            for entry in json.load(f).get("ips", []):
                if isinstance(entry, dict):
                    ip, at = str(entry.get("ip") or ""), str(entry.get("at") or "")
                    if not ip:
                        continue
                    try:
                        seen = datetime.datetime.fromisoformat(at.replace("Z", "+00:00"))
                        if seen.tzinfo is None:
                            seen = seen.replace(tzinfo=datetime.timezone.utc)
                        if seen < cutoff:
                            continue
                    except ValueError:
                        pass
                    ips.add(ip)
                else:
                    ips.add(str(entry))
    except (OSError, ValueError):
        pass
    return ips


class _Ptr:
    """Reverse lookups, cached on disk and bounded per run.

    Unresolvable is recorded as "" and cached: no PTR is not proof of anything,
    but re-asking a resolver the same unanswerable question every morning is.
    """

    def __init__(self, budget=None):
        # Read the module global at call time, not as a default argument: a
        # default is bound once at import, so setting PTR_LOOKUPS_PER_RUN — the
        # obvious way to turn lookups off in a test or on a resolver-less box —
        # silently did nothing.
        self.budget = PTR_LOOKUPS_PER_RUN if budget is None else budget
        self.dirty = False
        try:
            with open(PTR_FILE) as f:
                self.cache = dict(json.load(f))
        except (OSError, ValueError):
            self.cache = {}

    def hosting(self, ip):
        name = self.cache.get(ip)
        if name is None:
            if self.budget <= 0:
                return False        # unknown counts as a person, not a machine
            self.budget -= 1
            try:
                socket.setdefaulttimeout(3)
                name = socket.gethostbyaddr(ip)[0]
            except Exception:
                name = ""
            finally:
                socket.setdefaulttimeout(None)
            self.cache[ip] = name
            self.dirty = True
        return bool(name) and bool(HOSTING_PTR.search(name))

    def save(self):
        if not self.dirty:
            return
        try:
            os.makedirs(os.path.dirname(PTR_FILE), exist_ok=True)
            tmp = PTR_FILE + ".tmp"
            with open(tmp, "w") as f:
                json.dump(self.cache, f)
            os.replace(tmp, PTR_FILE)
        except OSError:
            pass


def _stale_browser(ua):
    m = CHROME_VERSION.search(ua)
    return bool(m) and int(m.group(1)) < STALE_CHROME


def _parse_day(ts):
    """'19/Aug/2026:18:05:32 +0000' -> '2026-08-19' (the log's own clock, UTC)."""
    try:
        return datetime.datetime.strptime(ts.split()[0], "%d/%b/%Y:%H:%M:%S").date().isoformat()
    except Exception:
        return ""


def _open(path):
    return gzip.open(path, "rt", errors="replace") if path.endswith(".gz") \
        else open(path, errors="replace")


def log_files(path=None):
    """The live log plus whatever logrotate has kept, newest first.

    Yesterday's traffic sits in the rotated file for the whole of the morning
    after a rotation, so reading only the live log would report zero on exactly
    the days rotation happened.
    """
    base = path or ACCESS_LOG
    out = [base]
    for suffix in (".1", ".1.gz", ".2.gz", ".3.gz"):
        p = base + suffix
        if os.path.exists(p):
            out.append(p)
    return [p for p in out if os.path.exists(p)]


def read_day(day, path=None):
    """Every request logged on `day` (UTC), classified.

    Returns (rows, counters). A row is a dict with ip, path, status, ua, ref,
    and `human` — whether it survived every filter. Nothing here returns a
    person: the address is used to group requests into visits within this
    function's caller and is never written anywhere.
    """
    owners = owner_ips()
    ptr = _Ptr()
    raw = []
    for f in log_files(path):
        try:
            with _open(f) as fh:
                for line in fh:
                    m = LINE.match(line)
                    if not m:
                        continue
                    if _parse_day(m.group("ts")) != day:
                        continue
                    if m.group("host") not in HOSTS:
                        continue
                    raw.append(m)
        except OSError:
            continue

    # Address-level verdicts first: one probe request condemns everything that
    # address did that day, which is the point — a scanner that also fetches the
    # home page is still a scanner.
    probed, cookie_owner = set(), set()
    for m in raw:
        if PROBE.search(m.group("path")):
            probed.add(m.group("ip"))
        if (m.group("owner") or "") == OWNER_COOKIE:
            cookie_owner.add(m.group("ip"))

    counters = {"lines": len(raw), "bot_ua": 0, "asset": 0, "probe": 0,
                "owner": 0, "datacenter": 0, "hosting_ptr": 0, "stale_browser": 0,
                "error": 0}
    rows = []
    for m in raw:
        ip, ua, path_, status = m.group("ip"), m.group("ua"), m.group("path"), m.group("status")
        row = {"ip": ip, "path": path_.split("?")[0], "status": int(status),
               "ua": ua, "ref": m.group("ref") or "", "human": False}
        if ASSET.match(row["path"]):
            counters["asset"] += 1
            rows.append(row)
            continue
        if ip in cookie_owner or ip in owners:
            counters["owner"] += 1
        elif BOT.search(ua) or not ua or ua == "-":
            counters["bot_ua"] += 1
        elif ip in probed:
            counters["probe"] += 1
        elif ip.startswith(DATACENTER_PREFIXES):
            counters["datacenter"] += 1
        elif _stale_browser(ua):
            counters["stale_browser"] += 1
        elif ptr.hosting(ip):
            counters["hosting_ptr"] += 1
        elif row["status"] >= 400:
            # A 404 is not a page view. Counted separately rather than dropped
            # silently, because a burst of them is a broken link, not a bot.
            counters["error"] += 1
        else:
            row["human"] = True
        rows.append(row)
    ptr.save()
    return rows, counters


def visits(rows):
    """Human page views grouped into visitors.

    A visitor is one (address, user-agent) pair for the day. Coarse — a
    household behind one address browsing on two phones is two visitors, and
    the same phone on wifi and cellular is also two — but it is stable, needs no
    cookie, and never leaves this process.
    """
    seen, paths, organic = {}, {}, set()
    for r in rows:
        if not r["human"]:
            continue
        key = (r["ip"], r["ua"])
        seen.setdefault(key, 0)
        seen[key] += 1
        paths.setdefault(r["path"], set()).add(key)
        if SEARCH_REFERRER.match(r["ref"]):
            organic.add(key)
    return {
        "visitors": len(seen),
        "pageviews": sum(seen.values()),
        "organic_visitors": len(organic),
        "by_path": {p: len(v) for p, v in sorted(paths.items(), key=lambda kv: -len(kv[1]))},
        "_by_path_keys": paths,
    }
