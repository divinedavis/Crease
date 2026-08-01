#!/usr/bin/env bash
# Build locally, ship to the droplet, restart both services, verify.
#
#   ./deploy/deploy.sh
#
# Secrets are never committed and never scp'd from the repo: the droplet's
# .env files are written once by bootstrap.sh from the macOS keychain and are
# left alone by every subsequent deploy.
set -euo pipefail

HOST="${CREASE_HOST:-root@104.236.120.144}"
REMOTE=/root/crease
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> building"
npx tsc -p packages/delivery/tsconfig.json
npx tsc -p services/dispatch/tsconfig.json
npm run build -w @crease/portal >/dev/null

echo "==> staging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/services/dispatch" "$STAGE/packages/delivery" "$STAGE/apps/portal"
cp -R services/dispatch/dist "$STAGE/services/dispatch/"
cp services/dispatch/package.json "$STAGE/services/dispatch/"
cp -R packages/delivery/dist "$STAGE/packages/delivery/"
cp packages/delivery/package.json "$STAGE/packages/delivery/"

# Next standalone already contains its traced node_modules and a server.js.
cp -R apps/portal/.next/standalone/. "$STAGE/apps/portal/"
mkdir -p "$STAGE/apps/portal/.next"
cp -R apps/portal/.next/static "$STAGE/apps/portal/.next/static"
[ -d apps/portal/public ] && cp -R apps/portal/public "$STAGE/apps/portal/public"

# The standalone bundle nests the app under its workspace path; flatten it so
# WorkingDirectory in the unit file stays stable.
if [ -f "$STAGE/apps/portal/apps/portal/server.js" ]; then
  cp -R "$STAGE/apps/portal/apps/portal/." "$STAGE/apps/portal/"
  rm -rf "$STAGE/apps/portal/apps"
fi

cp -R deploy "$STAGE/deploy"
cp -R supabase "$STAGE/supabase"
cp -R scripts "$STAGE/scripts"

echo "==> uploading"
ssh "$HOST" "mkdir -p $REMOTE /var/log/crease"
rsync -az --delete \
  --exclude '.env' --exclude '.env.local' \
  "$STAGE/" "$HOST:$REMOTE/"

echo "==> installing dispatch runtime deps"
ssh "$HOST" "cd $REMOTE/services/dispatch && npm install --omit=dev --no-audit --no-fund --silent"

# scripts/ imports @supabase/supabase-js but sits outside the dispatch
# package, so give the deploy root a resolvable node_modules.
ssh "$HOST" "ln -sfn $REMOTE/services/dispatch/node_modules $REMOTE/node_modules"

echo "==> systemd"
scp -q deploy/crease-dispatch.service deploy/crease-portal.service "$HOST:/etc/systemd/system/"
ssh "$HOST" 'systemctl daemon-reload && systemctl enable --now crease-dispatch crease-portal && systemctl restart crease-dispatch crease-portal'

echo "==> waiting for health"
for i in $(seq 1 15); do
  if ssh "$HOST" 'curl -sf -m 3 http://127.0.0.1:8011/healthz >/dev/null'; then break; fi
  sleep 2
done

echo "==> verifying"
ssh "$HOST" 'echo -n "dispatch: "; curl -s -m 5 http://127.0.0.1:8011/healthz; echo; \
             echo -n "portal:   "; curl -s -o /dev/null -w "%{http_code}\n" -m 8 http://127.0.0.1:3010/login; \
             systemctl is-active crease-dispatch crease-portal'
echo "==> done"
