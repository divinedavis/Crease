#!/usr/bin/env bash
# Build and run the iOS UI test suite against real data.
#
#   ./scripts/ios-test.sh [simulator name]
set -euo pipefail

SIM="${1:-iPhone 17 Pro}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS="$ROOT/apps/ios"

# Derived data must live outside ~/Desktop: it is iCloud-synced, which stamps
# extended attributes onto the build product, and codesign then rejects it with
# "resource fork, Finder information, or similar detritus not allowed".
DD="${CREASE_DERIVED_DATA:-/tmp/crease-dd}"

echo "==> minting a session for the test customer"
eval "$(node "$ROOT/scripts/ios-session.mjs")"

echo "==> generating project"
(cd "$IOS" && xcodegen generate >/dev/null)
xattr -cr "$IOS" 2>/dev/null || true

# xcodebuild refuses to overwrite an existing result bundle, so a second run
# fails for a reason that has nothing to do with the tests.
rm -rf "$DD/TestResults.xcresult"

echo "==> testing on $SIM"
# xcodebuild forwards only variables prefixed TEST_RUNNER_ into the test
# runner's environment; a bare NAME=value sets a build setting instead, which
# the tests never see.
cd "$IOS"
export TEST_RUNNER_UITEST_ACCESS_TOKEN="$UITEST_ACCESS_TOKEN"
export TEST_RUNNER_UITEST_REFRESH_TOKEN="$UITEST_REFRESH_TOKEN"

xcodebuild test \
  -project Crease.xcodeproj \
  -scheme Crease \
  -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath "$DD" \
  -resultBundlePath "$DD/TestResults.xcresult" \
  2>&1 | grep -E "Test Case '.*(passed|failed)|error:|TEST (SUCCEEDED|FAILED)" || true

echo "==> result bundle: $DD/TestResults.xcresult"
