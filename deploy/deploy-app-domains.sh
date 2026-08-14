#!/usr/bin/env bash
# Bring up portal.usecreaseapp.com + api.usecreaseapp.com and repoint the
# dispatch service's public URL at the branded API host.
#
# Order matters: the vhost's port-80 block must be live before certbot runs so
# the webroot challenge for the two new names can be served; the 443 block
# briefly presents the old 2-SAN cert until the expand completes, which is
# harmless because nothing links to these hosts yet.
#
# Safe to re-run. Leaves crease.divinedavis.com fully working as an alias for
# iOS builds in the field.
#
#   CREASE_HOST=root@<ip> ./deploy/deploy-app-domains.sh
set -euo pipefail

HOST="${CREASE_HOST:?set CREASE_HOST=root@your.server.ip}"
IP="${HOST##*@}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMES=(usecreaseapp.com www.usecreaseapp.com portal.usecreaseapp.com api.usecreaseapp.com)

echo "==> checking DNS"
for d in portal.usecreaseapp.com api.usecreaseapp.com; do
  resolved="$(dig +short @1.1.1.1 "$d" A | tail -1)"
  if [ "$resolved" != "$IP" ]; then
    echo "ERROR: $d resolves to '$resolved', expected $IP." >&2
    exit 1
  fi
  echo "    $d -> $resolved"
done

echo "==> installing vhost"
scp -q "$ROOT/deploy/nginx-app-domains.conf" "$HOST:/etc/nginx/sites-available/crease-app-domains"
ssh "$HOST" 'ln -sf /etc/nginx/sites-available/crease-app-domains /etc/nginx/sites-enabled/crease-app-domains && nginx -t && systemctl reload nginx'

echo "==> expanding certificate to cover portal + api"
domain_args=""
for d in "${NAMES[@]}"; do domain_args="$domain_args -d $d"; done
ssh "$HOST" "certbot certonly --webroot -w /var/www/html $domain_args \
  --cert-name usecreaseapp.com --expand \
  --non-interactive --agree-tos -m divinejdavis@gmail.com --keep-until-expiring"
ssh "$HOST" 'nginx -t && systemctl reload nginx'

echo "==> repointing dispatch PUBLIC_URL"
ssh "$HOST" "sed -i \
  -e 's|^PUBLIC_URL=.*|PUBLIC_URL=https://api.usecreaseapp.com|' \
  -e 's|^MOCK_WEBHOOK_URL=.*|MOCK_WEBHOOK_URL=https://api.usecreaseapp.com/webhooks/mock|' \
  /root/crease/services/dispatch/.env && systemctl restart crease-dispatch"

echo "==> verifying"
sleep 2
health=$(curl -s "https://api.usecreaseapp.com/healthz")
echo "    api healthz -> $health"
portal=$(curl -s -o /dev/null -w '%{http_code}' "https://portal.usecreaseapp.com/login")
echo "    portal /login -> $portal (expect 200)"
api403=$(curl -s -o /dev/null -w '%{http_code}' -X POST "https://api.usecreaseapp.com/v1/orders/x/dispatch-pickup")
echo "    /v1/ from internet -> $api403 (expect 403)"
probe=$(curl -s -o /dev/null -w '%{http_code}' "https://api.usecreaseapp.com/")
echo "    api / -> $probe (expect 404)"
old=$(curl -s -o /dev/null -w '%{http_code}' "https://crease.divinedavis.com/login")
echo "    old-domain alias /login -> $old (expect 200)"

[ "$portal" = "200" ] || { echo "ERROR: portal did not return 200" >&2; exit 1; }
[ "$api403" = "403" ] || { echo "ERROR: internal API is exposed" >&2; exit 1; }
[ "$old" = "200" ]    || { echo "ERROR: old-domain alias broken" >&2; exit 1; }
echo "$health" | grep -q '"ok":true' || { echo "ERROR: dispatch unhealthy after restart" >&2; exit 1; }
echo "==> portal.usecreaseapp.com + api.usecreaseapp.com live"
