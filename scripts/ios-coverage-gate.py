#!/usr/bin/env python3
"""Every feature screen is exercised by a test (2026-10-03, owner: the checks
must follow features as they are added and removed).

Reads the code coverage of the gate's test run (unit + XCUITest, collected
with -enableCodeCoverage YES) and fails any Swift file under
apps/ios/Crease/Features that no test executed a single line of. A new screen
therefore cannot ship without a test that opens it, and nothing has to be
listed by hand: the folder IS the list. A deleted screen simply drops out; a
UI test still looking for it fails on its own (waitForExistence), so dead
tests surface in the same run.

  python3 scripts/ios-coverage-gate.py /tmp/crease-dd/Gates.xcresult
"""
import json, subprocess, sys

FEATURES = "/apps/ios/Crease/Features/"


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    out = subprocess.run(["xcrun", "xccov", "view", "--report", "--json", sys.argv[1]],
                         capture_output=True, text=True, check=True).stdout
    files = {}
    for target in json.loads(out).get("targets", []):
        for f in target.get("files", []):
            if FEATURES in f["path"]:
                # a file can appear under more than one target; keep the best
                files[f["path"]] = max(files.get(f["path"], 0), f.get("coveredLines", 0))
    if not files:
        print("coverage gate: no feature files in the coverage report — was -enableCodeCoverage YES set?")
        return 1
    cold = sorted(p.split(FEATURES)[1] for p, n in files.items() if n == 0)
    print(f"coverage gate: {len(files) - len(cold)}/{len(files)} feature files exercised by a test")
    if cold:
        print("NO TEST touches these screens (add a UI test that opens each one):")
        for c in cold:
            print(f"  - apps/ios/Crease/Features/{c}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
