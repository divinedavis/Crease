#!/usr/bin/env bash
# Ship the canvass tool. The committed index.html carries placeholders; the
# Supabase URL and anon key are substituted here from the local .env, so the
# public repo never carries a project credential, even a publishable one.
set -euo pipefail

HOST="${CREASE_HOST:?set CREASE_HOST=root@your.server.ip}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

URL="$(grep '^SUPABASE_URL=' "$ROOT/services/dispatch/.env" | cut -d= -f2)"
ANON="$(grep '^SUPABASE_ANON_KEY=' "$ROOT/services/dispatch/.env" | cut -d= -f2)"
[ -n "$URL" ] && [ -n "$ANON" ] || { echo "missing Supabase env"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
sed -e "s|__SUPABASE_URL__|$URL|" -e "s|__SUPABASE_ANON_KEY__|$ANON|" \
  "$ROOT/growth/prospects/index.html" > "$STAGE/index.html"

# The page loads the SDK from this origin, so the bundle ships with it or the
# tool is a blank screen.
cp "$ROOT/growth/prospects/supabase.js" "$STAGE/supabase.js"

# The tab icon. Without them the browser falls back to a letter from the
# domain, which is how this page spent its life labelled "U".
cp "$ROOT/growth/prospects/icon.svg" "$STAGE/icon.svg"
cp "$ROOT/growth/prospects/apple-touch-icon.png" "$STAGE/apple-touch-icon.png"

# /var/www, not /root: nginx's workers cannot traverse root's home.
ssh "$HOST" 'mkdir -p /var/www/crease-prospects'
scp -q "$STAGE/index.html" "$STAGE/supabase.js" "$STAGE/icon.svg" \
  "$STAGE/apple-touch-icon.png" "$HOST:/var/www/crease-prospects/"

echo -n "deployed: " && curl -s -o /dev/null -w '%{http_code}\n' https://portal.usecreaseapp.com/prospects/
