#!/usr/bin/env bash
# Ship the canvass tool and the expansion roadmap. Both committed pages carry
# placeholders; the Supabase URL and anon key are substituted here from the
# local .env, so the public repo never carries a project credential.
set -euo pipefail

HOST="${CREASE_HOST:?set CREASE_HOST=root@your.server.ip}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

URL="$(grep '^SUPABASE_URL=' "$ROOT/services/dispatch/.env" | cut -d= -f2)"
ANON="$(grep '^SUPABASE_ANON_KEY=' "$ROOT/services/dispatch/.env" | cut -d= -f2)"
[ -n "$URL" ] && [ -n "$ANON" ] || { echo "missing Supabase env"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# Both pages carry the placeholders and both are served from this directory.
for page in index.html roadmap.html; do
  sed -e "s|__SUPABASE_URL__|$URL|" -e "s|__SUPABASE_ANON_KEY__|$ANON|" \
    "$ROOT/growth/prospects/$page" > "$STAGE/$page"
done

# The page loads the SDK from this origin, so the bundle ships with it or the
# tool is a blank screen.
cp "$ROOT/growth/prospects/supabase.js" "$STAGE/supabase.js"

# The tab icon. Without them the browser falls back to a letter from the
# domain, which is how this page spent its life labelled "U".
cp "$ROOT/growth/prospects/icon.svg" "$STAGE/icon.svg"
cp "$ROOT/growth/prospects/apple-touch-icon.png" "$STAGE/apple-touch-icon.png"

# /var/www, not /root: nginx's workers cannot traverse root's home.
ssh "$HOST" 'mkdir -p /var/www/crease-prospects'
scp -q "$STAGE/index.html" "$STAGE/roadmap.html" "$STAGE/supabase.js" "$STAGE/icon.svg" \
  "$STAGE/apple-touch-icon.png" "$HOST:/var/www/crease-prospects/"

# Check the canonical host. usecreaseapp.com now 301s to creasenyc.com, so
# probing it only ever proved the redirect existed — a green code that said
# nothing about whether the page deployed. Basic auth is gone from /prospects
# too (RLS is what scopes the notes), so 200 is now the real pass.
fail=0
for page in "" roadmap.html; do
  code="$(curl -sL -o /dev/null -w '%{http_code}' "https://portal.creasenyc.com/prospects/$page")"
  echo "deployed /prospects/$page: $code"
  [ "$code" = "200" ] || { echo "  UNEXPECTED — wanted 200"; fail=1; }
done

# A 200 only proves nginx served a file. Prove it served THIS build: the
# placeholders must be gone and the shared-session adapter must be present,
# or the page silently asks for a second login again.
body="$(curl -sL "https://portal.creasenyc.com/prospects/")"
case "$body" in
  *__SUPABASE_URL__*) echo "  FAIL: placeholders not substituted"; fail=1 ;;
esac
case "$body" in
  *"storage: cookieStorage"*) echo "  ok: shares the portal session" ;;
  *) echo "  FAIL: cookie session adapter missing"; fail=1 ;;
esac
exit $fail
