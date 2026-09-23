#!/usr/bin/env bash
# tests/test-runner.sh — plain shell job runner for tests/*.sh. Replaces the old per-scenario
# subagent dispatch: a self-contained scenario script's own pass/fail is 100% deterministic
# (check()'s own comparison), so grading it is a job for a job runner, not an agent. This file
# is itself bash 3.2-compatible (no `wait -n`, `declare -A`, `${var,,}`, `mapfile`, namerefs) —
# it is a shell script under test the same way every tests/*.sh is, not exempt because it
# orchestrates rather than asserts.
set -uo pipefail

RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$RUNNER_DIR/.." && pwd -P)"

CAP=8            # concurrency cap: at most this many tests/*.sh processes at once
export KAIZERO_TEST_MODE="${KAIZERO_TEST_MODE:-report}"

# --- scenario list: the named subset, or every tests/*.sh -----------------------------------
ALL_SCRIPTS=()
if [ "$#" -gt 0 ]; then
  for key in "$@"; do ALL_SCRIPTS+=("$RUNNER_DIR/$key.sh"); done
else
  for f in "$RUNNER_DIR"/*.sh; do
    base="$(basename "$f")"
    case "$base" in test-setup.sh|test-teardown-reap.sh|test-teardown-delete.sh|test-runner.sh) continue ;; esac
    ALL_SCRIPTS+=("$f")
  done
fi

# split on each scenario's own `# KAIZERO_TEST_ISOLATED=1` marker (same convention as
# KAIZERO_NEEDS_REAL_CLAUDE): a scenario that raced its own background helper against its main
# process under concurrent CPU contention (confirmed empirically, not a shared-file collision —
# every scenario's $TU is already unique) self-marks here. SCRIPTS runs at the concurrency cap
# below; ISOLATED_SCRIPTS runs one at a time afterward, once nothing else is competing for CPU.
SCRIPTS=(); ISOLATED_SCRIPTS=()
for f in "${ALL_SCRIPTS[@]}"; do
  if grep -q '^# KAIZERO_TEST_ISOLATED=1' "$f" 2>/dev/null; then
    ISOLATED_SCRIPTS+=("$f")
  else
    SCRIPTS+=("$f")
  fi
done
N="${#SCRIPTS[@]}"
N_ISOLATED="${#ISOLATED_SCRIPTS[@]}"

RESULTS="$(mktemp "${TMPDIR:-/tmp}/kaizero-runner-results.XXXXXX")"
: > "$RESULTS"

# --- residue check: same commands as TEST.md's old "Project-repo residue check" section,
# now real code instead of markdown fences a reader had to transcribe correctly. Diffed against
# the baseline, never checked for zero on its own — this repo is dogfooded and its own .git
# legitimately carries worktrees/branches with no test running at all.
# literal grep-over-ls check, unchanged from TEST.md's own pre-conversion residue check
# shellcheck disable=SC2010
residue_snapshot(){
  ( cd "$REPO" || exit 1
    git worktree list | tail -n +2
    git branch --list '*-task-*'
    ls .git 2>/dev/null | grep '^todos-seconds-\|^todos-done-\|^transcripts-\|^zero.sh$\|^instance$' || true
    git rev-parse HEAD )
}

baseline_residue_pass(){
  BASELINE="$(mktemp "${TMPDIR:-/tmp}/kaizero-baseline.XXXXXX")"
  residue_snapshot > "$BASELINE"
}

residue_pass(){
  AFTER="$(mktemp "${TMPDIR:-/tmp}/kaizero-after.XXXXXX")"
  residue_snapshot > "$AFTER"
  echo "new residue (worktrees/branches/stray files, want none):"
  sed '$d' "$AFTER" | grep -vFxf <(sed '$d' "$BASELINE") || echo none
  BASE_HEAD="$(tail -1 "$BASELINE")"; AFTER_HEAD="$(tail -1 "$AFTER")"
  if [ "$BASE_HEAD" = "$AFTER_HEAD" ]; then
    echo "new commits in project repo (want none): none"
  else
    echo "new commits in project repo (want none):"
    ( cd "$REPO" && git log --oneline "$BASE_HEAD..$AFTER_HEAD" )
  fi
  ( cd "$REPO" && git status --porcelain )
}

# --- one background job per scenario. Each writes its own stdout to a per-scenario log under
# a runner-owned scratch dir. run_one — not the scenario script itself — appends the one
# "<key> <status>" line to $RESULTS, deliberately: a scenario killed by `timeout` never reaches
# its own trailing teardown/exit lines, so a scenario-side append would leave that key permanently
# missing from the tally (the completion count would never reach N). Reading the exit status from
# outside, after `timeout` returns either way, is what makes a hung scenario still show up as
# ERROR instead of silently stalling the whole run. Concurrent single-line appends stay atomic
# under PIPE_BUF, so no lock is needed.
RUNS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kaizero-runner-runs.XXXXXX")"

run_one(){
  local script="$1" key budget
  key="$(basename "$script" .sh)"
  budget="$(grep -m1 '^# KAIZERO_WALLCLOCK_BUDGET=' "$script" | sed 's/^# KAIZERO_WALLCLOCK_BUDGET=//')"
  budget="${budget:-90s}"
  timeout "$budget" bash "$script" > "$RUNS_DIR/$key.log" 2>&1
  status=$?
  # every scenario's own trailing line exits 0 (pass), 1 (FAIL, no ERROR) or 2 (ERROR) — see
  # tests/*.sh's final line. `timeout` killing a hung script (124), or anything else unexpected,
  # never reached that line at all, so both are ERROR too: a scenario that didn't finish is
  # exactly as worth an implementor's inspection as one that did and hit a guard refusal.
  case "$status" in
    0) verdict=PASS ;;
    1) verdict=FAIL ;;
    *) verdict=ERROR ;;
  esac
  printf '%s %s\n' "$key" "$verdict" >> "$RESULTS"
}

baseline_residue_pass

running_pids=""       # space-separated pid list of jobs currently in flight
printed=0

# reaps dead pids, then prints the surviving running_pids count
count_running(){
  local n=0 pid alive=""
  for pid in $running_pids; do
    if kill -0 "$pid" 2>/dev/null; then n=$((n + 1)); alive="$alive $pid"; fi
  done
  running_pids="$alive"
  echo "$n"
}

print_tally(){
  local n_done
  n_done="$(wc -l < "$RESULTS" | tr -d ' ')"
  while [ "$printed" -lt "$n_done" ]; do
    printed=$((printed + 1))
    sed -n "${printed}p" "$RESULTS" | while IFS=' ' read -r k v; do
      echo "$printed/$N done ($k: $v)"
    done
  done
}

pending=("${SCRIPTS[@]}")
while [ "${#pending[@]}" -gt 0 ] || [ "$(count_running)" -gt 0 ]; do
  # refill freed slots — rolling window, not batching: scan the whole pending list and launch
  # every script the cap allows right now, not stopping at the first one that's blocked (a
  # blocked real-claude script must not stall scripts behind it that don't need one).
  still_pending=()
  for next in "${pending[@]}"; do
    if [ "$(count_running)" -lt "$CAP" ]; then
      run_one "$next" &
      newpid=$!
      running_pids="$running_pids $newpid"
    else
      still_pending+=("$next")
    fi
  done
  pending=("${still_pending[@]}")
  sleep 0.5
  count_running >/dev/null   # reap finished pids before the next poll
  print_tally
done
print_tally

# --- isolated scenarios: one at a time, only after every concurrent one has returned, so nothing
# else is competing for CPU during a run whose own pass/fail depends on real-time scheduling order
# between a background helper and its main process (see TEST.md Dispatch instruction).
if [ "$N_ISOLATED" -gt 0 ]; then
  echo
  echo "isolated scenarios (sequential, $N_ISOLATED total):"
  iso_done=0
  for script in "${ISOLATED_SCRIPTS[@]}"; do
    run_one "$script"
    iso_done=$((iso_done + 1))
    key="$(basename "$script" .sh)"
    verdict="$(tail -1 "$RESULTS" | awk -v k="$key" '$1==k{print $2}')"
    echo "$iso_done/$N_ISOLATED isolated done ($key: $verdict)"
  done
fi

echo
residue_pass

fail_or_error=0
while IFS=' ' read -r k v; do
  [ "$v" = PASS ] || fail_or_error=1
done < "$RESULTS"

echo
echo "logs and residue kept at: $RUNS_DIR"
[ "$fail_or_error" -eq 0 ]
