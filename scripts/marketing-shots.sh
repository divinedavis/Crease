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
eval "$(node "$ROOT/scripts/ios-session.mjs")"
export TEST_RUNNER_UITEST_ACCESS_TOKEN="$UITEST_ACCESS_TOKEN"
export TEST_RUNNER_UITEST_REFRESH_TOKEN="$UITEST_REFRESH_TOKEN"

cd "$IOS"
xcodegen generate >/dev/null
xattr -cr "$IOS" 2>/dev/null || true
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
python3 - "$OUT" <<'PY'
import json, pathlib, shutil, sys
out = pathlib.Path(sys.argv[1])
manifest = out / 'manifest.json'
if not manifest.exists():
    print('no manifest — nothing exported'); raise SystemExit(1)
data = json.loads(manifest.read_text())
count = 0
for entry in data:
    for att in entry.get('attachments', []):
        name = att.get('suggestedHumanReadableName') or att.get('exportedFileName')
        src = out / att['exportedFileName']
        if not src.exists() or not name: continue
        stem = pathlib.Path(name).stem
        if not stem[:2].isdigit(): continue
        shutil.copy(src, out / f'{stem}.png')
        count += 1
print(f'exported {count} named screenshots to {out}')
PY
