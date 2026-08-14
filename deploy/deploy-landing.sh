#!/usr/bin/env bash
# Deploy the usecreaseapp.com landing page (apps/landing) and its vhost.
#
# Safe to re-run at any stage:
#   - always syncs the static files
#   - before DNS resolves: installs the HTTP-only vhost (serves the page and
#     certbot's webroot challenge)
#   - once DNS points at the droplet: issues the cert and swaps in the TLS
#     vhost from nginx-landing.conf
#
#   CREASE_HOST=root@<ip> ./deploy/deploy-landing.sh
set -euo pipefail

# Not defaulted in a public repo: the box is shared with several unrelated
# production sites.
HOST="${CREASE_HOST:?set CREASE_HOST=root@your.server.ip}"
DOMAIN="usecreaseapp.com"
IP="${HOST##*@}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> syncing static files"
ssh "$HOST" "mkdir -p /var/www/usecreaseapp"
rsync -az --delete "$ROOT/apps/landing/" "$HOST:/var/www/usecreaseapp/"

have_cert() {
  ssh "$HOST" "test -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
}

dns_ok() {
  # Resolve via a public resolver so a stale local cache can't produce a
  # false positive; certbot's CA resolves from the outside too.
  [ "$(dig +short @1.1.1.1 "$DOMAIN" A | tail -1)" = "$IP" ] &&
  [ "$(dig +short @1.1.1.1 "www.$DOMAIN" A | tail -1)" = "$IP" ]
}

install_vhost() {
  scp -q "$ROOT/deploy/$1" "$HOST:/etc/nginx/sites-available/usecreaseapp"
  ssh "$HOST" 'ln -sf /etc/nginx/sites-available/usecreaseapp /etc/nginx/sites-enabled/usecreaseapp && nginx -t && systemctl reload nginx'
}

if ! have_cert; then
  if dns_ok; then
    echo "==> DNS resolves; issuing certificate"
    # The HTTP vhost must be live first so the webroot challenge is served.
    install_vhost nginx-landing-http.conf
    ssh "$HOST" "certbot certonly --webroot -w /var/www/html -d $DOMAIN -d www.$DOMAIN \
      --non-interactive --agree-tos -m divinejdavis@gmail.com --keep-until-expiring"
  else
    echo "==> DNS not pointing at $IP yet; installing HTTP-only vhost"
    install_vhost nginx-landing-http.conf
    echo "    re-run after the A record for $DOMAIN (and www CNAME) go live"
    exit 0
  fi
fi

echo "==> installing TLS vhost"
install_vhost nginx-landing.conf

echo "==> verifying"
# nginx -t passes on a config that is syntactically valid but semantically
# wrong, so check real URLs for real status codes.
code=$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/")
echo "    https://$DOMAIN/ -> $code"
www=$(curl -s -o /dev/null -w '%{http_code}' "https://www.$DOMAIN/")
echo "    https://www.$DOMAIN/ -> $www (expect 301)"
redirect=$(curl -s -o /dev/null -w '%{http_code}' "http://$DOMAIN/")
echo "    http -> $redirect (expect 301)"
[ "$code" = "200" ] || { echo "ERROR: landing page did not return 200" >&2; exit 1; }
echo "==> live at https://$DOMAIN"
