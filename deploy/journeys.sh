#!/usr/bin/env bash
# Run the live journey suite against production, the Find A Crib way: every
# journey, then the failures once more, and exit 1 if any still fail.
# deploy.sh runs this after deploy/health.sh and rolls back when it fails.
#
#   CREASE_HOST=root@<ip> deploy/journeys.sh
#
# There is no staging, so these drive real production over an SSH tunnel to
# the loopback-only dispatch API. They use the review/test account, whose
# orders go to the mock courier and never charge a live card (see
# scripts/e2e-confirm.mjs: the paid path is skipped when the server hands back
# pk_live). A health check proves pages render; this proves an order can still
# be booked, dispatched, cancelled and refunded.
#
# e2e-money and e2e-payouts are not here: they need the mock payment
# provider, which production does not run.
set -uo pipefail
HOST="${CREASE_HOST:?set CREASE_HOST=root@your.server.ip}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PORT="${CREASE_TUNNEL_PORT:-18011}"
LOGS="$(mktemp -d)"

: "${CREASE_TEST_PASSWORD:=$(security find-generic-password -s crease-test-password -w 2>/dev/null || true)}"
[ -n "$CREASE_TEST_PASSWORD" ] || { echo "journeys: set CREASE_TEST_PASSWORD (keychain crease-test-password)" >&2; exit 1; }
# Read from the box every run: the local .env copy went stale at the switch
# to live keys and the webhook journey 401'd against it.
STRIPE_WEBHOOK_SECRET="$(ssh "$HOST" 'grep ^STRIPE_WEBHOOK_SECRET= /opt/crease/services/dispatch/.env | cut -d= -f2-')"
export CREASE_ALLOW_PROD=1 CREASE_BASE="http://127.0.0.1:$PORT" CREASE_TEST_PASSWORD STRIPE_WEBHOOK_SECRET

ssh -f -N -o ExitOnForwardFailure=yes -L "$PORT:127.0.0.1:8011" "$HOST" \
  || { echo "journeys: could not open the tunnel on :$PORT" >&2; exit 1; }
cleanup() { pkill -f "$PORT:127.0.0.1:8011" 2>/dev/null; rm -rf "$LOGS"; }
trap cleanup EXIT

# e2e.mjs walks one order end to end, and an order can be walked only once, so
# every attempt seeds its own. Without an id it would grab the newest order,
# which is whatever the previous journey left behind.
run() {
  local name="$1" args=()
  if [ "$name" = e2e ]; then
    local oid
    oid="$(node scripts/seed.mjs 2>&1 | grep -o '"orderId":"[^"]*"' | cut -d'"' -f4)"
    [ -n "$oid" ] || { echo "seed produced no order" >"$LOGS/$name.log"; return 1; }
    args=("$oid")
  fi
  node "scripts/$name.mjs" "${args[@]+"${args[@]}"}" >"$LOGS/$name.log" 2>&1
}

# Seed first: the test customer is deleted between sessions and every journey
# signs in as it.
node scripts/seed.mjs >/dev/null 2>&1 || { echo "journeys: seed failed" >&2; exit 1; }

JOURNEYS=(e2e e2e-cancel e2e-confirm e2e-stripe-webhook e2e-service-area rls-check)
failed=()
for j in "${JOURNEYS[@]}"; do
  if run "$j"; then echo "    ok    $j"; else echo "    fail  $j (retrying once)"; failed+=("$j"); fi
done

still=()
for j in "${failed[@]+"${failed[@]}"}"; do
  if run "$j"; then echo "    ok    $j (on retry)"; else still+=("$j"); fi
done

if [ "${#still[@]}" -gt 0 ]; then
  for j in "${still[@]}"; do
    echo "    FAIL  $j" >&2
    tail -15 "$LOGS/$j.log" | sed 's/^/          /' >&2
  done
  echo "==> JOURNEYS FAILED: ${still[*]}" >&2
  exit 1
fi
echo "==> all ${#JOURNEYS[@]} journeys passed"
