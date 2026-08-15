#!/usr/bin/env bash
# Build locally, ship to the droplet, restart both services, verify.
#
#   ./deploy/deploy.sh
#
# Secrets are never committed and never scp'd from the repo: the droplet's
# .env files are written once by bootstrap.sh from the macOS keychain and are
# left alone by every subsequent deploy.
set -euo pipefail

# Set CREASE_HOST=root@<ip>. Not defaulted in a public repo: the box is
# shared with several unrelated production sites.
HOST="${CREASE_HOST:?set CREASE_HOST=root@your.server.ip}"
# The services run as the unprivileged `crease` user out of /opt (they used to
# run as root from /root/crease, which meant any RCE in the webhook-facing
# dispatch process — holder of the service-role, Stripe and Uber keys — was
# instant root on a box shared with six other sites).
REMOTE=/opt/crease
SERVICE_USER=crease
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> building"
# Build every package, so adding one cannot be silently forgotten here.
for pkg in packages/*/; do
  [ -f "$pkg/tsconfig.json" ] && npx tsc -p "$pkg/tsconfig.json"
done
npx tsc -p services/dispatch/tsconfig.json
npm run build -w @crease/portal >/dev/null

echo "==> staging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/services/dispatch" "$STAGE/packages" "$STAGE/apps/portal"
cp -R services/dispatch/dist "$STAGE/services/dispatch/"
cp services/dispatch/package.json "$STAGE/services/dispatch/"

# Every built package, not an enumerated list — the last deploy shipped a
# dispatch binary that imported a package the staging step never copied.
for pkg in packages/*/; do
  name="$(basename "$pkg")"
  [ -d "$pkg/dist" ] || continue
  mkdir -p "$STAGE/packages/$name"
  cp -R "$pkg/dist" "$STAGE/packages/$name/"
  cp "$pkg/package.json" "$STAGE/packages/$name/"
done

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
# --delete removes anything on the box that is not in the stage, so every
# credential that lives only on the droplet has to be named here or a deploy
# quietly destroys it. secrets/ holds the APNs .p8, which Apple issues exactly
# once and will not reissue.
rsync -az --delete \
  --exclude '.env' --exclude '.env.local' --exclude 'secrets/' \
  "$STAGE/" "$HOST:$REMOTE/"

echo "==> installing dispatch runtime deps"
ssh "$HOST" "cd $REMOTE/services/dispatch && npm install --omit=dev --no-audit --no-fund --silent"

# scripts/ imports @supabase/supabase-js but sits outside the dispatch
# package, so give the deploy root a resolvable node_modules.
ssh "$HOST" "ln -sfn $REMOTE/services/dispatch/node_modules $REMOTE/node_modules"

# rsync/npm run over SSH as root, so the tree comes back root-owned. Hand it
# back or the unprivileged service cannot read its own code and .env.
echo "==> restoring ownership to $SERVICE_USER"
ssh "$HOST" "chown -R $SERVICE_USER:$SERVICE_USER $REMOTE && chmod 700 $REMOTE/secrets 2>/dev/null; chmod 600 $REMOTE/services/dispatch/.env $REMOTE/apps/portal/.env.local 2>/dev/null; true"

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
