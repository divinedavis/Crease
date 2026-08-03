#!/usr/bin/env bash
# Archive, export and upload Crease to TestFlight.
#
#   ./scripts/testflight.sh          # bump build number, archive, upload
#   ./scripts/testflight.sh --no-bump
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
[ "${1:-}" = "--no-bump" ] && BUMP=0

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
echo "==> pre-flight: building for the simulator"
xcodebuild -project Crease.xcodeproj -scheme Crease \
  -destination "platform=iOS Simulator,name=$SMOKE_SIM" \
  -derivedDataPath "$SMOKE_DD" -quiet build CODE_SIGNING_ALLOWED=NO

SIM_ID=$(xcrun simctl list devices available | grep "$SMOKE_SIM (" | grep -oE '[0-9A-F-]{36}' | head -1)
[ -n "$SIM_ID" ] || { echo "no simulator named '$SMOKE_SIM'" >&2; exit 1; }
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
