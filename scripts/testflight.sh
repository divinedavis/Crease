#!/usr/bin/env bash
# Archive, export and upload Crease to TestFlight.
#
#   ./scripts/testflight.sh          # bump build number, archive, upload
#   ./scripts/testflight.sh --no-bump
#   ./scripts/testflight.sh --cloud  # gates + pre-flight here, then push a
#                                    # tf-<build> tag; Xcode Cloud archives
#                                    # and uploads (apps/ios/ci_scripts)
#
# Signing is fully automatic: xcodebuild is given the ASC API key directly, so
# it can create the distribution certificate and provisioning profile itself
# rather than requiring anyone to click through the developer portal.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS="$ROOT/apps/ios"
source "$ROOT/scripts/asc-config.env"

# Never build inside ~/Desktop: it is iCloud-synced, which stamps extended
# attributes onto the build product, and codesign rejects it as "resource fork,
# Finder information, or similar detritus".
WORK="${CREASE_BUILD_DIR:-/tmp/crease-build}"
ARCHIVE="$WORK/Crease.xcarchive"
EXPORT="$WORK/export"

BUMP=1
CLOUD=0
for ARG in "$@"; do
  case "$ARG" in
    --no-bump) BUMP=0 ;;
    --cloud) CLOUD=1 ;;
    *) echo "unknown option: $ARG" >&2; exit 2 ;;
  esac
done

if [ "$CLOUD" = "1" ]; then
  # Xcode Cloud builds what is in git, not what is on disk. Anything
  # uncommitted would pass the gates here and be missing from the upload.
  if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "--cloud needs a clean tree: commit or stash first" >&2; exit 1
  fi
  [ "$(git -C "$ROOT" branch --show-current)" = "pricing-route-aware" ] \
    || { echo "--cloud ships only from pricing-route-aware" >&2; exit 1; }
fi

# Apple's four quality checks before anything is bumped or built for upload:
# Swift Testing, every XCUITest incl. the accessibility audit, the performance
# budget, MetricKit + Xcode Organizer, and Features/ coverage
# (owner, 2026-10-03). CREASE_SKIP_GATES=1 is for an emergency only; say why.
if [ "${CREASE_SKIP_GATES:-0}" = "1" ]; then
  echo "==> WARNING: CREASE_SKIP_GATES=1 — shipping without the quality gates" >&2
else
  "$ROOT/scripts/ios-gates.sh"
fi

cd "$IOS"

if [ "$BUMP" = "1" ]; then
  CURRENT=$(grep -E '^ +CURRENT_PROJECT_VERSION:' project.yml | grep -oE '[0-9]+' | head -1)
  NEXT=$((CURRENT + 1))
  # TestFlight rejects a build number it has already seen, and the failure
  # arrives minutes later by email rather than at upload time.
  sed -i '' -E "s/(CURRENT_PROJECT_VERSION: \")[0-9]+(\")/\1$NEXT\2/" project.yml
  echo "==> build number $CURRENT -> $NEXT"
fi

echo "==> generating project"
xcodegen generate >/dev/null

# ---------------------------------------------------------------------------
# Pre-flight: compile, then actually launch it.
#
# A clean archive proves the code compiles. It does not prove the app starts.
# Missing usage strings, entitlements the profile does not carry, and force
# unwraps in an initialiser all compile perfectly and then trap on launch —
# and a build that traps reaches testers before anyone notices.
# ---------------------------------------------------------------------------
rm -rf "$WORK"
mkdir -p "$WORK"

SMOKE_SIM="${CREASE_SIM:-iPhone 17 Pro}"
SMOKE_DD="$WORK/smoke"
# Pick the simulator by UDID. A name-only destination means "that name on the
# newest runtime", and when the newest runtime has no device of that name
# (Xcode 27, 2026-10-17) xcodebuild refuses even though one exists on 26.x.
SIM_ID=$(xcrun simctl list devices available | grep "$SMOKE_SIM (" | grep -oE '[0-9A-F-]{36}' | head -1)
[ -n "$SIM_ID" ] || { echo "no simulator named '$SMOKE_SIM'" >&2; exit 1; }
echo "==> pre-flight: building for the simulator"
xcodebuild -project Crease.xcodeproj -scheme Crease \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath "$SMOKE_DD" -quiet build CODE_SIGNING_ALLOWED=NO

xcrun simctl boot "$SIM_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_ID" -b >/dev/null 2>&1 || true

APP="$SMOKE_DD/Build/Products/Debug-iphonesimulator/Crease.app"
BUNDLE=com.divinedavis.crease
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
BEFORE=$(ls "$CRASH_DIR" 2>/dev/null | grep -ci crease || true)

echo "==> pre-flight: launching"
xcrun simctl terminate "$SIM_ID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$SIM_ID" "$APP"
PID=$(xcrun simctl launch "$SIM_ID" "$BUNDLE" | awk -F': ' '{print $2}')
sleep 8

if ! xcrun simctl spawn "$SIM_ID" launchctl list 2>/dev/null | grep -q "$BUNDLE"; then
  if ! ps -p "${PID:-0}" >/dev/null 2>&1; then
    AFTER=$(ls "$CRASH_DIR" 2>/dev/null | grep -ci crease || true)
    echo "PRE-FLIGHT FAILED: the app did not stay running." >&2
    if [ "${AFTER:-0}" -gt "${BEFORE:-0}" ]; then
      LATEST=$(ls -t "$CRASH_DIR"/Crease* 2>/dev/null | head -1)
      echo "--- crash report: $LATEST ---" >&2
      python3 -c "
import json,sys,pathlib
p=pathlib.Path('$LATEST')
txt=p.read_text(errors='ignore').split(chr(10),1)
try:
    d=json.loads(txt[1])
    ex=d.get('exception',{})
    print('  type:', ex.get('type'), ex.get('signal'))
    print('  reason:', (d.get('termination') or {}).get('reasons') or ex.get('message'))
    for f in (d.get('threads') or [{}])[0].get('frames',[])[:8]:
        print('   ', f.get('imageIndex'), f.get('symbol') or f.get('imageOffset'))
except Exception as e:
    print('  (could not parse:', e, ')')
" >&2
    fi
    echo "Not shipping a build that traps on launch." >&2
    exit 1
  fi
fi
xcrun simctl terminate "$SIM_ID" "$BUNDLE" 2>/dev/null || true
echo "==> pre-flight: app launched and stayed alive"

# ---------------------------------------------------------------------------
# Purpose strings.
#
# App Store processing statically analyses the binary and rejects it with
# ITMS-90683 if any privacy-gated API is referenced without a matching
# NS*UsageDescription — including references that come from an SDK and are
# never called. This passes `altool --validate-app`, passes a launch smoke
# test, and is reported only by email hours later, so five builds were lost to
# it before anyone knew. Checking here costs a second.
# ---------------------------------------------------------------------------
echo "==> pre-flight: purpose strings"
MISSING=""
for KEY in $(strings "$APP/Crease" 2>/dev/null | grep -oE '^NS[A-Za-z]+UsageDescription$' | sort -u); do
  if ! /usr/libexec/PlistBuddy -c "Print :$KEY" "$APP/Info.plist" >/dev/null 2>&1; then
    MISSING="$MISSING $KEY"
  fi
done
if [ -n "$MISSING" ]; then
  echo "PRE-FLIGHT FAILED: the binary references privacy APIs with no purpose string:" >&2
  for K in $MISSING; do echo "    $K" >&2; done
  echo "  Apple rejects this as ITMS-90683 after upload, not during validation." >&2
  echo "  Add the key(s) to project.yml under info.properties and re-run." >&2
  exit 1
fi
echo "==> pre-flight: purpose strings declared"

if [ "$CLOUD" = "1" ]; then
  BUILD=$(grep -E '^ +CURRENT_PROJECT_VERSION:' project.yml | grep -oE '[0-9]+' | head -1)
  TAG="tf-$BUILD"
  cd "$ROOT"
  git add apps/ios/project.yml apps/ios/Crease.xcodeproj
  if ! git diff --cached --quiet; then
    git commit -q -m "Ship build $BUILD to TestFlight via Xcode Cloud" \
      -m "ios-gates.sh, the launch pre-flight and the purpose-string check passed locally; Xcode Cloud archives and uploads from tag $TAG." \
      -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
  fi
  git tag "$TAG"
  # One push, so the pre-push hook runs once. main follows the branch because
  # Dependabot only scans the default branch.
  git push -q origin pricing-route-aware pricing-route-aware:main "$TAG"
  echo "==> pushed $TAG; Xcode Cloud takes it from here."
  echo "    python3 scripts/asc.py builds   # once it has uploaded"
  exit 0
fi

xattr -cr "$IOS" 2>/dev/null || true

echo "==> archiving"
xcodebuild archive \
  -project Crease.xcodeproj \
  -scheme Crease \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$WORK/dd" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  DEVELOPMENT_TEAM="$ASC_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  -quiet

echo "==> exporting"
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$ASC_TEAM_ID</string>
  <key>uploadSymbols</key><true/>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -quiet

IPA="$(ls "$EXPORT"/*.ipa | head -1)"
echo "==> built $IPA"

echo "==> validating before upload"
# Validation catches the whole class of errors that otherwise come back as an
# email 20 minutes later: missing icons, bad entitlements, unsupported SDKs.
xcrun altool --validate-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1 | tail -20

echo "==> uploading"
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1 | tail -20

echo "==> uploaded. Processing takes a few minutes:"
echo "    python3 scripts/asc.py builds"
