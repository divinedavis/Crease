#!/bin/bash
# Wrapper for the Crease growth cron.
#
# The daily review agent runs in Anthropic's cloud with only a git checkout —
# it cannot reach this droplet, read the database, or see the log. So git IS
# the channel between it and production: it pushes ledger and code changes,
# this pulls them in before each run and pushes the morning's measurements back
# out.
#
# Because git is the only channel, silence in git is the only symptom the agent
# ever sees, and silence has three very different causes: the cron never fired,
# it fired and crashed, or it ran fine and the push was lost. Those need three
# different fixes. So this appends a heartbeat record before it does anything
# else and again when it finishes, and commits that file whether or not the run
# succeeded. One invariant follows, and it is the whole point:
#
#   EVERY INVOCATION LEAVES A COMMIT.
#
# No commit for a morning therefore means the script did not run at all, and
# never means "it ran but stayed quiet".
set -uo pipefail
cd /root/Crease-growth || exit 1

# Secrets live here and only here — never in the repo, which is public.
# SMTP_*, ANTHROPIC_API_KEY, CREASE_INTERNAL_KEY, and SC_KEY_FILE once Search
# Console is connected.
set -a; . ./growth.env; set +a

# The site reads guides out of its own working directory. This is the one path
# that must match deploy/crease-web.service, and getting it wrong publishes
# pages nothing serves.
export CREASE_CONTENT_DIR="${CREASE_CONTENT_DIR:-/opt/crease/apps/web/content}"
export CREASE_PUBLIC_DIR="${CREASE_PUBLIC_DIR:-/opt/crease/apps/web/public}"

# The branch this checkout tracks. Not hardcoded to main: the repo's active
# line of work is a long-lived branch, and a wrapper that pushed to main would
# publish state the review agent never reads and quietly diverge from the code
# actually deployed. Override with GROWTH_BRANCH in growth.env.
BRANCH="${GROWTH_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}"

BEAT=growth/cron_heartbeat.jsonl
BEAT_KEEP=200          # ~200 days at one cron a day
JOB="${*:-daily}"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
head_sha() { git rev-parse --short HEAD 2>/dev/null || echo unknown; }

# Escape for a JSON string. Written in sed/tr rather than python because a
# heartbeat whose whole job is to report "python did not start" cannot need
# python in order to be written.
jesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'; }

# beat <phase> <rc> <pull-state> <note>
beat() {
  printf '{"at":"%s","job":"%s","phase":"%s","rc":%s,"pull":"%s","head":"%s","note":"%s"}\n' \
    "$(now)" "$(jesc "$JOB")" "$1" "${2:-null}" "$(jesc "$3")" "$(head_sha)" "$(jesc "${4:-}")" \
    >> "$BEAT" 2>/dev/null
}

# ---------------------------------------------------------------- the pull
#
# This runs FIRST and then re-execs, because the thing it pulls is this file.
#
# bash reads a script lazily and seeks back to the byte offset after the last
# command it ran. Rewriting the file mid-execution therefore does not load the
# new version — it resumes the OLD offset inside the NEW bytes, part-way
# through whatever statement now lives there. The first live run did exactly
# that: it pulled a two-line change to this script, then skipped its own commit
# step and pushed nothing, with no error printed anywhere. Re-execing after the
# pull is what makes "the engine updates itself" safe.
if [ -z "${GROWTH_PULLED:-}" ]; then
  beat start null pending ""

  # Take whatever the review agent pushed. --autostash so an uncommitted ledger
  # write from a previous run never blocks the pull.
  pull_state=ok
  git pull --rebase --autostash -q origin "$BRANCH" || {
    pull_state=failed
    echo "growth_run: git pull failed, running on the local copy"
  }

  # A failed pull can wedge every LATER run, not just this one: an autostash pop
  # that could not be replayed, or an interrupted rebase, writes conflict markers
  # into the working tree, and ledger.load_techniques() raises SystemExit on the
  # first '<<<<<<<' it reads. Nothing later in the day clears that, so recover
  # here. Ledger files are safe to take from origin — the droplet is their
  # only writer and pushes them every run, so origin is its own last-known-good
  # copy, and this run is about to regenerate them anyway.
  if [ -n "$(git ls-files -u 2>/dev/null)" ] || [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
    conflicted=$(git ls-files -u 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' ' ')
    git rebase --abort >/dev/null 2>&1
    git fetch -q origin "$BRANCH" >/dev/null 2>&1
    # shellcheck disable=SC2086 # deliberate word-splitting: one arg per path
    [ -n "$conflicted" ] && git checkout --force FETCH_HEAD -- $conflicted >/dev/null 2>&1
    pull_state="recovered"
    echo "growth_run: recovered a conflicted checkout (${conflicted:-mid-rebase}) from origin"
  fi


  GROWTH_PULLED="$pull_state" exec bash "$0" "$@"
fi
pull_state="$GROWTH_PULLED"

runlog=$(mktemp) || runlog=/tmp/crease_growth.$$.log
python3 growth_daily.py "$@" 2>&1 | tee "$runlog"
rc=${PIPESTATUS[0]}

# The tail of a failed run is what a cloud review needs to tell a crash from a
# quiet morning, and it is the one thing the droplet's own log never reaches
# it. Only on failure, and only two lines: this file is committed to a PUBLIC
# repo, and a successful run is already summarised in last_run.json.
note=""
if [ "$rc" -ne 0 ]; then
  note=$(grep -v '^[[:space:]]*$' "$runlog" | tail -n 2 | tr '\n' ' ' | cut -c1-300)
fi
rm -f "$runlog"
beat finish "$rc" "$pull_state" "$note"

# Trim the heartbeat so it cannot grow without bound.
if [ "$(wc -l < "$BEAT" 2>/dev/null || echo 0)" -gt "$BEAT_KEEP" ]; then
  tail -n "$BEAT_KEEP" "$BEAT" > "$BEAT.trim" && mv "$BEAT.trim" "$BEAT"
fi

# Publish. Only the files the review agent reads — never the whole tree, and
# never anything holding a secret or a visitor.
#
# growth/state.json is NOT here on purpose: it carries per-run scratch state
# and the API spend ledger, and snapshot.json republishes the parts of it that
# are safe. growth.env is gitignored and would be a live credential in a public
# repo.
# One at a time, and only what exists. `git add` fails the WHOLE invocation on
# a pathspec that matches nothing, so listing gsc_pages.json — which does not
# exist until Search Console is connected — silently staged nothing at all and
# the first run pushed no state whatsoever.
for f in growth/snapshot.json growth/techniques.json growth/keywords.json \
         growth/last_run.json growth/gsc_pages.json "$BEAT"; do
  [ -e "$f" ] && git add -- "$f"
done
if ! git diff --cached --quiet 2>/dev/null; then
  git -c user.name="crease-growth" -c user.email="divinejdavis@gmail.com" \
      commit -q -m "growth: $(date -u +%Y-%m-%d) run ($JOB, rc=$rc)"
fi
git push -q origin "HEAD:$BRANCH" || echo "growth_run: push failed — the review agent will see stale state"

exit "$rc"
