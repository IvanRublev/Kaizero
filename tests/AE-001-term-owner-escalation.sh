#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=47s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# AE-001-term-owner-escalation — term_owner's ordinary safe-to-exit kill gets the same
# TERM -> grace -> KILL escalation arm_watchdog already has: a SIGTERM-ignoring session is still
# gone within WATCHDOG_GRACE seconds, a session that obeys the first TERM is not made to wait out
# the grace window or receive a KILL, the escalation re-validates the recorded session identity
# before its KILL, and KAIZERO_EXIT_REASON still receives its value exactly once, before the
# first signal.
# Needs real claude: no — a disposable sleep/bash stub, driven directly against the real emitted
# compact-exit-hook.sh, stands in for the session (BUG 057's driver pattern, same as
# tests/Q-001-context-rot-guard.sh).
# Tools beyond the shared prerequisites: none.
# Folder under $TESTROOT: $TESTROOT/AE-001-term-owner-escalation
# Wall-clock budget: its longest Run command sleeps up to WATCHDOG_GRACE (10s) plus a small
# margin — allow at least 30s for the whole case.
#
# BUG 039s: a bare `kill_tree TERM "$pid"` with no retry never ends a session that ignores the
# signal. This scenario drives the real emitted hook's term_owner on the ordinary
# KAIZERO_SAFE_TO_EXIT path (not the context-rot guard, which tests/Q-001-context-rot-guard.sh
# already covers) against both a deaf stub and an obedient one.
#
# BUG 058k: term_owner's target is now terminator.sh's WRAPPER_PID, and terminator.sh's TERM step
# (kill_tree_descendants) never signals that pid directly — only its descendants, exactly like the
# real wrapper/claude relationship (claude runs as a child of the pty-holding `script`). So each
# stub below is a two-process WRAPPER/CHILD pair, not one process standing in for both: the
# session record names the WRAPPER's pid, and the CHILD is where TERM actually lands. The WRAPPER
# `wait`s on its CHILD and exits the instant the CHILD does (mirroring `script` exiting once its
# own child exits) — that self-exit is what lets terminator.sh's early-bail-on-death poll (added by
# this same fix) notice a TERM-obedient session is already gone well inside WATCHDOG_GRACE.

# Setup
TAE="$TESTROOT/AE-001-term-owner-escalation"; mkdir -p "$TAE/repo"
cd "$TAE/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] AE1 x\n' > todo.md; git add -A; git commit -qm init
KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1   # writes the real emitted hook, no claude needed
HOOK="$TAE/repo/.git/compact-exit-hook.sh"

# BUG 057 driver pattern (own_session, same shape as Q-001-context-rot-guard.sh's run_hook): a
# session record naming a disposable WRAPPER stub's pid, KAIZERO_SAFE_TO_EXIT non-empty so the
# hook's ordinary turn-end branch is the one that fires (not the context-rot guard), and its own
# KAIZERO_EXIT_REASON file so the "written exactly once, before the first signal" claim is
# checkable. $1 = the CHILD's command (the claude stand-in TERM must actually reach). The WRAPPER
# launches that child, waits on it, and exits the moment it does — same as real `script`. Prints
# the wrapper's pid, the elapsed wall time of the hook call, and whether the wrapper is still
# alive afterward — everything each case below needs.
# the child must be launched INSIDE the wrapper's own subshell (so `wait` targets a real child
# of that shell, not a pid it never forked) — one bash -c body backgrounds the child, records its
# pid to $3 for the caller to read, then waits on it and exits the moment it does, same as real
# `script` exiting once its own child (claude) exits.
run_term_owner(){ local child_cmd="$1" tag="$2"
  local childpidfile="$TAE/childpid-$tag"
  bash -c 'bash -c "$1" & echo $! > "$2"; wait' _ "$child_cmd" "$childpidfile" \
    > "$TAE/wrapper-$tag.out" 2>&1 &
  local wrapper=$!
  local i=0; while [ ! -s "$childpidfile" ] && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i+1)); done
  local child; child="$(cat "$childpidfile" 2>/dev/null)"
  # the pidfile only proves the child process forked, not that its own `trap` line (first
  # statement in child_cmd) has actually run yet — firing the hook's TERM before that installs
  # can let a "TERM-ignoring" child die on the first TERM anyway, or race an "obedient" child's
  # own trap-logging. Each call site touches "$TAE/ready-$tag" itself right after its trap
  # statement; wait for it here too, same readiness-barrier fix as K1/K5.
  local readyfile="$TAE/ready-$tag"
  i=0; while [ ! -f "$readyfile" ] && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i+1)); done
  local rec="$TAE/rec-$tag" st safe="$TAE/safe-$tag" reason="$TAE/reason-$tag" log="$TAE/log-$tag"
  st="$(ps -o lstart= -p "$wrapper" 2>/dev/null | awk '{$1=$1;print}')"
  printf '%s\n%s\n%s\n' "$wrapper" "$st" 1 > "$rec"
  printf 'x\n' > "$safe"
  local t0 t1
  t0=$(date +%s)
  # BUG 058k: term_owner's own foreground call to terminator.sh returns fast (validate, then fork
  # the actual sequence into the background) — the hook call below returning is dispatch, not
  # completion. Poll the wrapper's own liveness (the same event kaizero.sh's own `wait` uses)
  # up to WATCHDOG_GRACE(10)+margin instead of trusting the hook call's own wall time.
  KAIZERO_INSTANCE=AE001 KAIZERO_SESSION_RECORD="$rec" KAIZERO_SESSION_EPOCH=1 \
    KAIZERO_SAFE_TO_EXIT="$safe" KAIZERO_EXIT_REASON="$reason" \
    bash -c 'printf "%s" "{}" | bash "$1" >/dev/null 2>&1' _ "$HOOK" > "$log" 2>&1
  local j=0; while kill -0 "$wrapper" 2>/dev/null && [ "$j" -lt 150 ]; do sleep 0.1; j=$((j+1)); done
  t1=$(date +%s)
  echo "WRAPPER=$wrapper CHILD=$child ELAPSED=$((t1 - t0)) REASON=$(cat "$reason" 2>/dev/null)"
  if kill -0 "$wrapper" 2>/dev/null; then
    kill -KILL "$wrapper" "$child" 2>/dev/null; wait "$wrapper" 2>/dev/null
    echo "ALIVE=1"
  else
    wait "$wrapper" 2>/dev/null
    echo "ALIVE=0"
  fi
}

# AE1 — a SIGTERM-ignoring claude (a descendant of the wrapper) is still gone within
# WATCHDOG_GRACE seconds, and the wrapper (never itself sent TERM) goes with it via the sequence's
# final KILL
cd "$TAE/repo"
OUT="$(run_term_owner 'trap "" TERM; : > "'"$TAE"'/ready-deaf"; echo deaf > "'"$TAE"'/deaf.started"; sleep 1000' deaf)"
echo "$OUT"
ALIVE=$(printf '%s\n' "$OUT" | sed -n 's/^ALIVE=//p')
ELAPSED=$(printf '%s\n' "$OUT" | sed -n 's/.*ELAPSED=\([0-9]*\).*/\1/p')
REASON=$(printf '%s\n' "$OUT" | sed -n 's/.*REASON=\(.*\)/\1/p')
# the deaf child actually ran
check "AE1 started" "$([ -f "$TAE/deaf.started" ] && echo 1 || echo 0)" "1"
# wrapper dead, not merely signalled
check "AE1 gone" "$([ "$ALIVE" = "0" ] && echo yes || echo no)" "yes"
# WATCHDOG_GRACE=10 plus a small margin, not instant and not stuck
check "AE1 within grace+margin" "$([ "$ELAPSED" -ge 9 ] && [ "$ELAPSED" -le 15 ] && echo yes || echo "no ($ELAPSED)")" "yes"
# ignoring TERM meant the wrapper never self-exited, so the recheck still found it live and
# escalated — the KILL-code variant of the ordinary safe-to-exit value
check "AE1 reason" "$REASON" "0 (killed)"
# AE1 PASS — started = 1, gone = yes, within grace+margin = yes, reason = '0 (killed)'.

# AE2 — a claude that dies from the first TERM takes its wrapper down with it (the wrapper exits
# the instant its `wait` returns, same as real `script`), so term_owner is not made to wait out
# the grace window, and no KILL is ever sent to either of them
cd "$TAE/repo"
# a trap that LOGS the signal it received and then lets the default action end the process — bash
# runs the trap handler and then still terminates on TERM/an untrapped-equivalent exit, so this
# both proves the death was caused by TERM (the log line) and never receives a KILL (SIGKILL
# cannot be trapped or logged at all — its absence from the log is the whole proof).
OUT="$(run_term_owner 'trap '"'"'echo TERM >> "'"$TAE"'/obedient.sig"; exit 143'"'"' TERM; : > "'"$TAE"'/ready-obedient"; sleep 1000' obedient)"
echo "$OUT"
ALIVE=$(printf '%s\n' "$OUT" | sed -n 's/^ALIVE=//p')
ELAPSED=$(printf '%s\n' "$OUT" | sed -n 's/.*ELAPSED=\([0-9]*\).*/\1/p')
REASON=$(printf '%s\n' "$OUT" | sed -n 's/.*REASON=\(.*\)/\1/p')
check "AE2 gone" "$([ "$ALIVE" = "0" ] && echo yes || echo no)" "yes"
# well under WATCHDOG_GRACE=10, the early-bail-on-death poll noticed the wrapper was already gone
# rather than sleeping the whole window
check "AE2 fast, no full grace wait" "$([ "$ELAPSED" -le 5 ] && echo yes || echo "no ($ELAPSED)")" "yes"
# one line, never a second signal logged
check "AE2 sig log" "$(tr -s '\n' ' ' < "$TAE/obedient.sig" 2>/dev/null)" "TERM "
# a KILL cannot be trapped, so a second line here would mean something else stayed alive to log
# it, not that KILL fired
check "AE2 sig count" "$(grep -c . "$TAE/obedient.sig" 2>/dev/null)" "1"
# the wrapper self-exited before the recheck, so terminator.sh never overwrote CODE with the
# KILL-code variant
check "AE2 reason" "$REASON" "0"
# AE2 PASS — gone = yes, fast, no full grace wait = yes, sig log = 'TERM ', sig count = 1, reason = 0.

# AE3 — the escalation re-validates the recorded identity before its KILL: a record overwritten
# during the grace window is not signalled
cd "$TAE/repo"
bash -c 'trap "" TERM; sleep 1000' > "$TAE/victim.out" 2>&1 & VICTIM=$!
bash -c 'trap "" TERM; sleep 1000' > "$TAE/bystander.out" 2>&1 & BYSTANDER=$!
rec="$TAE/rec-restart"
st="$(ps -o lstart= -p "$VICTIM" 2>/dev/null | awk '{$1=$1;print}')"
printf '%s\n%s\n%s\n' "$VICTIM" "$st" 1 > "$rec"
safe="$TAE/safe-restart"; printf 'x\n' > "$safe"
reason="$TAE/reason-restart"
# overwrite the record with the bystander's identity partway through the grace window, exactly
# as a real restart would once it wrote a fresh record — this must be the pid term_owner's
# KILL escalation reaches, and the victim (still holding the OLD, now-stale record's pid) must
# be left alone by the escalation from here on.
( sleep 4
  bst="$(ps -o lstart= -p "$BYSTANDER" 2>/dev/null | awk '{$1=$1;print}')"
  printf '%s\n%s\n%s\n' "$BYSTANDER" "$bst" 2 > "$rec"
) > "$TAE/rewrite.out" 2>&1 &
KAIZERO_INSTANCE=AE001 KAIZERO_SESSION_RECORD="$rec" KAIZERO_SESSION_EPOCH=1 \
  KAIZERO_SAFE_TO_EXIT="$safe" KAIZERO_EXIT_REASON="$reason" \
  bash -c 'printf "%s" "{}" | bash "$1" >/dev/null 2>&1' _ "$HOOK"
sleep 0.3
# the stale record's own pid is never KILLed once the epoch it was validated under is gone
check "AE3 victim still alive" "$(kill -0 "$VICTIM" 2>/dev/null && echo yes || echo no)" "yes"
# the new record names it, but its epoch (2) never matched KAIZERO_SESSION_EPOCH=1 either, so
# it was never a valid escalation target
check "AE3 bystander untouched" "$(kill -0 "$BYSTANDER" 2>/dev/null && echo yes || echo no)" "yes"
kill -KILL "$VICTIM" "$BYSTANDER" 2>/dev/null; wait "$VICTIM" "$BYSTANDER" 2>/dev/null
# AE3 PASS — victim still alive = yes, bystander untouched = yes.

# AE PASS — AE1 through AE3 all report PASS.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
