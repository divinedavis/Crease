#!/usr/bin/env bash
# Copy what is live in /opt/crease (and the systemd units deploy.sh installs)
# to /var/backups/crease-app/<UTC timestamp>/, keep the newest 15, and print
# the timestamp. deploy.sh takes one right before every upload;
# deploy/rollback.sh <timestamp> puts it back.
#
#   CREASE_HOST=root@<ip> deploy/snapshot.sh
#
# Not copied, because no deploy writes them and a backup is one more place a
# key could leak from: .env files, secrets/ (the APNs .p8), the growth
# engine's apps/web/content/, and Next's runtime .next/cache/.
# Unchanged files are hard links to the previous snapshot (--link-dest), so
# fifteen snapshots of the ~160 MB tree cost little more than one.
set -euo pipefail
HOST="${CREASE_HOST:?set CREASE_HOST=root@your.server.ip}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
ssh "$HOST" "set -euo pipefail
  B=/var/backups/crease-app
  mkdir -p \$B && chmod 700 \$B
  prev=\$(ls -1 \$B | grep -E '^[0-9]{8}T[0-9]{6}Z\$' | sort | tail -1 || true)
  link=''; [ -n \"\$prev\" ] && link=\"--link-dest=\$B/\$prev/tree\"
  mkdir -p \$B/$TS/systemd
  rsync -a \$link \
    --exclude '.env' --exclude '.env.local' --exclude '*.env' --exclude '*.p8' \
    --exclude 'secrets/' --exclude 'apps/web/content/' --exclude '.next/cache/' \
    /opt/crease/ \$B/$TS/tree/
  cp -a /etc/systemd/system/crease-*.service /etc/systemd/system/crease-*.timer \$B/$TS/systemd/
  (cd \$B/$TS/tree && find . -type f -print0 | sort -z | xargs -0 md5sum) > \$B/$TS/MANIFEST.md5
  ls -1 \$B | grep -E '^[0-9]{8}T[0-9]{6}Z\$' | sort | head -n -15 | while read -r old; do rm -rf \"\$B/\$old\"; done
" >&2
echo "$TS"
