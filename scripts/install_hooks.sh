#!/usr/bin/env bash
# Point git at the versioned hooks in .githooks/ (pre-push: gitleaks over the
# pushed commits + scripts/test.sh). Run once per checkout, worktree included,
# and on the droplet's /root/Crease-growth checkout if it ever pushes again.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
echo "hooks installed: $(ls .githooks | tr '\n' ' ')"
