#!/usr/bin/env python3
"""The only place this engine talks to a model, and the only place it prices it.

Two jobs call a model: writer.py writes one guide, scout.py proposes
techniques. Both go through here so there is exactly one answer to "what did
this morning cost" and one place to change the model.

The standing rule is in BUDGET.md and it is short: **two calls a day, both
bounded, both priced from the response's own usage block.** A job whose call
count scales with anything — pages, keywords, neighborhoods — does not belong
here; that is what plain code is for, and almost everything this engine does
needs no model at all.
"""
import json
import os
import subprocess
import urllib.error
import urllib.request

from . import ledger

HERE = os.path.dirname(os.path.abspath(__file__))
API_URL = "https://api.anthropic.com/v1/messages"

# Daily automation runs on Opus 5: these calls publish to a live site without
# anyone reading them first, and the cost of a bad autonomous page exceeds the
# cost of the tokens. That holds only because the call count is two.
MODEL = "claude-opus-5"

# Published per-million-token rates for MODEL, so a run can price itself.
# Update these together with MODEL — a stale rate reports a confident wrong
# number, which is worse than reporting none.
PRICE_IN_PER_MTOK, PRICE_OUT_PER_MTOK = 5.00, 25.00


class ApiError(Exception):
    """An API refusal, with its real type and message preserved.

    "credit balance is too low" and "reached your specified API usage limits"
    are both HTTP 400 and need opposite responses — top up, versus raise a
    self-imposed cap that topping up will not clear. Reporting the wrong one
    sends someone to add money to an account that already has it.
    """

    def __init__(self, status, etype, message):
        self.status, self.etype, self.message = status, etype, message
        super().__init__(f"{etype or 'http_' + str(status)}: {message}")


def load_key():
    v = os.environ.get("ANTHROPIC_API_KEY")
    if v:
        return v.strip()
    p = os.path.join(HERE, ".anthropic_key")
    if os.path.exists(p):
        return open(p).read().strip()
    try:
        return subprocess.check_output(
            ["security", "find-generic-password", "-s", "crease-anthropic", "-w"],
            stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return None


def price(usage):
    """Dollar estimate for one response's `usage` block.

    Cache reads bill at ~0.1x and writes at ~1.25x, so this is an estimate, not
    an invoice. It exists to catch a job that quietly costs fifty times what it
    should, not to reconcile billing. Web-search results arrive as input
    tokens, which is why a search-heavy call is dominated by the input side.
    """
    u = usage or {}
    tin = (u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0)
           + u.get("cache_creation_input_tokens", 0))
    tout = u.get("output_tokens", 0)
    return round(tin / 1e6 * PRICE_IN_PER_MTOK + tout / 1e6 * PRICE_OUT_PER_MTOK, 4)


def _days_ago(n):
    import datetime
    return (datetime.date.fromisoformat(ledger.today())
            - datetime.timedelta(days=n)).isoformat()


def record_spend(job, resp):
    """Add one call's estimated cost to today's running total in the ledger."""
    try:
        cost = price((resp or {}).get("usage"))
        day = ledger.today()
        spend = ledger.get_state("api_spend", {}) or {}
        today = spend.get(day) or {}
        today[job] = round((today.get(job) or 0) + cost, 4)
        spend = {d: v for d, v in spend.items() if d >= _days_ago(14)}
        spend[day] = today
        ledger.set_state("api_spend", spend)
        return cost
    except Exception:
        return 0.0        # cost bookkeeping must never break the job it measures


def call(key, system, prompt, max_tokens=8000, tools=None, timeout=600):
    """One message. Bounded output, no retry loop — a rate limit is a tomorrow
    problem, and a retry storm against one is how a cap gets hit at 5am."""
    body = {"model": MODEL, "max_tokens": max_tokens, "system": system,
            "messages": [{"role": "user", "content": prompt}]}
    if tools:
        body["tools"] = tools
    req = urllib.request.Request(
        API_URL, data=json.dumps(body).encode(),
        headers={"content-type": "application/json",
                 "x-api-key": key,
                 "anthropic-version": "2023-06-01"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            err = json.loads(raw).get("error") or {}
        except Exception:
            err = {}
        raise ApiError(e.code, err.get("type"), err.get("message") or raw[:200]) from None


def text_of(resp):
    """The text blocks of a response, joined. Tool-use blocks are skipped."""
    return "".join(b.get("text", "") for b in (resp or {}).get("content", [])
                   if b.get("type") == "text")


def json_of(resp):
    """Parse a JSON object out of a reply, tolerating a ```json fence.

    Raises ValueError with the truncation state named, because "the model wrote
    nonsense" and "the reply was cut off at max_tokens" look identical in a
    parse error and only one of them is fixed by raising a limit.
    """
    raw = text_of(resp).strip()
    if raw.startswith("```"):
        raw = raw.split("\n", 1)[1] if "\n" in raw else raw
        raw = raw.rsplit("```", 1)[0]
    start = raw.find("{")
    end = raw.rfind("}")
    if start < 0 or end <= start:
        truncated = (resp or {}).get("stop_reason") == "max_tokens"
        raise ValueError("no JSON object in the reply"
                         + (" (truncated at max_tokens)" if truncated else ""))
    try:
        return json.loads(raw[start:end + 1])
    except json.JSONDecodeError as e:
        truncated = (resp or {}).get("stop_reason") == "max_tokens"
        raise ValueError(f"unparseable JSON: {e}"
                         + (" (truncated at max_tokens)" if truncated else "")) from None
