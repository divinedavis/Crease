#!/usr/bin/env python3
"""The starting ledger.

Idempotent: `add()` returns the existing record if the slug is known, so this
runs every morning and only ever fills in what is missing. It never reactivates
something review.py retired — a retired technique stays retired until a person
or the review agent says otherwise, which is the whole point of the ledger.

Two kinds of record are seeded, and the difference matters more than it looks:

  active     the engine runs it unattended, today.
  candidate  the engine will NOT run it. It needs money, an account, a public
             identity, or a decision that is not the engine's to make. Each one
             carries its first concrete step, and the daily report lists them
             under WAITING ON YOU. A candidate with no first step is a wish.
"""
from . import ledger


def run():
    ledger.add(
        slug="guides",
        name="Answer one unanswered question a day",
        hypothesis=(
            "The site ranks for 'laundry pickup <neighborhood>' because it has a page "
            "per neighborhood, and ranks for nothing else because it has no other pages. "
            "The questions people type before they are ready to book — what wash and fold "
            "costs, what a load weighs, whether it is worth it — have no page here at all. "
            "One good page per question should earn impressions on queries the area pages "
            "cannot compete for, and give the area pages something to link to."),
        kind="content",
        prefixes=["/guides/"],
        metric="owned_visitors",
        source="seed",
        evidence="Uncovered `explain` queries in growth/keywords.json are the queue.",
        status="active",
        notes="One page per run, hard limit. See BUDGET.md and techniques.t_guides.")

    ledger.add(
        slug="link_mesh",
        name="Keep guides and neighborhood pages linked to each other",
        hypothesis=(
            "A guide nothing links to except the hub is an orphan, and orphans are the "
            "pages search engines are slowest to trust. Every guide naming the "
            "neighborhoods it is relevant to gives the thirty area pages a reason to "
            "link out and the guides a reason to be found."),
        kind="content",
        prefixes=["/guides/", "/laundry-pickup/"],
        metric="owned_visitors",
        source="seed",
        evidence="Costs nothing and calls nothing; runs on every published guide.",
        status="active")

    ledger.add(
        slug="indexnow",
        name="Submit new and changed URLs to IndexNow",
        hypothesis=(
            "Bing, Yandex and Seznam crawl on submission. On a site this small the gap "
            "between 'indexed this week' and 'indexed next month' is most of the value a "
            "new page has in its first month."),
        kind="indexing",
        prefixes=[],
        metric="organic_visitors",
        source="seed",
        evidence="Google does not participate; it re-crawls from sitemap <lastmod>.",
        status="active",
        notes="Only URLs a run created or changed — resubmitting the site daily gets a "
              "host ignored.")

    # ---------------------------------------------------------- candidates

    ledger.add(
        slug="search_console",
        name="Verify creasenyc.com in Google Search Console",
        hypothesis=(
            "Everything this engine measures today is whether we TRIED: a page exists, a "
            "link was added, a URL was submitted. Position is the only measurement that "
            "says whether any of it worked, and Google is the only source of it. Until "
            "this is connected, review.py cannot retire anything on evidence and the "
            "loop is an automation rather than a loop."),
        kind="indexing",
        prefixes=[],
        metric="organic_visitors",
        source="seed",
        evidence="growth/searchconsole.py is written and waiting; it degrades to "
                 "measured:False until a key and a verified property exist.",
        status="candidate",
        notes="FIRST STEP: add creasenyc.com as a URL-prefix property in Search Console "
              "and verify it (DNS or the HTML file — the site serves /robots.txt and a "
              "sitemap already). Then create a service account, add its client_email as "
              "a FULL user on the property (Restricted cannot read Search Analytics), "
              "put the JSON on the droplet and set SC_KEY_FILE in growth.env. Do not "
              "reuse the findacrib service account: one key held by two engines means "
              "revoking either revokes both.")

    ledger.add(
        slug="google_business_profile",
        name="Google Business Profile for the Clinton Hill operation",
        hypothesis=(
            "'laundry pickup near me' and the map pack are where local intent actually "
            "lands, and neither is reachable from an unverified web page. A profile is "
            "the single largest local-search lever available to a service this size."),
        kind="distribution",
        prefixes=[],
        metric="organic_visitors",
        source="seed",
        evidence="Local pack results are drawn from Business Profile, not the index.",
        status="candidate",
        notes="FIRST STEP: decide whether Crease has a public address to list. Google "
              "requires either a storefront customers can visit or a declared service "
              "area with a real business address, and verification is by postcard or "
              "video. This is a business decision about what address to publish, not "
              "something the engine can take.")

    ledger.add(
        slug="dry_cleaning_pages",
        name="Pages for dry cleaning, once dry cleaning exists",
        hypothesis=(
            "'dry cleaning pickup brooklyn' is already a tracked query and the site "
            "cannot answer it, because the service does not exist yet. Writing the page "
            "first would rank for a promise we cannot keep."),
        kind="content",
        prefixes=[],
        metric="organic_visitors",
        source="seed",
        evidence="facts.py: dry cleaning is not offered. keywords.json tracks the query.",
        status="candidate",
        notes="FIRST STEP: sign a partner cleaner who does dry cleaning and turn it on "
              "in the app. Until then this stays a candidate on purpose — a page for a "
              "service we do not sell is the one kind of content that costs more than "
              "it earns.")

    return ledger.load_techniques()
