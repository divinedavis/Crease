#!/usr/bin/env bash
# Xcode Cloud: runs right after the clone, before the build.
#
# Secrets.xcconfig is gitignored, so a fresh clone has nothing for the Debug
# and Release configs to read. It is rebuilt here. Only SUPABASE_ANON_KEY is a
# workflow secret (Xcode Cloud > Workflow > Environment); the host and dispatch
# URL are public and default to the values in Secrets.xcconfig.example. Xcode
# refused to save either of them as a secret ("invalid value"), 2026-10-17.
#
# Builds start only from tf-<build> tags, which scripts/testflight.sh --cloud
# pushes after ios-gates.sh passes locally. The gates sign in against
# production and reseed it, so they stay on the Mac.
set -euo pipefail
IOS="$CI_PRIMARY_REPOSITORY_PATH/apps/ios"

: "${SUPABASE_ANON_KEY:?set SUPABASE_ANON_KEY in the Xcode Cloud workflow environment}"
SUPABASE_HOST="${SUPABASE_HOST:-crease.supabase.co}"
DISPATCH_URL="${DISPATCH_URL:-https://api.creasenyc.com}"

# A literal // begins a comment in xcconfig; rebuild the scheme from SLASH,
# the same way Secrets.xcconfig.example does.
DISPATCH_XC="${DISPATCH_URL//\/\//\$(SLASH)\$(SLASH)}"
cat > "$IOS/Secrets.xcconfig" <<XC
SUPABASE_HOST = $SUPABASE_HOST
SUPABASE_ANON_KEY = $SUPABASE_ANON_KEY
SLASH = /
DISPATCH_URL = $DISPATCH_XC
XC
echo "wrote Secrets.xcconfig"

# The tag names the build number the gates passed on. If the committed project
# disagrees, the upload would be a different build than the one tested, or a
# number TestFlight has already seen.
if [ -n "${CI_TAG:-}" ]; then
  WANT="${CI_TAG#tf-}"
  HAVE=$(grep -E '^ +CURRENT_PROJECT_VERSION:' "$IOS/project.yml" | grep -oE '[0-9]+' | head -1)
  if [ "$WANT" != "$HAVE" ]; then
    echo "tag $CI_TAG but project.yml is at build $HAVE" >&2
    exit 1
  fi
  grep -q "CURRENT_PROJECT_VERSION = $HAVE;" "$IOS/Crease.xcodeproj/project.pbxproj" \
    || { echo "project.pbxproj is stale: regenerate with xcodegen and re-tag" >&2; exit 1; }
  echo "building $CI_TAG"
fi
