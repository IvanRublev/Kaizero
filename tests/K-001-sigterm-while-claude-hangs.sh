#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=220s
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# K-001-sigterm-while-claude-hangs — SIGTERM while claude hangs. A hung claude is reaped on
# SIGTERM (backgrounded + interruptible wait) without losing the exit report; normal exit and
# restart paths are unaffected.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/K-001-sigterm-while-claude-hangs
#
# A supervisor / timeout / kill stopping the run must still land at the closer. The stub hangs
# forever, so the wrapper only survives the TERM if claude is backgrounded and reaped by an
# interruptible wait — a foreground child would defer the trap until the KILL. The same stub
# set proves the two paths this must not change: a clean exit still ends 0, and a stub exiting
# 143 (the Stop hook's restart signal) still restarts with TERMED unset.

# Setup
TK="$TESTROOT/K-001-sigterm-while-claude-hangs"; mkdir -p "$TK/repo" "$TK/bin"
cd "$TK/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] K1 x\n' > todo.md; git add -A; git commit -qm init

# K1 — the hang: closer still runs, exit 143, no orphan child
cd "$TK/repo"
rm -f "$TK/k1.ready"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\necho "Execution error"\nsleep 0.3\n: > "%s/k1.ready"\nsleep 1000\n' "$TK" > "$TK/bin/claude"; chmod +x "$TK/bin/claude"
PATH="$TK/bin:$PATH" env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TK/hang.log" 2>&1 &
WPID=$!
# wait for the stub's own readiness marker, not a bare pgrep match — pgrep also matches the
# short-lived run_doctor `claude -v` preflight (same argv0 path), and even once the real launch
# starts, firing TERM the instant pgrep sees it can race script's pty-copy loop before "Execution
# error" is flushed to hang.log
i=0; while [ ! -f "$TK/k1.ready" ] && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
kill -TERM "$WPID" 2>/dev/null
i=0; while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
kill -0 "$WPID" 2>/dev/null && kill -KILL "$WPID" 2>/dev/null
K1RC=0; wait "$WPID" || K1RC=$?
check "K1 exit" "$K1RC" "143"
# the report the TERM used to eat
check "K1 stats" "$(grep -c 'Execution stats' "$TK/hang.log")" "1"
check "K1 stopped" "$(grep -c 'Run loop stopped' "$TK/hang.log")" "1"
# the TERM was forwarded to claude
check "K1 orphans" "$(pgrep -f "$TK/bin/claude" | wc -l | tr -d ' ')" "0"
# a second handler would silently replace this one
check "K1 one TERM trap" "$(grep -c '^trap .*TERM$' "$REAL_SCRIPT")" "1"
# no foreground launch, no `|| true` swallow; <&3 hands claude back the stdin bash would
# otherwise replace with /dev/null on an async launch
check "K1 backgrounded" "$(grep -c 'script -q /dev/null claude "\${CLAUDE_ARGS\[@\]}" "\$PROMPT" >&4 2>&4 <&3 &$' "$REAL_SCRIPT")" "1"
# K1 PASS — exit = 143, stats = 1, stopped = 1, orphans = 0, one TERM trap = 1, backgrounded = 1.

# K2 — the two paths that must not change
cd "$TK/repo"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\necho "stub ran"\nexit 0\n' > "$TK/bin/claude"; chmod +x "$TK/bin/claude"
PATH="$TK/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TK/ok.log" 2>&1
# TERMED=0 must not leak a status through set -e
check "K2 normal exit" "$?" "0"
check "K2 normal stats" "$(grep -c 'Execution stats' "$TK/ok.log")" "1"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\necho "stub run"\nexit 143\n' > "$TK/bin/claude"; chmod +x "$TK/bin/claude"
PATH="$TK/bin:$PATH" timeout 60 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge todo.md -t x > "$TK/restart.log" 2>&1
# claude's own 143 is the Stop hook path, not ours
check "K2 restart exit" "$?" "0"
# the wait's re-check found it dead and looped
check "K2 restart runs" "$(grep -c 'stub run' "$TK/restart.log")" "2"
check "K2 restart line" "$(grep -c 'restarting in' "$TK/restart.log")" "1"
# K2 PASS — normal exit = 0 with normal stats = 1, and restart exit = 0 with restart runs = 2, restart line = 1.

# K3 — SIGTERM to kaizero.sh also kills a `zero.sh mr` child stalled on the forge, not just claude's own pid
cd "$TK/repo"
# stands in for claude mid-Bash-tool-call running .git/zero.sh mr <id> <twt>: a stub zero.sh
# backgrounded, then a plain default-TERM wait — bash does not forward a signal from an exiting
# script to a job it merely backgrounded, so this child only dies if on_term's terminator.sh walks
# the tree (its descendant TERM/KILL sweep) instead of signaling claude's own pid alone
printf '#!/usr/bin/env bash\nsleep 1000\n' > "$TK/bin/zero.sh"; chmod +x "$TK/bin/zero.sh"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\n"%s/bin/zero.sh" mr FAKE-1 /fake/wt &\necho "$!" > "%s/mr-child.pid"\necho "stub running zero.sh mr"\nwait\n' "$TK" "$TK" > "$TK/bin/claude"
chmod +x "$TK/bin/claude"
PATH="$TK/bin:$PATH" env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TK/mr-term.log" 2>&1 &
WPID=$!
i=0; while [ ! -f "$TK/mr-child.pid" ] && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
MRCHILD="$(cat "$TK/mr-child.pid" 2>/dev/null)"
kill -TERM "$WPID" 2>/dev/null
i=0; while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
kill -0 "$WPID" 2>/dev/null && kill -KILL "$WPID" 2>/dev/null
wait "$WPID" 2>/dev/null
sleep 0.3
kill -0 "$MRCHILD" 2>/dev/null
# TERMed via on_term's terminator.sh, not left running against the forge
check "K3 mr child orphaned" "$?" "1"
# K3 PASS — mr child orphaned = 1.

# K4 — renaming the agent binary does not change which process is signalled (BUG 057)
cd "$TK/repo"
# claude on PATH execs a stub under a DIFFERENT name — ps -o comm= then reports that other
# name for the running session, not claude. Before BUG 057 this made term_owner's/find_owner's
# name-matcher a no-op (it walked for a process named claude and never found one); the recorded
# session identity carries no name at all, so it is signalled exactly as K1's own hang case is.
# `sleep 1000 & wait`, not a bare `sleep 1000`: bash tail-call-execs a lone-final external command
# in place (no fork, same pid, new image) — a bare sleep would silently overwrite the argv0 this
# case just renamed, replacing "k4-renamed-agent" with "sleep" before the poll below ever sees it.
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\nexec -a k4-renamed-agent bash -c "echo \\"Execution error\\"; sleep 1000 & wait"\n' > "$TK/bin/claude"
chmod +x "$TK/bin/claude"
PATH="$TK/bin:$PATH" env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TK/k4.log" 2>&1 &
WPID=$!
i=0; while ! pgrep -f k4-renamed-agent >/dev/null 2>&1 && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
check "K4 renamed process running before TERM" "$(pgrep -f k4-renamed-agent | wc -l | tr -d ' ')" "1"
kill -TERM "$WPID" 2>/dev/null
i=0; while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
kill -0 "$WPID" 2>/dev/null && kill -KILL "$WPID" 2>/dev/null
K4RC=0; wait "$WPID" || K4RC=$?
check "K4 exit" "$K4RC" "143"
# signalled by recorded pid, not by a comm= name match
check "K4 renamed process gone after TERM" "$(pgrep -f k4-renamed-agent | wc -l | tr -d ' ')" "0"
# K4 PASS — renamed process running before TERM = 1, exit = 143, renamed process gone after TERM = 0.

# K5 — a claude that ignores SIGTERM is escalated to SIGKILL by terminator.sh's own WATCHDOG_GRACE
# window, not left running until some outside cleanup kills it (BUG 058k: on_term used to send a
# single TERM with no escalation)
cd "$TK/repo"
rm -f "$TK/k5.ready"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\ntrap "" TERM\n: > "%s/k5.ready"\necho "stub deaf"\nsleep 1000\n' "$TK" > "$TK/bin/claude"; chmod +x "$TK/bin/claude"
PATH="$TK/bin:$PATH" env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TK/deaf.log" 2>&1 &
WPID=$!
# wait for the readiness marker, written only after `trap "" TERM` is installed — a bare pgrep
# match (which also catches run_doctor's `claude -v` preflight) can fire TERM before the trap is
# in place, letting the "deaf" stub die on the first TERM and defeating the whole test
i=0; while [ ! -f "$TK/k5.ready" ] && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
kill -TERM "$WPID" 2>/dev/null
# a TERM-obedient stub would already be gone by here; the deaf one must still be alive
sleep 2
check "K5 deaf survives TERM" "$(pgrep -f "$TK/bin/claude" | wc -l | tr -d ' ')" "1"
# terminator.sh's own KILL escalation ends it once WATCHDOG_GRACE elapses — no signal sent by the
# test itself
i=0; while pgrep -f "$TK/bin/claude" >/dev/null 2>&1 && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done
check "K5 deaf killed within grace" "$(pgrep -f "$TK/bin/claude" | wc -l | tr -d ' ')" "0"
i=0; while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i+1)); done
kill -0 "$WPID" 2>/dev/null && kill -KILL "$WPID" 2>/dev/null
K5RC=0; wait "$WPID" || K5RC=$?
check "K5 exit" "$K5RC" "143"
# K5 PASS — deaf survives TERM = 1, deaf killed within grace = 0, exit = 143.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
