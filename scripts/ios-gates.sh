#!/usr/bin/env bash
# Apple's four quality checks, run by testflight.sh before every upload
# (owner, 2026-10-02/03: "make sure we do 1-4 before any push to test flight",
# and they must follow the app as features come and go).
#
#   1. Swift Testing  — the @Test suites in CreaseTests must run (and pass)
#   2. XCUITest       — the whole UI suite, incl. AccessibilityAuditTests
#                       (performAccessibilityAudit on every screen it reaches)
#   3. XCTMetric      — PerformanceTests, judged by ios-perf-gate.py against
#                       the median of the last 5 passing ships
#   4. MetricKit      — the subscriber is still wired; the Xcode Organizer's
#                       field numbers for recent builds are printed
# plus ios-coverage-gate.py: every screen under Features/ is executed by a test.
#
#   ./scripts/ios-gates.sh            # all of it (testflight.sh runs this)
#   SIM_ID=<udid> ./scripts/ios-gates.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS="$ROOT/apps/ios"
DD="${CREASE_DERIVED_DATA:-/tmp/crease-dd}"
PY="${PY:-$HOME/.venvs/spendcap/bin/python}"

SIM_ID="${SIM_ID:-$(xcrun simctl list devices available -j | python3 -c "import json,sys
d=json.load(sys.stdin)
print(next(iter([v['udid'] for r in d['devices'].values() for v in r if v.get('name')=='iPhone 17 Pro']), ''))")}"
[ -n "$SIM_ID" ] || { echo "no iPhone 17 Pro simulator" >&2; exit 1; }
xcrun simctl boot "$SIM_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_ID" -b >/dev/null 2>&1 || true

echo "==> gate 4a: MetricKit still wired"
grep -q "MXMetricManager.shared.add" "$IOS/Crease/Core/Metrics.swift" \
  && grep -q "\[MXDiagnosticPayload\]" "$IOS/Crease/Core/Metrics.swift" \
  && grep -rq "Metrics.shared.start()" "$IOS/Crease" \
  || { echo "GATE FAILED: Core/Metrics.swift or its start() call is gone" >&2; exit 1; }

echo "==> minting a session for the test customer"
CREASE_TEST_PASSWORD="${CREASE_TEST_PASSWORD:-$(security find-generic-password -s crease-test-password -w 2>/dev/null || true)}"
export CREASE_TEST_PASSWORD
: "${CREASE_TEST_PASSWORD:?keychain item crease-test-password missing}"
SESSION_ENV="$(node "$ROOT/scripts/ios-session.mjs" --with-refresh)" || { echo "could not mint a session" >&2; exit 1; }
eval "$SESSION_ENV"
export TEST_RUNNER_UITEST_ACCESS_TOKEN="$UITEST_ACCESS_TOKEN" TEST_RUNNER_UITEST_REFRESH_TOKEN="$UITEST_REFRESH_TOKEN"

# The UI tests read the demo customer's orders (and the cancel test uses one
# up); seed-marketing rewrites the same fixed rows, so it is safe every run.
echo "==> seeding the demo customer's orders"
CREASE_ALLOW_PROD=1 node "$ROOT/scripts/seed-marketing.mjs" >/dev/null

(cd "$IOS" && xcodegen generate >/dev/null)
xattr -cr "$IOS" 2>/dev/null || true
cd "$IOS"
# a fresh install: permissions and keychain state from an earlier run must not
# decide a test
xcrun simctl uninstall "$SIM_ID" com.divinedavis.crease 2>/dev/null || true

run() {   # run <result bundle> <log> <xcodebuild test args...>
  local bundle="$1" log="$2"; shift 2
  rm -rf "$bundle"
  set +e
  xcodebuild test -project Crease.xcodeproj -scheme Crease \
    -destination "platform=iOS Simulator,id=$SIM_ID" -derivedDataPath "$DD" \
    -resultBundlePath "$bundle" "$@" 2>&1 \
    | grep -E "Test Case '.*(passed|failed)|error:|Test run with|✘|TEST (SUCCEEDED|FAILED)" > "$log"
  local status=${PIPESTATUS[0]}
  set -e
  tail -15 "$log"
  if [ "$status" -ne 0 ]; then
    echo "---- failures ($log) ----"; grep -E "error:|' failed \(|✘" "$log" | head -40 || true
    echo "GATE FAILED: tests failed (full results: $bundle)" >&2
    exit 1
  fi
}

echo "==> gates 1+2: unit tests (XCTest + Swift Testing) and every XCUITest incl. the accessibility audit"
run "$DD/Gates.xcresult" "$DD/gates.log" -enableCodeCoverage YES \
  -skip-testing:CreaseUITests/MarketingScreenshots -skip-testing:CreaseUITests/PerformanceTests
# xcodebuild passes with zero tests run; make each gate prove it ran
grep -qE "Test run with [1-9][0-9]* tests?.* passed" "$DD/gates.log" \
  || { echo "GATE FAILED: no Swift Testing tests ran" >&2; exit 1; }
grep -q "AccessibilityAuditTests" "$DD/gates.log" \
  || { echo "GATE FAILED: the accessibility audit did not run" >&2; exit 1; }
[ "$(grep -c "' passed (" "$DD/gates.log")" -gt 20 ] \
  || { echo "GATE FAILED: suspiciously few XCTest cases passed" >&2; exit 1; }

echo "==> coverage: every Features/ screen is exercised"
python3 "$ROOT/scripts/ios-coverage-gate.py" "$DD/Gates.xcresult"

echo "==> gate 3: performance"
xcrun simctl uninstall "$SIM_ID" com.divinedavis.crease 2>/dev/null || true
CREASE_ALLOW_PROD=1 node "$ROOT/scripts/seed-marketing.mjs" >/dev/null
run "$DD/Perf.xcresult" "$DD/perf.log" -only-testing:CreaseUITests/PerformanceTests
python3 "$ROOT/scripts/ios-perf-gate.py" "$DD/Perf.xcresult" --record

echo "==> gate 4b: Xcode Organizer (report only)"
"$PY" "$ROOT/scripts/organizer-report.py" || echo "warning: Organizer report unavailable"
echo "==> all quality gates passed"
