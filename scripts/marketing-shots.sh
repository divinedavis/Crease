#!/usr/bin/env bash
# Capture App Store screens from a signed-in session and export the PNGs.
#
#   ./scripts/marketing-shots.sh
#
# Runs only MarketingScreenshots, which is excluded from the normal suite
# because it asserts nothing — it exists to produce artefacts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS="$ROOT/apps/ios"
DD="${CREASE_DERIVED_DATA:-/tmp/crease-dd}"
OUT="${1:-$ROOT/apps/ios/marketing/raw}"

: "${CREASE_TEST_PASSWORD:?set CREASE_TEST_PASSWORD (keychain: crease-test-password)}"

mint_session() {
  # --with-refresh because Session.swift only injects a test session when both
  # halves are present; without the flag ios-session.mjs prints only the access
  # token and this script died on an unbound UITEST_REFRESH_TOKEN.
  local env
  env="$(node "$ROOT/scripts/ios-session.mjs" --with-refresh)" || {
    echo "could not mint a session — is CREASE_TEST_PASSWORD correct?" >&2
    exit 1
  }
  eval "$env"
  : "${UITEST_ACCESS_TOKEN:?session minting returned no token}"
  export TEST_RUNNER_UITEST_ACCESS_TOKEN="$UITEST_ACCESS_TOKEN"
  export TEST_RUNNER_UITEST_REFRESH_TOKEN="$UITEST_REFRESH_TOKEN"
}

cd "$IOS"
xcodegen generate >/dev/null
xattr -cr "$IOS" 2>/dev/null || true

# Two of the five screens are the Orders list and one order's tracking view,
# and both need the injected session to actually be honoured on the wire. It is
# not always: some runs come back with an Orders screen RLS answered as if
# nobody were signed in, which photographs as "No orders yet" over an account
# that has three orders. A freshly minted session is what makes the difference,
# so retry with one rather than shipping a panel of an empty state.
ATTEMPTS="${CREASE_SHOT_ATTEMPTS:-3}"
for attempt in $(seq 1 "$ATTEMPTS"); do
  echo "==> capture attempt $attempt of $ATTEMPTS"
  mint_session
  rm -rf "$DD/Marketing.xcresult"

  xcodebuild test \
    -project Crease.xcodeproj -scheme Crease \
    -destination "platform=iOS Simulator,name=${CREASE_SIM:-iPhone 17 Pro}" \
    -derivedDataPath "$DD" \
    -resultBundlePath "$DD/Marketing.xcresult" \
    -only-testing:CreaseUITests/MarketingScreenshots \
    2>&1 | grep -E "Test Case .*(passed|failed)|error:" || true

  rm -rf "$OUT"; mkdir -p "$OUT"
  xcrun xcresulttool export attachments --path "$DD/Marketing.xcresult" --output-path "$OUT" >/dev/null 2>&1

  # The exporter names files by UUID; the manifest maps them back to the names
  # the test gave them, which is what the composer keys off.
  python3 "$ROOT/scripts/lib/name-shots.py" "$OUT"

  if compgen -G "$OUT/05-tracking*" >/dev/null; then
    echo "==> all five screens captured"
    exit 0
  fi
  echo "==> the Orders list came back empty; retrying with a new session" >&2
done

echo "could not capture the order screens after $ATTEMPTS attempts" >&2
exit 1
