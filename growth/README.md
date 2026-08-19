# Growth engine

A daily loop with one goal: **somebody in Brooklyn who needs laundry collected
finds this site, and books.**

It is the third of these. NEMO and Find A Crib run the same shape on the same
droplet, and the parts that are the same are the same on purpose — the ledger,
the review, the scout, the report. What is different here is the site: Crease's
pages are rendered by Next at request time, not files in a docroot, and that
single fact determines the whole publishing design below.

## The loop

    measure → review → build → scout → report

| Step | What it does |
|---|---|
| `measure` | Yesterday's traffic from `/var/log/nginx/creasenyc.access.log` (bots, scanners and the owner's own devices excluded), the funnel from the dispatcher over loopback, and a coverage re-check against the running site. One row per metric into the ledger. |
| `review` | Re-judges every active technique against its own measured series. Retires what is not earning after a grace period, flags what is served-but-unclicked, and records the verdict forever. |
| `build` | Runs each **active** technique — writes today's guide, repairs the link mesh, submits what changed to IndexNow. |
| `scout` | One call with live web search. Files new ideas as **candidates** and new queries as tracked. It never activates anything. |
| `report` | Emails the blunt version: blocked things first, then what moved, what ran, what needs a person, what it cost. |

Then `snapshot.py` writes the PII-free state file and `growth_run.sh` commits
and pushes it, because that file is the only thing the cloud review agent can
see.

## Publishing without a rebuild — the constraint that shapes everything

This site is a Next app built on a laptop and rsynced. The droplet has ~800MB
free and shares it with five other production sites; running `next build` there
at 5am to publish a page would risk OOM-killing all of them.

So a guide is **data, not code**. The engine writes
`/opt/crease/apps/web/content/guides/<slug>.json` and the route at
`apps/web/app/guides/[slug]/page.tsx` reads it at request time. Publishing is a
file write. Nothing is rebuilt, nothing is restarted.

Two consequences that are easy to forget and expensive to rediscover:

* **`deploy/deploy.sh` excludes `apps/web/content/`.** Its `rsync --delete`
  would otherwise erase every page the engine has ever published, and they
  cannot be rebuilt from this repo.
* **Nothing trusts the file.** `writer.py` validates what the model wrote
  before it reaches disk, and `lib/guides.ts` validates again on read, because
  the two halves ship independently.

The hub, the guide pages, the neighborhood pages and the sitemap all revalidate
every 60 seconds, so a page written at 05:20 is linked and listed before anyone
is awake.

## The ledger decides what runs, not the code

`techniques.json` is the source of truth. A technique is `candidate`, `active`
or `retired`, and only `active` ones run — so switching something off is a
one-line edit with no deploy, which is what lets `review.py` prune on its own
and lets the review agent steer by committing.

Verdicts persist after retirement, so a dead idea cannot be re-proposed as new,
and the accumulated history *is* the year-end "what actually worked" list:

    python3 growth_daily.py status

## What it will and will not do on its own

Writes and publishes guide pages, repairs internal links, and submits URLs to
IndexNow — to the live site, unattended.

It will **not** spend money, email customers, post as the business, create an
account, or turn on its own ideas. Anything in that category is seeded or filed
as a `candidate` with the first step written down, and appears in the report's
**WAITING ON YOU** block.

Guardrails in `techniques.py`: never delete a file, always write atomically, and
**at most one new page per run** — a hundred thin neighborhood pages overnight
is the exact pattern Google's scaled-content policy targets.

## Coverage is not rank, and the difference is the whole roadmap

`coverage_pct` says a page exists whose title or h1 targets a query. It says
nothing about position. On a new site those are wildly different numbers, so
every line that prints coverage says so in the line.

Position can only come from Search Console, and **creasenyc.com is not verified
there yet** (technique `search_console`, status `candidate`, first step
written). Until it is:

* `searchconsole.py` returns `measured: False` everywhere,
* and `review.py` therefore **retires nothing on traffic** — a technique judged
  dead by a metric with no resolution is a technique deleted for no reason.

Connecting it is what turns this from an automation into a loop that improves.

## The uncovered queries are the work queue

`keywords.json` is the tracked universe. The uncovered `explain` entries are
literally the writer's queue: `t_guides` takes the oldest one, writes the page
that answers it, and points the query at the new URL. The scout extends the
list. Nothing is ever deleted from it — the year-end review is only worth
reading if it still shows the questions that were never cracked.

## Requirements

* **`growth.env`** on the droplet, next to `growth_run.sh`, gitignored because
  this repository is public: `ANTHROPIC_API_KEY`, `CREASE_INTERNAL_KEY` (the
  dispatcher's, for the funnel), `SMTP_HOST/PORT/USER/PASSWORD`, and
  `SC_KEY_FILE` once Search Console is connected.
* **The dedicated nginx access log** — `access_log /var/log/nginx/creasenyc.access.log site;`
  in the vhost. Without it these requests land in the shared catch-all, which
  has no `$host` field, and traffic cannot be attributed.
* **The IndexNow key file** served at `/<key>.txt` — it lives in
  `apps/web/public/` and is how the endpoint verifies we own the host.
* **Anthropic credit.** Without it `writer` and `scout` fail cleanly, the
  mechanical techniques carry on, and the report says so at the top. See
  BUDGET.md.

## What a model is trusted with here, and what it is not

The scout reads the live web, which means a page it searches can contain text
written to be read as an instruction. That is not hypothetical for a job whose
whole purpose is to read pages about SEO, so the trust boundary is drawn by
what its output can *reach*, not by asking it nicely:

* A scout proposal becomes a **`candidate` ledger record and nothing else**. It
  cannot activate itself, and only `active` techniques run. The path from
  "a web page said so" to "code executed" runs through a person or the review
  agent, deliberately.
* Its fields are normalised on the way in: the slug is lowercased and
  snake-cased, `kind` is checked against an allowlist, and every string is
  truncated. There is no `eval`, no path, and no URL it can cause to be fetched.
* The writer's only external input is a query string, and its output is prose
  that is validated before it is written: prices must be ours, the slug must be
  a plain segment, a draft that mentions being a model is refused. It reaches a
  page as escaped text, and the JSON-LD block is serialised with `<` and `>`
  escaped so a `</script>` inside a sentence cannot end the block.
* Prompts carry public facts and aggregate counts. No customer, address, order
  or email is ever in one.

The failure this design accepts: a determined injection could get a
badly-aimed *candidate* into the ledger, where it will be read by a person and
ignored. The failure it refuses: anything a model writes turning into something
that runs, spends, or publishes an unreviewed claim.

## The bridge to the review agent

The agent runs in Anthropic's cloud with a checkout and nothing else — it
cannot reach the droplet. So the repo is the channel, in both directions:

* **`snapshot.json`** — yesterday's metrics, the full ledger with hypotheses
  and verdicts, keyword coverage, the guide queue, and the last run of each
  command. **Aggregates only.** `_assert_no_pii` refuses to write the file at
  all if anything shaped like an email address, phone number or street address
  appears in it. This repository is public and the tables underneath are lists
  of where people live; refusing to publish is the correct failure.
* **`techniques.json` / `keywords.json`** — the agent commits changes here and
  `growth_run.sh` pulls them in before the next run. This is how it steers.
* **`cron_heartbeat.jsonl`** — every invocation leaves a commit, whether or not
  it succeeded. No commit for a morning therefore means the cron did not run,
  and never means "it ran but stayed quiet".

## Running it by hand

Every command takes `--dry-run`. It is a rehearsal, not read-only: it publishes
no page, sends no email, submits nothing, and calls no API — but it still
records what it measured, because that is a day that happened either way.

```bash
cd /root/Crease-growth
set -a; . ./growth.env; set +a
python3 growth_daily.py daily --dry-run     # safe full rehearsal
python3 growth_daily.py measure             # yesterday's numbers
python3 growth_daily.py build               # write today's guide
python3 growth_daily.py status              # the scoreboard
python3 growth_daily.py facts               # what the writer may claim
```

Tests: `python3 -m growth.test_traffic`, `test_writer`, `test_snapshot`.

Cron: `/etc/cron.d/crease-growth` (05:20 ET, deliberately between Find A Crib's
05:00 and NEMO's 06:00 — three Python engines and a model call on the same
minute is how a 1GB box OOM-kills a live site).
Logs: `/var/log/crease-growth.log`.
