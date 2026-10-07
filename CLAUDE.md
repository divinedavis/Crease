# Crease

## Deploy

- Production deploys ONLY from branch `pricing-route-aware`, from a clean tree:
  `CREASE_HOST=root@<droplet> ./deploy/deploy.sh`. `main` is an old ancestor;
  its deploy.sh wiped the customer site on 2026-09-05. Merge main INTO the
  branch, never the other way.
- Same deploy rules as Find A Crib (owner, 2026-10-07).
- deploy.sh: clean-tree check -> `scripts/test.sh` -> build -> `deploy/snapshot.sh`
  (live tree + systemd units to `/var/backups/crease-app/<ts>`, 15 kept) ->
  upload -> `deploy/health.sh` -> `deploy/journeys.sh` (the live journey
  suite over an SSH tunnel: e2e, cancel, confirm, stripe-webhook,
  service-area, rls-check; failures re-run once). Any failure after the
  snapshot runs `deploy/rollback.sh <ts>` and exits 1.
  `CREASE_SKIP_JOURNEYS=1` only for an emergency, said in the commit.
- `deploy/deploy-prospects.sh`: `scripts/test.sh --browser` -> snapshot to
  `/var/backups/crease-prospects/<ts>` (15 kept) -> copy -> checks -> restore
  on failure. Browser tests use `.venv` (playwright), created with
  `python3 -m venv .venv && .venv/bin/pip install playwright`.
- `deploy-landing.sh` and `deploy-app-domains.sh` are RETIRED (usecreaseapp.com
  301s to creasenyc.com); they refuse to run.
- Uptime: dhcr-map `monitoring/uptime_watch.py` watches creasenyc.com,
  portal /login, api /healthz and the crease.divinedavis.com alias.
- Manual rollback: `CREASE_HOST=... deploy/rollback.sh` lists snapshots,
  `deploy/rollback.sh <ts>` restores one, verifies md5s and health.
- iOS: TestFlight only (`scripts/testflight.sh`). Never
  attach a build to an App Store version or run `scripts/asc.py submit` unless
  the owner says so. `asc.py submit` adds a 7-day phased release for non-1.0.

## Tests

- One command: `scripts/test.sh` — refuses test files no runner reaches,
  typechecks every workspace, runs every node workspace's tests (each must
  report >0) and the `growth/` Python tests. `scripts/test.sh --browser` adds
  the canvass page tests (`scripts/canvass-test/*-test.py`, needs python
  playwright + chromium).
- Pre-push hook `.githooks/pre-push`: gitleaks over the pushed commits +
  `scripts/test.sh`. Enable once per checkout/worktree with
  `scripts/install_hooks.sh`. Bypass only with `--no-verify` and say why.
- CI (`.github/workflows/ci.yml`, every push and PR): gitleaks, `scripts/test.sh`,
  npm audit. `canvass.yml` runs the browser tests when the canvass page or its
  tests change. ubuntu runners only; no secrets go to GitHub.
- Not automated (need prod credentials or Xcode): `scripts/e2e*.mjs` and
  `rls-check.mjs` run against production over an SSH tunnel; `scripts/ios-test.sh`
  runs the XCUITests on a simulator.
- iOS quality gates (owner, 2026-10-03): `scripts/testflight.sh` runs
  `scripts/ios-gates.sh` before every upload — Swift Testing + XCTest + every
  XCUITest incl. `AccessibilityAuditTests` (light AND dark), the
  `ios-coverage-gate.py` check that every `Features/` file is executed by a
  test, `PerformanceTests` judged by `ios-perf-gate.py` (fail > 1.5x the median
  of the last 5 ships, baseline `apps/ios/perf_baseline.json`), MetricKit wiring,
  and the Xcode Organizer report. A new screen needs a UI test that opens it.
  `CREASE_SKIP_GATES=1` only for an emergency, said in the commit.
- **Every change adds, updates AND deletes tests in the same commit.** New
  behavior gets a test, changed behavior updates its test, removed behavior
  deletes its test (no dead tests). Say which in the commit body
  (`Tests: ...`), alongside the `XCUITest review:` and `OWASP LLM:` lines.

## App Store freeze
`ASC_FREEZE` at the repo root = TestFlight only (owner, 2026-09-22). `scripts/asc.py` refuses `setup`, `attach` and `submit` while it exists. Delete it only on the owner's explicit word.
