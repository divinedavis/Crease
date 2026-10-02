#!/usr/bin/env bash
# Is Crease up and serving the real thing? Exit 0 only if every check passes.
# deploy.sh runs this after a copy (and rolls back when it fails);
# rollback.sh runs it after a restore.
#
#   CREASE_HOST=root@<ip> deploy/health.sh
#
# A 200 is not enough: a Next standalone build that lost its static/ dir, or
# a portal that renders an error page, both answer 200. So each check looks
# for content only the working page has.
set -uo pipefail
HOST="${CREASE_HOST:?set CREASE_HOST=root@your.server.ip}"
fail=0
ok()  { printf '    ok    %s\n' "$*"; }
bad() { printf '    FAIL  %s\n' "$*" >&2; fail=1; }

# Services come back over a few seconds; wait for dispatch before judging.
for _ in $(seq 1 15); do
  ssh "$HOST" 'curl -sf -m 3 http://127.0.0.1:8011/healthz >/dev/null' && break
  sleep 2
done

units="$(ssh "$HOST" 'systemctl is-active crease-dispatch crease-portal crease-web' 2>/dev/null | tr '\n' ' ')"
[ "$units" = "active active active " ] && ok "units: $units" || bad "units: ${units:-<no answer>} (want all active)"

health="$(ssh "$HOST" 'curl -s -m 5 http://127.0.0.1:8011/healthz' || true)"
case "$health" in *'"ok":true'*'"payments":"stripe"'*) ok "dispatch /healthz ok, payments=stripe" ;;
  *) bad "dispatch /healthz -> ${health:-<no response>}" ;; esac

portal="$(ssh "$HOST" 'curl -s -m 8 http://127.0.0.1:3010/login' || true)"
if printf '%s' "$portal" | grep -q '<title>Crease — cleaner portal</title>' && printf '%s' "$portal" | grep -q 'type="password"'; then
  ok "portal /login renders the sign-in form"
else bad "portal /login is missing its title or password field"; fi

web="$(curl -s -m 10 https://creasenyc.com/ || true)"
if printf '%s' "$web" | grep -q '<title>Crease: Laundry'; then ok "creasenyc.com / has the Crease title"
else bad "creasenyc.com / is missing the Crease title"; fi

# One of the page's own JS chunks must load, or the page is a dead shell.
chunk="$(printf '%s' "$web" | grep -oE '/_next/static/[^"]+\.js' | head -1)"
if [ -n "$chunk" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://creasenyc.com$chunk")" = 200 ]; then
  ok "creasenyc.com static chunk loads"
else bad "creasenyc.com static chunk ${chunk:-<none found>} does not load"; fi

for u in https://portal.creasenyc.com/login https://api.creasenyc.com/healthz; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$u" || true)"
  [ "$code" = 200 ] && ok "$u 200" || bad "$u -> ${code:-<none>}"
done

[ "$fail" = 0 ] && echo "==> healthy" || echo "==> UNHEALTHY" >&2
exit "$fail"
