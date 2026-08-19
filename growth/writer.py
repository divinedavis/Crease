#!/usr/bin/env python3
"""The one call a day that writes a page.

Takes the oldest question nobody on this site answers yet — an uncovered
`explain` query from keywords.py — and writes the guide that answers it, as
JSON the site renders at request time (apps/web/lib/guides.ts).

Three constraints shape everything here:

**One page per run, and only when there is a real question to answer.** A
hundred thin pages overnight is precisely the pattern Google's scaled-content
policy targets, and it is also how a site stops being worth reading. The queue
is drained one item a day or not at all.

**The model gets the facts and may not invent more.** facts.py is the whole
permitted world; the validator below re-checks the output for the numbers a
model most reliably gets wrong. A wrong price on a public page is not a typo,
it is what somebody books on.

**Nothing is trusted on the way out.** The renderer validates again on read,
because the two halves ship separately — but a bad page should never reach
disk in the first place, so the strict check is here.
"""
import json
import os
import re

from . import facts, keywords, ledger, llm

SYSTEM = f"""You write short, useful guides for {facts.BRAND} ({facts.SITE}), a laundry \
pickup and delivery service in {facts.CITY}, New York.

You are writing for one person: somebody in Brooklyn who just typed a question into a \
search engine and wants it answered. Answer it in the first two sentences. Everything \
after that is detail for the reader who wants it.

House style:
  - Plain, specific, unexcited. No marketing voice, no "in today's fast-paced world",
    no rhetorical questions as headings.
  - Concrete over general. "A full kitchen bin liner of clothes is about 15 pounds"
    beats "laundry can add up quickly".
  - Say what is true even when it does not sell. If the honest answer to "is this worth
    it" is "not if you have a machine in your unit", write that.
  - Second person. Short paragraphs. No bulleted lists — the page renders paragraphs.
  - Never mention that this page was generated, automated, or written by a model.

{facts.block()}

If answering the question well requires a fact you were not given, write around it \
rather than inventing it, or say that it depends and on what.

Reply with a single JSON object and nothing else:

{{
  "slug": "lowercase-hyphenated-url-segment, 3-8 words, no year, no brand name",
  "title": "the page's h1 — a direct answer or a plain description, under 70 characters",
  "description": "one sentence for the search result, 120-155 characters",
  "intro": "2-3 sentences that answer the question outright, before any detail",
  "sections": [
    {{"heading": "a plain noun phrase, not a question", "body": ["paragraph", "paragraph"]}}
  ],
  "faq": [{{"q": "a question someone actually types", "a": "2-4 sentences"}}],
  "areas": ["neighborhood-slugs-this-is-most-relevant-to"]
}}

4 to 6 sections, 1 to 3 paragraphs each. 3 to 5 FAQ entries. 2 to 6 area slugs, \
chosen from this list only: {{AREAS}}"""

# Mirrors the renderer's limits (apps/web/lib/guides.ts). Kept a little tighter
# here: the renderer truncates silently to stay up, this refuses so the problem
# is visible in the morning report instead of on the page.
MAX = {"title": 90, "description": 200, "intro": 900, "heading": 120,
       "para": 1400, "q": 160, "a": 800}
SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+){1,12}$")

# The prices the model must not have changed.
#
# An earlier version rejected any dollar figure that was not one of ours, and
# it rejected the right kind of page for the wrong reason: "most bags land
# between $24 and $36" is arithmetic a reader wants, not a claimed rate. What
# must never be wrong is a price attached to a THING WE SELL — a rate per
# pound, the minimum, a courier fee — so each of those is checked in the
# context that makes it a claim, and free-standing arithmetic is left alone.
# \d{1,3}(?:,\d{3})* rather than [\d,]*: the loose form swallowed the comma in
# "a $20, which is about" and reported the minimum as "$20,".
PRICE_RE = r"\$\s?\d{1,3}(?:,\d{3})*(?:\.\d{2})?"
CLAIMS = [
    (re.compile(rf"({PRICE_RE})\s*(?:a|per|/)\s*(?:pound|lb\b)", re.I),
     {facts.PRICE_PER_POUND}, "the price per pound"),
    (re.compile(rf"(?:minimum(?:\s+(?:order|charge|is|of))?\s*(?:is|of)?\s*)({PRICE_RE})"
                rf"|({PRICE_RE})\s*minimum", re.I),
     {facts.MINIMUM}, "the minimum"),
    (re.compile(rf"(?:courier|delivery|round[- ]trip|one[- ]leg|pickup)\s*"
                rf"(?:fee\s*)?(?:is\s*|of\s*|:\s*)?({PRICE_RE})"
                rf"|({PRICE_RE})\s*(?:for a |per )?(?:round[- ]trip|one[- ]leg|courier fee)", re.I),
     {facts.COURIER_ROUND_TRIP, facts.COURIER_ONE_LEG}, "the courier fee"),
]


class Rejected(Exception):
    """The draft was not publishable. Carries why, for the report."""


def area_slugs():
    return [slug for _, slug in keywords.CORE_AREAS]


def _s(v, limit, what):
    if not isinstance(v, str):
        raise Rejected(f"{what} is not a string")
    v = " ".join(v.split())
    if not v:
        raise Rejected(f"{what} is empty")
    if len(v) > limit:
        raise Rejected(f"{what} is {len(v)} chars, over the {limit} limit")
    return v


def validate(doc, query):
    """Turn a model's reply into a publishable guide, or refuse it.

    Refusing is cheap: the query stays in the queue and tomorrow's run tries
    again. Publishing something wrong is not.
    """
    if not isinstance(doc, dict):
        raise Rejected("reply was not an object")

    slug = _s(doc.get("slug"), 80, "slug").lower()
    if not SLUG_RE.match(slug):
        raise Rejected(f"slug {slug!r} is not a plain hyphenated segment")

    out = {
        "slug": slug,
        "title": _s(doc.get("title"), MAX["title"], "title"),
        "description": _s(doc.get("description"), MAX["description"], "description"),
        "intro": _s(doc.get("intro"), MAX["intro"], "intro"),
        "sections": [],
        "faq": [],
        "areas": [],
        "query": query,
    }

    sections = doc.get("sections")
    if not isinstance(sections, list) or not 3 <= len(sections) <= 8:
        raise Rejected(f"expected 3-8 sections, got {len(sections) if isinstance(sections, list) else 'none'}")
    for i, s in enumerate(sections):
        if not isinstance(s, dict):
            raise Rejected(f"section {i} is not an object")
        body = s.get("body")
        if not isinstance(body, list) or not body:
            raise Rejected(f"section {i} has no body paragraphs")
        out["sections"].append({
            "heading": _s(s.get("heading"), MAX["heading"], f"section {i} heading"),
            "body": [_s(p, MAX["para"], f"section {i} paragraph") for p in body[:4]],
        })

    faq = doc.get("faq")
    if not isinstance(faq, list) or not 2 <= len(faq) <= 8:
        raise Rejected("expected 2-8 FAQ entries")
    for i, f in enumerate(faq):
        if not isinstance(f, dict):
            raise Rejected(f"faq {i} is not an object")
        out["faq"].append({"q": _s(f.get("q"), MAX["q"], f"faq {i} question"),
                           "a": _s(f.get("a"), MAX["a"], f"faq {i} answer")})

    known = set(area_slugs())
    areas = [a for a in (doc.get("areas") or []) if isinstance(a, str) and a in known]
    if not areas:
        # Not a rejection: the mesh matters, the model's choice of it does not.
        # Fall back to the neighborhoods closest to the shop.
        areas = area_slugs()[:6]
    out["areas"] = areas[:8]

    # The prices, last, over everything the page will actually say.
    text = " ".join([out["title"], out["description"], out["intro"]]
                    + [s["heading"] for s in out["sections"]]
                    + [p for s in out["sections"] for p in s["body"]]
                    + [f["q"] for f in out["faq"]] + [f["a"] for f in out["faq"]])
    for pattern, allowed, what in CLAIMS:
        for match in pattern.finditer(text):
            found = next((g for g in match.groups() if g), None)
            if found and found.replace(" ", "") not in allowed:
                raise Rejected(f"draft states {what} as {found!r}, which is not what we charge")
    for banned in ("as an ai", "language model", "i cannot", "generated by"):
        if banned in text.lower():
            raise Rejected(f"draft talks about itself ({banned!r})")
    return out


def draft(query, timeout=600):
    """One API call. Returns (guide, response) or raises."""
    key = llm.load_key()
    if not key:
        raise Rejected("no Anthropic key (set ANTHROPIC_API_KEY, growth/.anthropic_key, "
                       "or keychain crease-anthropic)")
    system = SYSTEM.replace("{AREAS}", ", ".join(area_slugs()))
    prompt = (f"Write the guide that answers this search: \"{query}\"\n\n"
              f"Answer that question specifically. Do not write a general page about "
              f"laundry services that happens to mention it.")
    resp = llm.call(key, system, prompt, max_tokens=8000, timeout=timeout)
    llm.record_spend("writer", resp)
    doc = llm.json_of(resp)
    return validate(doc, query), resp


def write_guide(content_dir, guide, dry_run=False):
    """Persist one guide. Returns (path, url, created).

    Never overwrites a different guide's file, and writes atomically: a
    half-written JSON file is a 500 on a live page, and the renderer would be
    right to refuse it.
    """
    path = os.path.join(content_dir, "guides", f"{guide['slug']}.json")
    url = f"/guides/{guide['slug']}"
    existing = None
    if os.path.exists(path):
        try:
            with open(path) as f:
                existing = json.load(f)
        except Exception:
            existing = None
    doc = dict(guide)
    doc["published"] = (existing or {}).get("published") or ledger.today()
    doc["updated"] = ledger.today()
    if existing and _same_content(existing, doc):
        return path, url, False
    if dry_run:
        return path, url, existing is None
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
    # The site runs as its own user and only ever reads these.
    try:
        os.chmod(path, 0o644)
    except OSError:
        pass
    return path, url, existing is None


def _same_content(a, b):
    keys = ("title", "description", "intro", "sections", "faq", "areas")
    return all(a.get(k) == b.get(k) for k in keys)


def published(content_dir):
    """Slugs already on disk. The queue skips what exists."""
    d = os.path.join(content_dir, "guides")
    try:
        return sorted(n[:-5] for n in os.listdir(d) if n.endswith(".json"))
    except OSError:
        return []
