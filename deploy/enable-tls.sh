#!/usr/bin/env bash
# Issue the certificate and swap the HTTP-only vhost for the TLS one.
#
# Run this AFTER the DNS A record for crease.divinedavis.com points at the
# droplet. Safe to re-run.
#
#   ./deploy/enable-tls.sh
set -euo pipefail

# Set CREASE_HOST=root@<ip>. Not defaulted in a public repo: the box is
# shared with several unrelated production sites.
HOST="${CREASE_HOST:?set CREASE_HOST=root@your.server.ip}"
DOMAIN="${CREASE_DOMAIN:-crease.divinedavis.com}"
IP="${HOST##*@}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> checking DNS"
RESOLVED="$(dig +short "$DOMAIN" A | tail -1)"
if [ -z "$RESOLVED" ]; then
  echo "ERROR: $DOMAIN does not resolve yet. Add an A record -> $IP and retry." >&2
  exit 1
fi
if [ "$RESOLVED" != "$IP" ]; then
  # Issuing against the wrong host silently produces a cert nginx cannot use.
  echo "ERROR: $DOMAIN resolves to $RESOLVED, expected $IP." >&2
  exit 1
fi
echo "    $DOMAIN -> $RESOLVED"

echo "==> issuing certificate"
ssh "$HOST" "certbot certonly --webroot -w /var/www/html -d $DOMAIN \
  --non-interactive --agree-tos -m divinejdavis@gmail.com --keep-until-expiring"

echo "==> installing TLS vhost"
scp -q "$ROOT/deploy/nginx-crease.conf" "$HOST:/etc/nginx/sites-available/crease"
ssh "$HOST" 'ln -sf /etc/nginx/sites-available/crease /etc/nginx/sites-enabled/crease && nginx -t && systemctl reload nginx'

echo "==> verifying over TLS"
# nginx -t passes on a config that is syntactically valid but semantically
# wrong, so check a real URL for a real status code.
code=$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/login")
echo "    https://$DOMAIN/login -> $code"
health=$(curl -s "https://$DOMAIN/healthz")
echo "    healthz -> $health"
redirect=$(curl -s -o /dev/null -w '%{http_code}' "http://$DOMAIN/login")
echo "    http redirect -> $redirect (expect 301)"

# The internal API must not be reachable from off-box.
api=$(curl -s -o /dev/null -w '%{http_code}' -X POST "https://$DOMAIN/v1/orders/x/dispatch-pickup")
echo "    /v1/ from internet -> $api (expect 403)"

[ "$code" = "200" ] || { echo "ERROR: portal did not return 200" >&2; exit 1; }
[ "$api" = "403" ]  || { echo "ERROR: internal API is exposed" >&2; exit 1; }
echo "==> TLS enabled"
