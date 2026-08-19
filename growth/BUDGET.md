# Budget — don't blow it

**Standing rule: never blow the API budget.** These jobs run unattended, so a
cost mistake is not noticed when it is made. It is noticed days later, when the
account is capped and everything model-backed has silently stopped.

This is the file to update when the model, the token limits, or the rates
change, and the file to read before adding a job that calls one.

## What this engine spends

Two callers, both in `growth/llm.py`, **one call each per day**:

| Job | What it does | Web search | max_tokens |
|---|---|---|---|
| `writer` | writes one guide page | no | 8,000 |
| `scout` | proposes techniques and queries | yes, `max_uses: 5` | 16,000 |

Both run on `claude-opus-5`. Rates for that model, per million tokens:
**$5 input, $25 output.**

Rough shape of a normal morning: the writer is a few cents; the scout is the
larger of the two and is dominated by **input**, because every web-search
result is injected on the input side. `max_uses` is therefore the real budget
dial and `max_tokens` barely moves it — this is the part that surprises people.

Each call prices itself from its own response `usage` block
(`llm.price()` / `llm.record_spend()`), the running total is kept in ledger
state `api_spend`, and the daily report carries an **API spend (estimated)**
section with today, the last seven days, and the average. It is an estimate —
cache reads bill at ~0.1x and writes at ~1.25x — and it exists to catch an
order-of-magnitude problem, not to reconcile an invoice.

**If that number moves by an order of magnitude, something changed. Find out
what before the cap does it for you.**

## The two billing failures look identical and are not

Both are HTTP 400. Read the message before reporting anything:

| Message contains | Meaning | Fix |
|---|---|---|
| `credit balance is too low` | The account is empty | Top up |
| `reached your specified API usage limits` | A self-imposed spend cap in the Anthropic console | Raise the cap, or wait for the reset date |

Reporting "no credit" when it is a usage cap sends someone to top up an account
that already has money. `report.py` prints the stored error text verbatim rather
than a remembered summary of it, for exactly this reason, and prints it in the
**first** section — a cost failure does not look like an outage, it looks like a
slightly less productive morning, because the mechanical techniques keep
succeeding while only the model-backed one stops.

This account is shared with the NEMO and Find A Crib engines. A cap hit by any
of them stops all three.

## The Opus 5 tension, stated plainly

Two standing instructions pull against each other:

- Daily automation runs on **Opus 5** — these calls publish to a live site
  unreviewed, and the cost of a bad autonomous page exceeds the cost of tokens.
- **Don't blow the budget.**

Both hold, and the way they coexist is that **Opus 5 is for judgment, not
volume**:

| Job | Model | Why |
|---|---|---|
| writer — one guide a day | Opus 5 | It publishes without review. Judgment. |
| scout — proposes the roadmap | Opus 5 | One call a day; its output steers the work. |
| anything per-page, per-query, per-neighborhood | **not Opus, and probably not a model at all** | Volume work. |

The rule of thumb: **a job that runs once a day can afford Opus. A job whose
call count scales with the size of the dataset cannot** — and should usually be
plain code, since most of what this engine does needs no model whatsoever.
`link_mesh`, `indexnow`, coverage checking, the log parser and the whole ledger
call nothing.

## The hard limits, and why they are limits

- **One new page per run.** Not a soft target — `t_guides` returns after the
  first success. A hundred thin pages overnight is exactly the pattern Google's
  scaled-content policy targets, and it is also how a site stops being worth
  reading.
- **No retry loop.** A rate limit is a tomorrow problem. Retrying into one at
  05:20 is how a cap gets hit before anybody is awake.
- **Three techniques and fifteen queries a day from the scout.** A firehose of
  ideas is indistinguishable from no ideas, because nobody reads it.

## Before adding a model-backed job

1. **Does it need a model at all?** Most of this engine is deterministic code.
2. **How many calls a day, at what input size?** Multiply it out at the rates
   above. If the answer scales with the dataset, redesign it.
3. **Does it search the web?** Then input tokens are the cost and `max_uses` is
   the dial. Keep it low.
4. **Record its spend** via `llm.record_spend("<job>", resp)`, or it can only
   ever be discovered by a cap.
5. **Fail loudly.** Write `ok: False` and the real error text into a `*_last`
   ledger state record, so the report can tell "ran, found nothing" from "could
   not run".
