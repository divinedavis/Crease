#!/usr/bin/env bash
# Put Crease back the way a deploy/snapshot.sh snapshot found it.
#
#   CREASE_HOST=root@<ip> deploy/rollback.sh                    # list snapshots
#   CREASE_HOST=root@<ip> deploy/rollback.sh 20261001T1830Z     # restore one
#
# deploy.sh calls this on its own when anything fails after the upload
# starts. Restores the code tree (dispatch, packages, portal, web, scripts,
# deploy, supabase, node_modules) and the crease-* systemd units, then
# restarts the three services and runs deploy/health.sh. .env files,
# secrets/, apps/web/content/ and .next/cache/ are never touched (the
# excludes also protect them from --delete). If the restore changed nothing
# on disk, services are left running untouched.
set -euo pipefail
HOST="${CREASE_HOST:?set CREASE_HOST=root@your.server.ip}"
B=/var/backups/crease-app
TS="${1:-}"
if [ -z "$TS" ]; then ssh "$HOST" "ls -1 $B"; exit 0; fi
case "$TS" in *[!0-9TZ]*) echo "bad snapshot name: $TS" >&2; exit 2 ;; esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> restoring snapshot $TS"
changed="$(ssh "$HOST" "set -euo pipefail
  test -d $B/$TS/tree
  rsync -a --delete --itemize-changes \
    --exclude '.env' --exclude '.env.local' --exclude '*.env' --exclude '*.p8' \
    --exclude 'secrets/' --exclude 'apps/web/content/' --exclude '.next/cache/' \
    $B/$TS/tree/ /opt/crease/
  for f in $B/$TS/systemd/*; do
    cmp -s \"\$f\" /etc/systemd/system/\$(basename \"\$f\") || { cp -a \"\$f\" /etc/systemd/system/; echo \"unit \$(basename \"\$f\")\"; }
  done")"
if [ -n "$changed" ]; then
  echo "$changed" | head -20 | sed 's/^/    /'
  echo "    ($(echo "$changed" | wc -l | tr -d ' ') changes) restarting services"
  ssh "$HOST" 'systemctl daemon-reload && systemctl restart crease-dispatch crease-portal crease-web'
else
  echo "    live tree already matches the snapshot; services left running"
fi

echo "==> verifying restore"
ssh "$HOST" "cd /opt/crease && md5sum --quiet -c $B/$TS/MANIFEST.md5" \
  && echo "    md5 of every restored file matches the snapshot manifest" \
  || { echo "ROLLBACK INCOMPLETE: files differ from snapshot $TS" >&2; exit 1; }
CREASE_HOST="$HOST" "$ROOT/deploy/health.sh"
echo "==> rolled back to $TS"
