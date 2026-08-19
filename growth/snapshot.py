#!/usr/bin/env python3
"""The bridge to the review agent, and the assertion that keeps it safe.

The engine runs on the droplet. The agent that judges it runs in Anthropic's
cloud with a git checkout and nothing else — it cannot reach this box, read the
database, or see the log. So the repository is the channel: this writes a state
file, growth_run.sh commits and pushes it, and the agent reads it the next
morning.

**This repository is public.** The tables underneath these numbers are a list of
where people live: customer addresses, coverage checks with street-level
detail, emails left on the site. None of it may leave. So this file is
aggregates only, and `_assert_no_pii` refuses to write the file at all if
anything shaped like an email address, a phone number, or a street address
appears anywhere in it. Refusing to publish is the correct failure: a snapshot
that is a day late costs a review cycle, and one that leaks a customer's
address cannot be taken back.

The business's own published contact details are the single allowed exception,
because they are already on the website.
"""
import json
import os
import re

from . import keywords, ledger, searchconsole

HERE = os.path.dirname(os.path.abspath(__file__))
SNAPSHOT_PATH = os.path.join(HERE, "snapshot.json")

ALLOWED = {"divinejdavis@gmail.com"}

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
PHONE = re.compile(r"(?<!\d)(?:\+?1[ .-]?)?\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}(?!\d)")
STREET = re.compile(
    r"\b\d{1,5}\s+[A-Z][A-Za-z.'-]+(?:\s+[A-Z][A-Za-z.'-]+)*\s+"
    r"(?:St|Street|Ave|Avenue|Rd|Road|Blvd|Boulevard|Pl|Place|Ct|Court|Ln|Lane|"
    r"Dr|Drive|Ter|Terrace|Way|Pkwy|Parkway)\b\.?", re.I)


def _assert_no_pii(doc):
    blob = json.dumps(doc)
    for match in EMAIL.findall(blob):
        if match.lower() not in ALLOWED:
            raise RuntimeError(f"snapshot contains an email address ({match}) — refusing to write")
    for pattern, what in ((PHONE, "phone number"), (STREET, "street address")):
        m = pattern.search(blob)
        if m:
            raise RuntimeError(f"snapshot contains something shaped like a {what} "
                               f"({m.group(0)!r}) — refusing to write")
    return True


def build():
    kw = keywords.summary()
    series = {}
    for metric in ("visitors", "pageviews", "organic_visitors", "serving_pages",
                   "search_impressions", "coverage_checks_total", "in_area_checks_total",
                   "orders_total", "orders_paid_total"):
        s = ledger.series("__site__", metric)
        if s:
            series[metric] = [{"date": d, "value": v} for d, v in s[-30:]]

    techs = []
    for t in ledger.load_techniques():
        techs.append({k: t.get(k) for k in
                      ("id", "slug", "name", "kind", "status", "hypothesis", "prefixes",
                       "metric", "source", "evidence", "added", "activated", "retired",
                       "revisit_on", "notes", "verdict")})

    doc = {
        "generated": ledger.today(),
        "site": "https://creasenyc.com",
        "techniques": techs,
        "keywords": {
            "summary": kw,
            # The queue is the roadmap: these are the questions with no page.
            # The review agent's most useful single act is reordering it.
            "queue": [k["query"] for k in keywords.guide_queue(limit=25)],
        },
        "series": series,
        "search_console": searchconsole.status(),
        "last_run": ledger.read_last_run(),
        "api_spend": ledger.get_state("api_spend", {}),
        "writer_last": ledger.get_state("writer_last"),
        "scout_last": ledger.get_state("scout_last"),
        "indexnow_last": ledger.get_state("indexnow_last"),
    }
    return doc


def write():
    doc = build()
    _assert_no_pii(doc)
    tmp = SNAPSHOT_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2, sort_keys=False)
        f.write("\n")
    os.replace(tmp, SNAPSHOT_PATH)
    return SNAPSHOT_PATH
