#!/usr/bin/env python3
"""Crease growth engine — the daily driver.

One cron runs this on the droplet:

  05:20 America/New_York   growth_run.sh daily --email …

The loop is: **measure → review → build → scout → report**.

  measure  yesterday's traffic from the nginx log, and the funnel from the
           dispatcher, into the ledger
  review   re-judge every active technique against its own measured series;
           retire what is not earning and flag what is served but not clicked
  build    run each ACTIVE technique — write today's guide, keep the link mesh
           honest, submit what changed to IndexNow
  scout    one call with live web search; files new ideas as CANDIDATES and
           never activates anything
  report   email the blunt version, blocked things first

Every command takes --dry-run. It is a rehearsal, not a read-only mode, and
the distinction is worth being exact about: a dry run **publishes no page,
sends no email, submits nothing to IndexNow and makes no API call**. It still
seeds the ledger and records what it measured, because that is local
bookkeeping about a day that happened either way — and a rehearsal that
refused to measure would not be rehearsing much.

    python3 growth_daily.py daily --dry-run
    python3 growth_daily.py measure
    python3 growth_daily.py status
"""
import argparse
import json
import os
import sys
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from growth import (facts, indexstatus, keywords, ledger, metrics,   # noqa: E402
                    report, review,
                    scout, searchconsole, seed, snapshot, techniques)

# Where the running site reads guides from. On the droplet the customer app's
# WorkingDirectory is /opt/crease/apps/web, so its content dir is this. In a
# checkout it is apps/web/content, which is why a laptop dry run works.
DEFAULT_CONTENT = os.environ.get(
    "CREASE_CONTENT_DIR",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "apps", "web", "content"))
# The site is asked for its own pages over loopback rather than over the
# internet: coverage must be measurable when DNS, TLS or the CDN are having a
# bad day, and none of those are what it is trying to measure.
DEFAULT_ORIGIN = os.environ.get("CREASE_WEB_ORIGIN", "http://127.0.0.1:3020")


def log(msg):
    print(msg, flush=True)


# ------------------------------------------------------------------- build

def cmd_build(args):
    seed.run()
    keywords.seed()
    ctx = techniques.Context(args.content_dir, dry_run=args.dry_run, log=log)

    active = {t["slug"] for t in ledger.active()}
    run_log = []
    for slug in techniques.ORDER:
        if slug not in active:
            log(f"  skip {slug} (not active in the ledger)")
            continue
        fn = techniques.REGISTRY.get(slug)
        if not fn:
            log(f"  skip {slug} (no implementation)")
            continue
        try:
            res = fn(ctx)
        except Exception as e:
            traceback.print_exc()
            res = {"ok": False, "detail": f"crashed: {e}"}
        res["slug"] = slug
        run_log.append(res)
        log(f"  [{'ok ' if res.get('ok') else 'FAIL'}] {slug}: {res.get('detail', '')}")

    if not args.dry_run:
        ledger.write_last_run("build", {
            "new_urls": len(ctx.new_urls), "changed_urls": len(ctx.changed_urls),
            "techniques": {r["slug"]: {"ok": bool(r.get("ok")), "detail": r.get("detail", "")}
                           for r in run_log}})
    log(f"  {len(ctx.new_urls)} new URLs, {len(ctx.changed_urls)} changed")
    return run_log


# ----------------------------------------------------------------- measure

def cmd_measure(args):
    try:
        data = metrics.collect_and_record(day=args.day)
    except Exception as e:
        traceback.print_exc()
        log(f"  measure FAILED: {e}")
        return None
    log(f"  {data['date']}: {data['visitors']} visitors, {data['pageviews']} views, "
        f"{data['organic_visitors']} from search")
    if data["funnel"]:
        log(f"  funnel: {data['funnel']['coverage_checks_total']} addresses checked, "
            f"{data['funnel']['orders_total']} orders (totals)")
    else:
        log("  funnel: dispatcher not reachable")

    # Coverage is a proxy for rank and is labelled as one everywhere it is
    # printed. It is still the only thing measurable without Search Console,
    # and it is what drives the guide queue.
    try:
        _, changed = keywords.check_coverage(args.origin)
        log(f"  coverage re-checked ({changed} verdicts changed)")
    except Exception as e:
        log(f"  coverage NOT re-checked: {e}")

    try:
        doc = searchconsole.collect()
        log(f"  search console: {len(doc['pages'])} serving pages, "
            f"{doc['queries_matched']} tracked queries ranked")
    except searchconsole.NotConnected as e:
        log(f"  search console: not connected ({e})")
    except Exception as e:
        log(f"  search console FAILED: {e}")

    # Impressions cannot tell "not indexed" from "indexed, nobody searched",
    # and on a site this new almost everything is zero. This asks Google
    # directly. The whole sitemap fits inside one day's quota, so there is no
    # sampling and no cohort to keep stable.
    try:
        ix = indexstatus.summary(indexstatus.run(dry_run=args.dry_run))
        log(f"  indexing: {ix['indexed']}/{ix['inspected']} indexed, "
            f"{ix['unknown_to_google']} never seen by Google")
    except searchconsole.NotConnected as e:
        log(f"  indexing: not connected ({e})")
    except Exception as e:
        log(f"  indexing FAILED: {e}")

    if not args.dry_run:
        ledger.write_last_run("measure", {"date": data["date"], "visitors": data["visitors"]})
    return data


# ------------------------------------------------------------------ review

def cmd_review(args):
    result = review.run(apply=not args.dry_run)
    for a in result["actions"]:
        log(f"  {a}")
    if not result["actions"]:
        log("  no changes — everything active is either earning or still in its grace period")
    return result


# ------------------------------------------------------------------- scout

def cmd_scout(args):
    result = scout.run(dry_run=args.dry_run)
    if not result.get("ok"):
        log(f"  scout blocked: {result.get('error')}")
        return result
    log(f"  proposed {len(result.get('techniques', []))} techniques, "
        f"{len(result.get('keywords', []))} queries")
    if result.get("note"):
        log(f"  note: {result['note']}")
    return result


# ------------------------------------------------------------------ report

def cmd_report(args, run_log=None, review_result=None, scout_result=None):
    subject, html, text = report.build(run_log, review_result, scout_result)
    if args.email and not args.dry_run:
        try:
            out = report.send(args.email, run_log, review_result, scout_result)
            log(f"  emailed {args.email}" if out.get("sent") else f"  not emailed: {out.get('why')}")
        except Exception as e:
            log(f"  email FAILED: {e}")
            print(text)
    else:
        print(text)
    return subject


# ------------------------------------------------------------------- daily

def cmd_daily(args):
    log("== measure");  data = cmd_measure(args)
    log("== review");   rev = cmd_review(args)
    log("== build");    run_log = cmd_build(args)
    log("== scout");    sct = cmd_scout(args)
    log("== snapshot")
    if not args.dry_run:
        try:
            log(f"  wrote {snapshot.write()}")
        except Exception as e:
            # A refused snapshot is a PII assertion doing its job. Loud, and
            # not fatal — the rest of the morning's work still happened.
            log(f"  snapshot NOT written: {e}")
    log("== report");   cmd_report(args, run_log, rev, sct)
    return 0


# ------------------------------------------------------------------ status

def cmd_status(args):
    techs = ledger.load_techniques()
    by_status = {}
    for t in techs:
        by_status.setdefault(t["status"], []).append(t)
    for status in ("active", "candidate", "retired"):
        rows = by_status.get(status, [])
        print(f"\n{status.upper()} ({len(rows)})")
        for t in rows:
            v = t.get("verdict") or {}
            print(f"  {t['id']} {t['slug']:<24} {t['name']}")
            if v:
                print(f"       verdict: {'works' if v.get('works') else 'no'} — {v.get('why')}")
    kw = keywords.summary()
    print(f"\nKEYWORDS  {kw['total']} tracked, {kw['covered']} with a page "
          f"({kw['coverage_pct']}% coverage — NOT rank)")
    if kw["ranked_known"]:
        print(f"          {kw['ranked_known']} ranked, {kw['top10']} in the top 10")
    else:
        print("          rank unknown — Search Console not connected")
    print("\nSEARCH CONSOLE  " + json.dumps(searchconsole.status()))
    return 0


def cmd_facts(args):
    """Print what the writer is allowed to say. Drift here is a published lie."""
    print(facts.block())
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", choices=["daily", "measure", "review", "build", "scout",
                                       "report", "status", "snapshot", "facts"])
    p.add_argument("--dry-run", action="store_true",
                   help="rehearse: publish nothing, send nothing, call no API")
    p.add_argument("--email", help="send the report here")
    p.add_argument("--day", help="measure a specific YYYY-MM-DD instead of yesterday")
    p.add_argument("--content-dir", default=DEFAULT_CONTENT,
                   help=f"where the site reads guides from (default {DEFAULT_CONTENT})")
    p.add_argument("--origin", default=DEFAULT_ORIGIN,
                   help=f"the running site, for coverage checks (default {DEFAULT_ORIGIN})")
    args = p.parse_args()
    args.content_dir = args.content_dir

    if args.command == "daily":
        return cmd_daily(args)
    if args.command == "measure":
        cmd_measure(args); return 0
    if args.command == "review":
        cmd_review(args); return 0
    if args.command == "build":
        cmd_build(args); return 0
    if args.command == "scout":
        cmd_scout(args); return 0
    if args.command == "report":
        cmd_report(args); return 0
    if args.command == "snapshot":
        print(snapshot.write()); return 0
    if args.command == "facts":
        return cmd_facts(args)
    return cmd_status(args)


if __name__ == "__main__":
    sys.exit(main())
