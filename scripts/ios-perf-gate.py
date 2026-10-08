#!/usr/bin/env python3
"""Performance budget for every ship (2026-10-02). Reads the XCTMetric numbers
PerformanceTests left in an .xcresult and compares each one with its baseline in
apps/ios/perf_baseline.json.

The baseline follows the app instead of being a fixed number (owner: "these
should be dynamic as i build features and remove features"):
  * a new performance test or metric is recorded the first time it runs;
  * one whose test was removed drops out of the file;
  * each passing ship (--record) adds its median to that metric's last 5, and
    the baseline is the median of those, so a feature that honestly costs a
    little moves the bar after a few ships while a sudden 1.5x jump fails.

FAIL when a "prefers smaller" metric's median is more than TOLERANCE over its
baseline. The tolerance is wide on purpose: it is a simulator on a Mac that
other work shares, so it catches a doubling, not a 10% wobble.

A memory metric must ALSO have grown by more than MIN_GROWTH (owner,
2026-10-08). "Memory added opening booking" sits around 0.4-0.9 MB and moves by
half a megabyte between runs of the same build, so 1.5x of it failed the Uber
redesign for +0.15 MB (0.2% of the app) while the unchanged old build landed at
the line too. A real leak or a doubled image cache is megabytes, and still fails.

  python3 scripts/ios-perf-gate.py /tmp/crease-dd/Perf.xcresult [--record]
"""
import json, os, statistics, subprocess, sys

TOLERANCE = 0.5      # fail above baseline * 1.5
MIN_GROWTH = {"kB": 1024}   # ...and, for memory, more than 1 MB above it
KEEP = 5             # passing ships remembered per metric
HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "..", "apps", "ios", "perf_baseline.json")


def read_metrics(xcresult):
    out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", xcresult],
                         capture_output=True, text=True, check=True).stdout
    got = {}
    for t in json.loads(out):
        for run in t.get("testRuns", []):
            for m in run.get("metrics", []):
                if not m.get("measurements"):
                    continue
                key = f"{t['testIdentifier']} :: {m['displayName']}"
                got[key] = {"median": statistics.median(m["measurements"]), "unit": m.get("unitOfMeasurement", ""),
                            "smaller": m.get("polarity", "prefers smaller") == "prefers smaller"}
    return got


def regressed(now, ref, unit, smaller=True):
    """Whether a metric's median is a regression against its baseline."""
    if not smaller:
        return now < ref * (1 - TOLERANCE)
    return now > ref * (1 + TOLERANCE) and now - ref > MIN_GROWTH.get(unit, 0)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    record = "--record" in sys.argv
    if not args:
        print(__doc__); return 2
    got = read_metrics(args[0])
    if not got:
        print("perf gate: no performance metrics in the result bundle — did PerformanceTests run?")
        return 1
    try:
        base = json.load(open(BASELINE))
    except FileNotFoundError:
        base = {}

    failed = []
    print(f"{'metric':<92} {'now':>9} {'baseline':>9}  verdict")
    for key, m in sorted(got.items()):
        hist = base.get(key, {}).get("history", [])
        if not hist:
            verdict, ref = "new (recorded)", None
        else:
            ref = statistics.median(hist)
            over = regressed(m["median"], ref, m["unit"], m["smaller"])
            verdict = f"FAIL (>{int(TOLERANCE * 100)}% worse)" if over else "ok"
            if over:
                failed.append(key)
        print(f"{key:<92} {m['median']:>9.3f} {ref if ref is not None else float('nan'):>9.3f}  {verdict}  {m['unit']}")
    gone = sorted(set(base) - set(got))
    for key in gone:
        print(f"{key:<92} {'—':>9} {'':>9}  removed (test no longer exists)")

    if failed:
        print(f"perf gate FAILED: {len(failed)} metric(s) regressed. Profile it (Instruments > Time Profiler) before shipping.")
        return 1
    if record:
        new = {k: {"history": (base.get(k, {}).get("history", []) + [round(m["median"], 4)])[-KEEP:], "unit": m["unit"]}
               for k, m in got.items()}
        with open(BASELINE, "w") as f:
            json.dump(new, f, indent=2, sort_keys=True); f.write("\n")
        print(f"perf gate OK — baseline updated ({len(new)} metrics, {len(gone)} removed)")
    else:
        print("perf gate OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
