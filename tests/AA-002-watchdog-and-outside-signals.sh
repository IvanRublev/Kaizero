#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=422s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# AA-002-watchdog-and-outside-signals — the EXIT_REASON code for a signal-sourced exit: the
# watchdog's TERM and its KILL escalation (91/92), a signal from outside Kaizero (93/94), and
# the wrapper's own SIGTERM (95) — plus the absence check that a SIGKILL to the wrapper itself
# prints nothing at all.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it.
# Tools beyond the shared prerequisites: none.
# Folder under $TESTROOT: $TESTROOT/AA-002-watchdog-and-outside-signals
# Wall-clock budget: its longest single Run command is `timeout 90` — allow that command at least
# 90s; AA5 runs it twice in sequence, so budget the case up to 180s altogether.
#
# Every restart/stop line is preceded by one "Code <N> - <reason>." line built from a single
# Kaizero-owned code. The code is written by whichever path kills claude, the instant it acts —
# wait collapses every SIGTERM into 143 and every SIGKILL into 137, so a cause re-derived after
# the fact could only guess. This scenario drives each write site for real and reads back the
# line the loop printed.
#
# Coverage of the two numbering schemes the script produces (both tabled in the README's
# ### Exit codes): EXIT_REASON 91 (AA3), 92 (AA4), 93/94 (AA5), 95 (AA6). kaizero.sh's own
# final status: 1 (B-001-startup-guard-refusals, Y5), 2
# (R-003-validate-ids-cache-and-the-launch-gate's id-validation refusal), 143 (AA6, K1).

# Setup
TAA="$TESTROOT/AA-002-watchdog-and-outside-signals"; mkdir -p "$TAA/repo" "$TAA/bin"
cd "$TAA/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] AA1 x\n' > todo.md; git add -A; git commit -qm init

# BUG 058k: the wrapper's own `trap "" TERM` (SIG_IGN) survives fork+exec into every descendant.
# Real claude (Node) overrides the inherited ignore via its own sigaction() call at startup — but
# POSIX shell semantics explicitly forbid a NON-INTERACTIVE shell's own `trap` builtin from
# un-ignoring a signal that was already SIG_IGN when that shell started, so a bash stub can never
# model "an obedient claude that dies to TERM" via `trap ... TERM` here — it needs a real
# sigaction()-based handler (python3), the same mechanism claude itself actually uses, to prove
# the signal is deliverable at all.
aahung(){ printf '#!/usr/bin/env python3\nimport sys, signal, time\nif len(sys.argv) > 1 and sys.argv[1] == "-v":\n    print("stub-claude 0.0.0"); sys.exit(0)\nsignal.signal(signal.SIGTERM, lambda s, f: sys.exit(143))\nprint("stub hung", flush=True)\ntime.sleep(1000)\n' > "$TAA/bin/claude"; chmod +x "$TAA/bin/claude"; }
# waits for the stub to be up, then signals IT (never the wrapper) — the "from outside" cases.
aasig(){ local i=0; while ! pgrep -f "$TAA/bin/claude" >/dev/null 2>&1 && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
        pkill -"$1" -f "$TAA/bin/claude"; }

# AA3 — the watchdog's own SIGTERM is 91, not "a signal from somewhere"
cd "$TAA/repo"
aahung
PATH="$TAA/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 90 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TAA/wd.log" 2>&1
check "AA3 exit" "$?" "0"
# the watchdog's own cause, in its own words
check "AA3 code 91" "$(grep -c "Code 91 - no progress for 5s . Kaizero's watchdog terminated it (KAIZERO_WATCHDOG=5)\." "$TAA/wd.log")" "1"
# 143 alone would read as an outside signal
check "AA3 not 93" "$(grep -c 'Code 93' "$TAA/wd.log")" "0"
# AA3 PASS — exit = 0, code 91 = 1, not 93 = 0.

# AA4 — the SIGKILL escalation is 92, distinct from the TERM-only case
cd "$TAA/repo"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\ntrap "" TERM\necho "stub deaf"\nsleep 1000\n' > "$TAA/bin/claude"; chmod +x "$TAA/bin/claude"
PATH="$TAA/bin:$PATH" KAIZERO_WATCHDOG=5 KAIZERO_WATCHDOG_GRACE=2 timeout 90 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TAA/deaf.log" 2>&1
check "AA4 exit" "$?" "0"
check "AA4 code 92" "$(grep -c 'Code 92 - .*watchdog killed it 2s after the SIGTERM it ignored' "$TAA/deaf.log")" "1"
# the escalation overwrites its own earlier 91
check "AA4 not 91" "$(grep -c 'Code 91' "$TAA/deaf.log")" "0"
# AA4 PASS — exit = 0, code 92 = 1, not 91 = 0.

# AA5 — a signal from outside Kaizero: 93 (TERM) and 94 (KILL)
cd "$TAA/repo"
for sig in TERM KILL; do
  aahung
  # a brace group (not `cmd & ...`) runs in this shell, so $! is kaizero.sh's own pid, not a
  # backgrounding subshell's.
  { PATH="$TAA/bin:$PATH" KAIZERO_WATCHDOG=0 timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TAA/ext-$sig.log" 2>&1 & }
  W=$!; aasig "$sig"; wait "$W"; check "AA5 $sig exit" "$?" "0"
done
# watchdog off, hook silent, so nothing of ours wrote a code
check "AA5 code 93" "$(grep -c 'Code 93 - received SIGTERM from outside Kaizero' "$TAA/ext-TERM.log")" "1"
check "AA5 code 94" "$(grep -c 'Code 94 - received SIGKILL from outside Kaizero' "$TAA/ext-KILL.log")" "1"
# AA5 PASS — both exit = 0, code 93 = 1, code 94 = 1.

# AA6 — the outer script's own SIGTERM is 95, above its final report — and its SIGKILL is uncatchable
cd "$TAA/repo"
aahung
# the brace group again (see AA5): the TERM below must reach kaizero.sh itself, not a subshell.
{ PATH="$TAA/bin:$PATH" env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TAA/term95.log" 2>&1 & }
W=$!
i=0; while ! pgrep -f "$TAA/bin/claude" >/dev/null 2>&1 && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
kill -TERM "$W" 2>/dev/null; RC=0; wait "$W" || RC=$?
check "AA6 exit" "$RC" "143"
check "AA6 code 95" "$(grep -c 'Code 95 - Kaizero itself received SIGTERM' "$TAA/term95.log")" "1"
check "AA6 above report" "$(awk '/Code 95/{c=NR} /Execution stats/{if (c && NR>c) {print "yes"; exit}}' "$TAA/term95.log")" "yes"
# absence check: a SIGKILL to the wrapper itself can be trapped by no shell, so no code is written
# for it and none is printed — the README says so plainly, and this proves nothing pretends otherwise.
aahung
{ PATH="$TAA/bin:$PATH" env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TAA/kill9.log" 2>&1 & }
W=$!
i=0; while ! pgrep -f "$TAA/bin/claude" >/dev/null 2>&1 && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
kill -KILL "$W" 2>/dev/null; wait "$W" 2>/dev/null; pkill -KILL -f "$TAA/bin/claude" 2>/dev/null
# nothing runs after SIGKILL, so no reason line is attempted
check "AA6 kill-9 code" "$(grep -c 'Code' "$TAA/kill9.log")" "0"
# the case is named as uncatchable, not silently missing
check "AA6 kill-9 doc" "$(grep -c 'cannot be trapped by any shell' "$REPO/README.md")" "1"
# AA6 PASS — exit = 143, code 95 = 1, above report = yes, kill-9 code = 0, kill-9 doc = 1.

# AA PASS — AA3 through AA6 all report PASS.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
