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

# What ships must be what was reviewed. This deploy builds from the working
# tree and installs two root-owned systemd units, so an uncommitted edit — or a
# stray file from another session working in the same checkout — reaches
# production without ever having been read by anyone. Refuse, rather than
# discover it later. CREASE_DEPLOY_DIRTY=1 is the deliberate escape hatch for a
# genuine hotfix.
if [ "${CREASE_DEPLOY_DIRTY:-0}" != "1" ]; then
  DIRTY="$(git status --porcelain -- services packages apps deploy scripts supabase 2>/dev/null || true)"
  if [ -n "$DIRTY" ]; then
    echo "refusing to deploy: uncommitted changes in the tree" >&2
    echo "$DIRTY" >&2
    echo "commit them, or set CREASE_DEPLOY_DIRTY=1 if this is a deliberate hotfix" >&2
    exit 1
  fi
fi
echo "==> deploying $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)"

# The repo pins Node 22 (.nvmrc, and `engines` in services/dispatch/package.json)
# while the droplet still runs 20, and nothing has ever said so out loud: the
# mismatch surfaces as a service that will not start after the restart, halfway
# through a deploy, not as anything you can read here. A warning rather than a
# failure on purpose — 20 is genuinely what the box runs today, so hard-failing
# would block every deploy, including the one that upgrades it.
echo "==> preflight: remote node"
# || true throughout: a missing .nvmrc or an unreachable box makes this check
# unavailable, which is not a reason to stop a deploy.
PINNED_MAJOR="$(tr -cd '0-9.' < .nvmrc 2>/dev/null | cut -d. -f1 || true)"
REMOTE_NODE="$(ssh "$HOST" 'node -v' 2>/dev/null || true)"
REMOTE_MAJOR="${REMOTE_NODE#v}"
REMOTE_MAJOR="${REMOTE_MAJOR%%.*}"
if [ -z "$PINNED_MAJOR" ]; then
  echo "!!  WARNING: no readable .nvmrc — cannot check the remote Node version" >&2
elif [ -z "$REMOTE_NODE" ]; then
  echo "!!  WARNING: could not read 'node -v' on $HOST — remote Node version unverified" >&2
elif [ "$REMOTE_MAJOR" != "$PINNED_MAJOR" ]; then
  echo "!!  WARNING: $HOST runs Node $REMOTE_NODE but this repo pins Node $PINNED_MAJOR" >&2
  echo "!!  (.nvmrc + services/dispatch/package.json engines). npm ci will warn and any" >&2
  echo "!!  ${PINNED_MAJOR}-only syntax or API in the built output will fail at service start." >&2
else
  echo "    node $REMOTE_NODE matches the pinned major ($PINNED_MAJOR)"
fi

echo "==> building"
# Build every package, so adding one cannot be silently forgotten here.
for pkg in packages/*/; do
  [ -f "$pkg/tsconfig.json" ] && npx tsc -p "$pkg/tsconfig.json"
done
npx tsc -p services/dispatch/tsconfig.json
npm run build -w @crease/portal >/dev/null
npm run build -w @crease/web >/dev/null

# NEXT_PUBLIC_* is baked into the client bundle at build time, on this laptop —
# the droplet's .env.local only reaches the server half. So a placeholder in
# the local file ships a browser client pointed at a host that does not exist,
# and every signed-in portal page dies with "a client-side exception has
# occurred". That is exactly what happened: apps/portal/.env.local read
# https://crease.supabase.co while the droplet read the real project.
#
# The anon key carries its project ref in its payload, so the two can be
# checked against each other without knowing either value here.
echo "==> preflight: public config baked into the client bundles"
for app in portal web; do
  env_file="apps/$app/.env.local"
  [ -f "$env_file" ] || continue
  url="$(grep -m1 '^NEXT_PUBLIC_SUPABASE_URL=' "$env_file" | cut -d= -f2- || true)"
  key="$(grep -m1 '^NEXT_PUBLIC_SUPABASE_ANON_KEY=' "$env_file" | cut -d= -f2- || true)"
  [ -n "$url" ] && [ -n "$key" ] || continue
  url_ref="$(printf '%s' "$url" | sed -E 's#https?://([^.]+)\..*#\1#')"
  key_ref="$(printf '%s' "$key" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | sed -E 's/.*"ref":"([^"]+)".*/\1/')"
  if [ -n "$key_ref" ] && [ "$url_ref" != "$key_ref" ]; then
    echo "ERROR: apps/$app/.env.local points at project '$url_ref' but its anon key belongs to '$key_ref'." >&2
    echo "       The client bundle is built from this file; shipping it breaks every signed-in page." >&2
    exit 1
  fi
  echo "    apps/$app -> $url_ref"
done

echo "==> staging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/services/dispatch" "$STAGE/packages" "$STAGE/apps/portal" "$STAGE/apps/web"
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

# The droplet installs with `npm ci`, which refuses to run without a lockfile,
# and the repo's root lock is a workspace lock that `npm ci` cannot read from a
# subdirectory. So resolve the dispatch tree here, on a laptop, and ship the
# result: the box then installs exactly these versions with integrity checking
# instead of re-resolving four caret ranges as root, unverified, into the
# process that holds the service-role, Stripe and Uber keys.
#
# This runs after the package loop on purpose — the file: deps resolve against
# $STAGE/packages, so a package that failed to build fails the deploy here,
# locally, rather than halfway through an install on the server.
echo "==> resolving dispatch dependency lock"
(cd "$STAGE/services/dispatch" && npm install --package-lock-only --omit=dev --no-audit --no-fund --silent)

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

# The customer site, same standalone shape as the portal.
cp -R apps/web/.next/standalone/. "$STAGE/apps/web/"
mkdir -p "$STAGE/apps/web/.next"
cp -R apps/web/.next/static "$STAGE/apps/web/.next/static"
[ -d apps/web/public ] && cp -R apps/web/public "$STAGE/apps/web/public"
if [ -f "$STAGE/apps/web/apps/web/server.js" ]; then
  cp -R "$STAGE/apps/web/apps/web/." "$STAGE/apps/web/"
  rm -rf "$STAGE/apps/web/apps"
fi

cp -R deploy "$STAGE/deploy"
cp -R supabase "$STAGE/supabase"
cp -R scripts "$STAGE/scripts"

# Two of these are production jobs — sweep.mjs (crease-sweep.service) and
# purge-events.mjs (weekly cron) — and they must keep shipping. The rest is
# laptop tooling, and the e2e/seed scripts are the dangerous half: run from
# /opt/crease they read the production service-role key out of the .env sitting
# right beside them and then create, cancel and re-book real orders. Nothing on
# the box invokes them; they were only ever there because this copied the whole
# directory. --delete removes the copies earlier deploys left behind.
rm -f "$STAGE"/scripts/e2e*.mjs \
      "$STAGE"/scripts/seed*.mjs \
      "$STAGE"/scripts/rls-check.mjs \
      "$STAGE"/scripts/ios-session.mjs \
      "$STAGE"/scripts/ios-test.sh \
      "$STAGE"/scripts/testflight.sh \
      "$STAGE"/scripts/marketing-shots.sh \
      "$STAGE"/scripts/upload-screenshots.py \
      "$STAGE"/scripts/asc.py \
      "$STAGE"/scripts/asc-metadata.py \
      "$STAGE"/scripts/asc-config.env*

echo "==> uploading"
ssh "$HOST" "mkdir -p $REMOTE /var/log/crease && chown $SERVICE_USER:adm /var/log/crease && chmod 750 /var/log/crease"
# --delete removes anything on the box that is not in the stage, so every
# credential that lives only on the droplet has to be named here or a deploy
# quietly destroys it. secrets/ holds the APNs .p8, which Apple issues exactly
# once and will not reissue.
#
# '.env' and '.env.local' match a basename exactly, so scripts/asc-config.env
# sailed straight past them and put the App Store Connect key and issuer IDs on
# a public-facing box that has no use for them. The globs cover every future
# *.env and any signing key that lands in the tree.
#
# apps/web/content/ is where the growth engine publishes: every guide page the
# site has ever had lives there and nowhere else — it is written on the box, is
# not in this repo, and cannot be rebuilt from it. Without this exclude a
# routine deploy silently deletes the entire published corpus.
rsync -az --delete \
  --exclude '.env' --exclude '.env.local' --exclude '*.env' --exclude '*.p8' \
  --exclude 'secrets/' --exclude 'apps/web/content/' \
  "$STAGE/" "$HOST:$REMOTE/"

# An rsync --exclude also protects the matching file on the receiver from
# --delete, so the asc-config.env already up there survives the rule that now
# keeps it from being sent. Remove it once, by name. (secrets/*.p8 is excluded
# as a directory above and is untouched by this.)
ssh "$HOST" "rm -f $REMOTE/scripts/asc-config.env"

# The health check below proves the service answers, not that it is running the
# code we just built — a partial rsync passes it too. Compare a checksum of the
# built artefacts on both sides before restarting anything.
echo "==> verifying upload"
LOCAL_SUM=$(cd "$STAGE" && find services/dispatch/dist packages -type f -name '*.js' -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
REMOTE_SUM=$(ssh "$HOST" "cd $REMOTE && find services/dispatch/dist packages -type f -name '*.js' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1")
if [ "$LOCAL_SUM" != "$REMOTE_SUM" ]; then
  echo "upload verification FAILED — staged and remote trees differ" >&2
  echo "  local  $LOCAL_SUM" >&2
  echo "  remote $REMOTE_SUM" >&2
  exit 1
fi
echo "    checksum ok (${LOCAL_SUM:0:12})"

echo "==> installing dispatch runtime deps"
# ci, not install: install would re-resolve the caret ranges on the box and
# accept whatever the registry served. --ignore-scripts because this runs as
# root — a postinstall in any of the 60-odd transitive packages would otherwise
# execute with that privilege on a droplet shared with six other sites.
ssh "$HOST" "cd $REMOTE/services/dispatch && npm ci --omit=dev --ignore-scripts --no-audit --no-fund --silent"

# scripts/ imports @supabase/supabase-js but sits outside the dispatch
# package, so give the deploy root a resolvable node_modules.
ssh "$HOST" "ln -sfn $REMOTE/services/dispatch/node_modules $REMOTE/node_modules"

# rsync/npm run over SSH as root, so the tree comes back root-owned. Hand it
# Code is root-owned and only group-readable by the service user, so a
# compromise of the webhook-facing dispatch process (which holds the
# service-role key) cannot rewrite its own binaries and persist across a restart
# or a timer run — ProtectSystem=full does not cover /opt, so this ownership
# split is what confines it. The service user owns only what it must write:
# Next's runtime cache, its secrets, and its env.
echo "==> ownership: code root-owned, secrets + runtime cache to $SERVICE_USER"
ssh "$HOST" "set -e
  chown -R root:$SERVICE_USER $REMOTE
  chmod -R u=rwX,g=rX,o= $REMOTE
  # Next writes its incremental cache here at runtime (revalidatePath); without
  # a writable subtree a root-owned code tree turns that into an EACCES.
  mkdir -p $REMOTE/apps/portal/.next/cache $REMOTE/apps/web/.next/cache
  chown -R $SERVICE_USER:$SERVICE_USER $REMOTE/apps/portal/.next/cache $REMOTE/apps/web/.next/cache
  if [ -d $REMOTE/secrets ]; then chown -R $SERVICE_USER:$SERVICE_USER $REMOTE/secrets; chmod 700 $REMOTE/secrets; fi
  for f in $REMOTE/services/dispatch/.env $REMOTE/apps/portal/.env.local $REMOTE/apps/web/.env.local; do
    if [ -f \"\$f\" ]; then chown $SERVICE_USER:$SERVICE_USER \"\$f\"; chmod 600 \"\$f\"; fi
  done"

echo "==> systemd"
# The sweep units ship here too. They were installed by hand once, which meant a
# rebuild from this repo would have come up without the reconciler — and this
# release deliberately relies on it: the Stripe ledger now settles on a failed
# dispatch so the provider stops retrying, and retryable create failures are
# parked for the sweep to release. Without the timer running, nothing retries.
scp -q deploy/crease-dispatch.service deploy/crease-portal.service deploy/crease-web.service \
      deploy/crease-sweep.service deploy/crease-sweep.timer \
      deploy/crease-purge.service deploy/crease-purge.timer "$HOST:/etc/systemd/system/"
ssh "$HOST" 'systemctl daemon-reload && systemctl enable --now crease-dispatch crease-portal crease-web && systemctl restart crease-dispatch crease-portal crease-web'
ssh "$HOST" 'systemctl enable --now crease-sweep.timer crease-purge.timer'
# The retention job ran from /etc/cron.d as root — the last thing still doing so
# after the move to an unprivileged service user. The timer above replaces it on
# the same weekly schedule; remove the cron entry so they can't both fire.
ssh "$HOST" 'rm -f /etc/cron.d/crease-purge-events'

echo "==> waiting for health"
ready=0
for i in $(seq 1 15); do
  if ssh "$HOST" 'curl -sf -m 3 http://127.0.0.1:8011/healthz >/dev/null'; then ready=1; break; fi
  sleep 2
done
[ "$ready" = 1 ] || echo "    dispatch still not answering after 30s — verifying anyway" >&2

# Assert, don't narrate. This step used to print the health body and the portal
# status code and exit 0 regardless, so a deploy that left both services broken
# ended with "==> done" and the operator walked away. Same checks the sibling
# deploy scripts make: a health body that says ok, and a portal that renders.
echo "==> verifying"
health="$(ssh "$HOST" 'curl -s -m 5 http://127.0.0.1:8011/healthz' || true)"
portal="$(ssh "$HOST" 'curl -s -o /dev/null -w "%{http_code}" -m 8 http://127.0.0.1:3010/login' || true)"
web="$(ssh "$HOST" 'curl -s -o /dev/null -w "%{http_code}" -m 10 http://127.0.0.1:3020/' || true)"
units="$(ssh "$HOST" 'systemctl is-active crease-dispatch crease-portal crease-web' || true)"
echo "    dispatch healthz -> ${health:-<no response>}"
echo "    portal /login    -> ${portal:-<no response>} (expect 200)"
echo "    web /            -> ${web:-<no response>} (expect 200)"
echo "    units            -> $(echo "$units" | tr '\n' ' ')"

echo "$health" | grep -q '"ok":true' || {
  echo "ERROR: dispatch is not healthy after restart — the new code is live and broken" >&2
  echo "  journalctl -u crease-dispatch -n 50 --no-pager" >&2
  exit 1
}
[ "$portal" = "200" ] || {
  echo "ERROR: portal /login returned '${portal:-<no response>}', expected 200" >&2
  echo "  journalctl -u crease-portal -n 50 --no-pager" >&2
  exit 1
}
[ "$web" = "200" ] || {
  echo "ERROR: the customer site returned '${web:-<no response>}', expected 200" >&2
  echo "  journalctl -u crease-web -n 50 --no-pager" >&2
  exit 1
}
echo "==> done"
