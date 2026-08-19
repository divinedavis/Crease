#!/usr/bin/env python3
"""The daily report — the blunt version, in the order a reader needs it.

Ordering is the whole design. A cost failure does not look like an outage, it
looks like a slightly less productive morning: the mechanical techniques keep
succeeding and only the LLM-backed one quietly stops. So **anything blocked
prints first**, before the numbers, where it cannot be scrolled past.

Then: what moved, what ran, what is waiting on a person, and what it cost.

Two things this file refuses to do:

  * print coverage where a reader would read rank. `coverage_pct` says a page
    exists that targets the query. It says nothing about position, and on a new
    site the two are wildly different numbers. Every line that prints coverage
    says so in the line.
  * print a cumulative total as if it were a day's work. The dispatcher's
    numbers are totals since launch; the change is shown next to them or not
    at all.
"""
import datetime

from . import emailkit, keywords, ledger, metrics, searchconsole


def _blocked():
    """Everything that could not run, with the real error text.

    The two billing failures are both HTTP 400 and need opposite responses —
    "credit balance is too low" means top up, "reached your specified API usage
    limits" is a self-imposed cap that topping up will not clear. The stored
    message is printed verbatim rather than summarised for exactly that reason.
    """
    out = []
    for key, label in (("scout_last", "scout"), ("writer_last", "guide writer")):
        rec = ledger.get_state(key) or {}
        if rec.get("ok") is False:
            out.append((f"{label} ({rec.get('date', '?')}):", rec.get("error", "unknown")))
    sc = searchconsole.status()
    if not sc.get("connected"):
        out.append(("search console:", sc.get("why", "not connected")))
    inl = ledger.get_state("indexnow_last") or {}
    if inl and inl.get("http") and int(inl["http"]) >= 400:
        out.append(("indexnow:", f"HTTP {inl['http']} on {inl.get('date')}"))
    return out


def _traffic():
    rows = []
    for metric, label in (("visitors", "visitors"), ("pageviews", "page views"),
                          ("organic_visitors", "from search")):
        s = ledger.series("__site__", metric)
        if not s:
            rows.append((label + ":", "not measured yet"))
            continue
        date, value = s[-1]
        week = [v for _, v in s[-7:]]
        avg = round(sum(week) / len(week), 1)
        rows.append((f"{label}:", f"{value} on {date} (7-day average {avg})"))
    filt = (ledger.read_results("__site__", "visitors") or [{}])[-1].get("meta", {}).get("filtered")
    if filt:
        dropped = sum(v for k, v in filt.items() if k not in ("lines", "asset"))
        rows.append(("filtered out:",
                     f"{dropped} requests — {filt.get('bot_ua', 0)} bot agents, "
                     f"{filt.get('probe', 0)} scans, {filt.get('datacenter', 0)} datacenter, "
                     f"{filt.get('owner', 0)} owner"))
    return rows


def _funnel():
    rows = []
    pairs = [("coverage_checks_total", "addresses checked"),
             ("in_area_checks_total", "in the service area"),
             ("emails_left_total", "left an email"),
             ("orders_total", "orders"),
             ("orders_paid_total", "orders paid")]
    any_seen = False
    for metric, label in pairs:
        s = ledger.series("__site__", metric)
        if not s:
            continue
        any_seen = True
        total = s[-1][1]
        d = metrics.delta(metric, days=1)
        change = f" (+{d} since the previous reading)" if d else ""
        rows.append((f"{label}:", f"{total} total{change}"))
    if not any_seen:
        rows.append(("dispatcher:", "not reachable — funnel not read this run"))
    return rows


def _search():
    kw = keywords.summary()
    rows = [
        ("queries tracked:", str(kw["total"])),
        ("with a page targeting them:",
         f"{kw['covered']} ({kw['coverage_pct']}%) — coverage, NOT rank"),
    ]
    if kw["ranked_known"]:
        rows.append(("ranking somewhere in Google:",
                     f"{kw['ranked_known']} of {kw['total']}"))
        rows.append(("in the top 10:", f"{kw['top10']} (top 3: {kw['top3']})"))
    else:
        rows.append(("rank:", "unknown — Search Console is not connected, "
                              "so nothing here is a position"))
    if kw["gaps"]:
        rows.append(("unanswered questions next:", ", ".join(kw["gaps"][:6])))
    return rows


def _build(run_log):
    rows = []
    for r in run_log or []:
        mark = "ok  " if r.get("ok") else "FAIL"
        rows.append((f"[{mark}] {r.get('slug')}:", r.get("detail", "")))
    if not rows:
        rows.append("no techniques ran")
    return rows


def _waiting():
    """Candidates, with their first step. A candidate with no step is a wish."""
    rows = []
    for t in ledger.load_techniques():
        if t.get("status") != "candidate":
            continue
        step = ""
        for line in (t.get("notes") or "").splitlines():
            if line.strip().startswith("FIRST STEP:"):
                step = line.strip()[len("FIRST STEP:"):].strip()
                break
        rows.append((f"{t['id']} {t['name']}:", step or "(no first step written — "
                                                        "ask the review agent for one)"))
    return rows


def _spend():
    spend = ledger.get_state("api_spend", {}) or {}
    if not spend:
        return [("today:", "$0.00 — no model was called")]
    today = ledger.today()
    days = sorted(spend)
    t = sum((spend.get(today) or {}).values())
    week = sum(sum(v.values()) for d, v in spend.items() if d >= days[-7:][0])
    rows = [("today:", f"${t:.4f}"),
            (f"last {min(7, len(days))} days:", f"${week:.4f}"),
            ("daily average:", f"${week / max(1, min(7, len(days))):.4f}")]
    by_job = (spend.get(today) or {})
    if by_job:
        rows.append(("by job today:", ", ".join(f"{k} ${v:.4f}" for k, v in by_job.items())))
    return rows


def build(run_log=None, review_result=None, scout_result=None):
    blocked = _blocked()
    sections = []
    if blocked:
        sections.append(("blocked — read this first", blocked, "bad"))
    sections.append(("traffic", _traffic(), None))
    sections.append(("funnel (totals since launch)", _funnel(), None))
    sections.append(("search", _search(), None))
    sections.append(("what ran this morning", _build(run_log), None))
    if review_result and review_result.get("actions"):
        sections.append(("review decisions", review_result["actions"], "warn"))
    if scout_result and scout_result.get("ok"):
        rows = []
        if scout_result.get("techniques"):
            rows.append(("proposed:", ", ".join(scout_result["techniques"])))
        if scout_result.get("keywords"):
            rows.append((f"{len(scout_result['keywords'])} new queries:",
                         ", ".join(scout_result["keywords"][:8])))
        if scout_result.get("note"):
            rows.append(scout_result["note"])
        sections.append(("scout", rows or ["nothing new worth proposing"], None))
    sections.append(("waiting on you", _waiting(), "warn"))
    sections.append(("api spend (estimated)", _spend(), None))

    active = len(ledger.active())
    intro = (f"{active} techniques active. "
             f"Measured {ledger.get_state('last_measure', {}).get('date', 'nothing')}.")
    title = f"Crease growth — {datetime.date.today().strftime('%a %d %b')}"
    html, text = emailkit.render(
        title, intro, sections,
        footer="growth_daily.py on 104.236.120.144 · log /var/log/crease-growth.log")
    subject = title + (" — BLOCKED" if blocked else "")
    return subject, html, text


def send(to, run_log=None, review_result=None, scout_result=None):
    subject, html, text = build(run_log, review_result, scout_result)
    if not emailkit.smtp_configured():
        return {"sent": False, "why": "SMTP not configured in growth.env"}
    emailkit.send(to, subject, html, text)
    return {"sent": True, "to": to, "subject": subject}
