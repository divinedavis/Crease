# Crease

## Deploy

- Production deploys ONLY from branch `pricing-route-aware`, from a clean tree:
  `CREASE_HOST=root@<droplet> ./deploy/deploy.sh`. `main` is an old ancestor;
  its deploy.sh wiped the customer site on 2026-09-05. Merge main INTO the
  branch, never the other way.
- deploy.sh: clean-tree check -> `scripts/test.sh` -> build -> `deploy/snapshot.sh`
  (live tree + systemd units to `/var/backups/crease-app/<ts>`, 15 kept) ->
  upload -> `deploy/health.sh`. Any failure after the snapshot runs
  `deploy/rollback.sh <ts>` and exits 1.
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
- **Every change adds, updates AND deletes tests in the same commit.** New
  behavior gets a test, changed behavior updates its test, removed behavior
  deletes its test (no dead tests). Say which in the commit body
  (`Tests: ...`), alongside the `XCUITest review:` and `OWASP LLM:` lines.
