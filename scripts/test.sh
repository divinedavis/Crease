#!/usr/bin/env bash
# Every fast automated test in the repo, one command. The pre-push hook and CI
# both run exactly this.
#
#   scripts/test.sh             # typecheck + unit tests (~15s)
#   scripts/test.sh --browser   # + the canvass page browser tests (needs
#                               #   python playwright + chromium, ~70s)
#
# What is NOT here, and why:
#   - scripts/e2e*.mjs, rls-check.mjs: run against PRODUCTION over an SSH
#     tunnel with keychain secrets (see the journey-suite notes in CLAUDE.md).
#   - apps/ios CreaseTests / CreaseUITests: need Xcode + a simulator (and the
#     UI suite a minted session); run scripts/ios-test.sh on the Mac.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BROWSER=0
[ "${1:-}" = "--browser" ] && BROWSER=1
# The repo's own venv when there is one (it carries playwright for --browser,
# which the deploy-prospects gate needs); otherwise whatever python3 is.
DEFAULT_PY=python3
[ -x "$ROOT/.venv/bin/python" ] && DEFAULT_PY="$ROOT/.venv/bin/python"
PY="${CREASE_PYTHON:-$DEFAULT_PY}"
step() { printf '==> %s\n' "$*"; }

# A test file no runner picks up is a test that silently never runs. Each
# workspace's `npm test` globs one directory; anything outside these patterns
# would be skipped without a word, so refuse instead.
step "every test file is reached by a runner"
orphans="$(git ls-files | grep -E '\.test\.(ts|tsx|js|mjs)$|(^|/)test_[^/]*\.py$|_test\.py$' \
  | grep -vE '^packages/[^/]+/src/[^/]+\.test\.ts$|^services/dispatch/src/.+\.test\.ts$|^apps/(portal|web)/lib/[^/]+\.test\.ts$|^growth/test_[^/]+\.py$' || true)"
if [ -n "$orphans" ]; then
  echo "these test files are not run by any runner — move them or widen the runner:" >&2
  echo "$orphans" >&2
  exit 1
fi

# tsc never deletes output, so a test removed from src/ keeps running from a
# stale dist/ on every machine that built it before. Clear compiled tests
# first so only the tests that exist in src/ run.
step "typecheck + build (packages, dispatch) and typecheck (portal, web)"
find packages/*/dist services/dispatch/dist -name '*.test.js*' -delete 2>/dev/null || true
for pkg in packages/*/; do
  [ -f "$pkg/tsconfig.json" ] && npx tsc -p "$pkg/tsconfig.json"
done
npx tsc -p services/dispatch/tsconfig.json
npx tsc --noEmit -p apps/portal/tsconfig.json
npx tsc --noEmit -p apps/web/tsconfig.json

LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
run() {  # run "<label>" cmd... — quiet on success, full output on failure
  local label="$1"; shift
  if "$@" >"$LOG" 2>&1; then return 0; fi
  cat "$LOG"; echo "FAILED: $label — run: $*" >&2; exit 1
}

step "node unit tests (every workspace)"
run "node unit tests" npm test --workspaces --if-present
# Node 23+ prints a spec summary ("ℹ tests 4"); Node 22 off a TTY prints TAP
# ("# tests 4"). Count both, and treat zero as a failure: a glob that matches
# nothing passes `node --test` without running a single test.
counts="$(awk '/^(ℹ|#) tests [0-9]/{t+=$3} /^(ℹ|#) pass [0-9]/{p+=$3} END{print t+0, p+0}' "$LOG")"
echo "    ${counts% *} tests, ${counts#* } passed"
suites="$(grep -cE '^(ℹ|#) tests [0-9]' "$LOG" || true)"
workspaces="$(grep -c '"test":' packages/*/package.json services/*/package.json apps/portal/package.json apps/web/package.json | awk -F: '{s+=$2} END{print s}')"
if [ "$suites" != "$workspaces" ] || grep -qE '^(ℹ|#) tests 0$' "$LOG"; then
  cat "$LOG"; echo "FAILED: expected $workspaces workspaces each running >0 tests, saw $suites summaries (or one ran 0)" >&2; exit 1
fi

step "python unit tests (growth/)"
run "python unit tests" "$PY" -m unittest discover -s growth -p 'test_*.py' -t .
grep -E '^Ran ' "$LOG" | sed 's/^/    /'

if [ "$BROWSER" = 1 ]; then
  step "canvass page browser tests (playwright, stubbed Supabase, no network)"
  for t in scripts/canvass-test/*-test.py; do
    run "$t" "$PY" "$t"
    echo "    $(basename "$t"): $(grep -c '^PASS' "$LOG") checks passed"
  done
else
  echo "==> skipped: canvass browser tests (scripts/test.sh --browser)"
fi
echo "==> all tests passed"
