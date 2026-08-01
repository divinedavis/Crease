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
xattr -cr "$IOS" 2>/dev/null || true
rm -rf "$WORK"
mkdir -p "$WORK"

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
