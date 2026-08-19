#!/usr/bin/env python3
"""One call a day that looks outside this repository.

Everything else in the engine works the queue it already has. This asks what
should be in the queue: it searches the live web for what is working now for
small local service businesses, and files what it finds as **candidates** and
as new tracked queries.

It never activates anything. A technique it proposes sits in the ledger with a
hypothesis and a first step until a person or the review agent turns it on. The
scout is the half of the loop that can be wrong in an expensive direction —
"post daily on four social networks" is a plausible sentence and a month of
somebody's life — so its output is a proposal, and proposals are cheap.

Bounded to three new techniques and fifteen new queries a day. A firehose of
ideas is indistinguishable from no ideas, because nobody reads it.
"""
import json

from . import facts, keywords, ledger, llm

MAX_NEW_TECHNIQUES = 3
MAX_NEW_KEYWORDS = 15

# Web search is where the cost is: results arrive as input tokens, so max_uses
# is the real budget dial and max_tokens barely moves it. Five is enough to
# read a handful of current sources and not enough to browse the internet.
TOOLS = [{"type": "web_search_20250305", "name": "web_search", "max_uses": 5}]

SYSTEM = f"""You are the growth scout for {facts.BRAND} ({facts.SITE}), a laundry pickup \
and delivery service operating within about {facts.RADIUS_MILES} miles of \
{facts.BASE_NEIGHBORHOOD}, Brooklyn.

Your job each day: find growth and local-SEO techniques that are working RIGHT NOW for \
small local service businesses, and propose the ones that fit THIS business. Search the \
web — do not answer from memory, and prefer sources from the last twelve months.

What this business is, so you do not propose something impossible:
{facts.block()}

Hard constraints on what you may propose:
  - It must be executable by a Python cron on a small server, OR be a single concrete
    step a person can take in under an hour. Nothing that needs a team.
  - It must not spend money, post as the business on any network, email anyone, or
    create an account, WITHOUT being marked as needing a person. Anything in that
    category is still worth proposing — mark it `needs_human: true` and write the first
    step precisely.
  - No technique that fabricates reviews, testimonials, locations, or content at scale.
    Thin pages generated per neighborhood are specifically what Google's scaled-content
    policy targets and this site will not do it.
  - Do not propose something the ledger already holds, in any wording.

Reply with one JSON object and nothing else:

{{
  "techniques": [
    {{"slug": "short_snake_case",
      "name": "one line",
      "hypothesis": "why this drives traffic or bookings for THIS business, specifically",
      "kind": "content|indexing|distribution|lifecycle|conversion",
      "evidence": "a URL you actually read, and what it said",
      "needs_human": true|false,
      "first_step": "the single next action, concrete enough to do today"}}
  ],
  "keywords": [
    {{"query": "what somebody types", "intent": "buy|local|explain",
      "why": "why somebody typing this would book"}}
  ],
  "note": "one sentence: the most important thing you learned today"
}}

At most {MAX_NEW_TECHNIQUES} techniques and {MAX_NEW_KEYWORDS} keywords. Fewer, better \
ones is the right answer most days. An empty techniques list is a legitimate answer."""


def _context():
    """What the scout must know so it does not re-propose what exists."""
    techs = ledger.load_techniques()
    lines = ["Techniques already in the ledger (do not re-propose any of these):"]
    for t in techs:
        v = t.get("verdict") or {}
        lines.append(f"  [{t['status']}] {t['slug']}: {t['name']}"
                     + (f" — verdict: {v.get('why')}" if v else ""))
    kw = keywords.summary()
    lines.append("")
    lines.append(f"Tracked queries: {kw['total']}, of which {kw['covered']} have a page "
                 f"targeting them. Uncovered right now: "
                 f"{', '.join(kw['gaps'][:15]) or 'none'}.")
    sc = ledger.series("__site__", "visitors")[-14:]
    if sc:
        lines.append(f"Human visitors, last {len(sc)} days: "
                     f"{', '.join(str(v) for _, v in sc)}.")
    else:
        lines.append("No traffic has been measured yet.")
    return "\n".join(lines)


def run(dry_run=False):
    key = llm.load_key()
    if not key:
        msg = ("no Anthropic key — set ANTHROPIC_API_KEY in growth.env, "
               "growth/.anthropic_key, or keychain crease-anthropic")
        if not dry_run:
            ledger.set_state("scout_last", {"date": ledger.today(), "ok": False, "error": msg})
        return {"ok": False, "error": msg, "techniques": [], "keywords": []}

    prompt = (_context() + "\n\nPropose what should be added. Search first.")
    if dry_run:
        return {"ok": True, "dry_run": True, "prompt_chars": len(prompt),
                "techniques": [], "keywords": []}

    try:
        resp = llm.call(key, SYSTEM, prompt, max_tokens=16000, tools=TOOLS)
    except llm.ApiError as e:
        # The two billing failures are both HTTP 400 and need opposite
        # responses, so the real message is stored rather than a remembered
        # summary of it. report.py prints this at the top.
        ledger.set_state("scout_last", {"date": ledger.today(), "ok": False,
                                        "error": str(e), "etype": e.etype,
                                        "status": e.status})
        return {"ok": False, "error": str(e), "techniques": [], "keywords": []}
    llm.record_spend("scout", resp)

    try:
        doc = llm.json_of(resp)
    except ValueError as e:
        ledger.set_state("scout_last", {"date": ledger.today(), "ok": False, "error": str(e)})
        return {"ok": False, "error": str(e), "techniques": [], "keywords": []}

    added_t, added_k = [], []
    for t in (doc.get("techniques") or [])[:MAX_NEW_TECHNIQUES]:
        slug = str(t.get("slug") or "").strip().lower().replace("-", "_")
        if not slug or ledger.get(slug):
            continue
        kind = t.get("kind") if t.get("kind") in ledger.VALID_KIND else "distribution"
        note = str(t.get("first_step") or "").strip()
        rec = ledger.add(
            slug=slug,
            name=str(t.get("name") or slug)[:120],
            hypothesis=str(t.get("hypothesis") or "")[:1000],
            kind=kind,
            prefixes=[],
            metric="organic_visitors",
            source=f"scout:{ledger.today()}",
            evidence=str(t.get("evidence") or "")[:500],
            status="candidate",
            notes=(f"FIRST STEP: {note}" if note else "")
                  + ("\nNeeds a person." if t.get("needs_human") else ""))
        if rec:
            added_t.append(rec["slug"])

    for k in (doc.get("keywords") or [])[:MAX_NEW_KEYWORDS]:
        q = str(k.get("query") or "").strip().lower()
        intent = k.get("intent") if k.get("intent") in ("buy", "local", "explain") else "explain"
        if keywords.add(q, intent, target="", source=f"scout:{ledger.today()}",
                        note=str(k.get("why") or "")[:300]):
            added_k.append(q)

    result = {"ok": True, "techniques": added_t, "keywords": added_k,
              "note": str(doc.get("note") or "")[:400]}
    ledger.set_state("scout_last", {"date": ledger.today(), **result})
    return result
