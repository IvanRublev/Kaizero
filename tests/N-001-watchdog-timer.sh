#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=585s
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# N-001-watchdog-timer — the KAIZERO_WATCHDOG timer's kill-and-restart mechanics: a stalled
# claude is killed (TERM then KILL) and restarted, 0 disables it, a healthy claude is left
# alone, and the kill reaches claude's own subprocess too.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/N-001-watchdog-timer
#
# A claude that stops making progress never exits, so the loop parks on it forever. The watchdog
# is the cutoff: it names itself on its own console line, SIGTERMs claude onto the ordinary
# restart path, and escalates to SIGKILL for a claude that ignores TERM. A claude that exits on
# its own must never see it, and 0 must switch it off.

# Setup
TN="$TESTROOT/N-001-watchdog-timer"; mkdir -p "$TN/repo" "$TN/bin"
cd "$TN/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] N1 x\n' > todo.md; git add -A; git commit -qm init

# N1 — a hung claude is killed, named, and restarted
cd "$TN/repo"
# BUG 058k: the wrapper's own `trap "" TERM` (SIG_IGN) survives fork+exec into every descendant.
# POSIX forbids a non-interactive shell's own `trap` builtin from un-ignoring a signal already
# SIG_IGN at that shell's own startup, so a bash stub can never model "an obedient claude that
# dies to TERM" via `trap`. Real claude (Node) overrides the inherited ignore via its own
# sigaction() call — python3's signal.signal is the same real mechanism, not a shell trap.
printf '#!/usr/bin/env python3\nimport sys, signal, time\nif len(sys.argv) > 1 and sys.argv[1] == "-v":\n    print("stub-claude 0.0.0"); sys.exit(0)\nsignal.signal(signal.SIGTERM, lambda s, f: sys.exit(143))\nprint("stub hung", flush=True)\ntime.sleep(1000)\n' > "$TN/bin/claude"; chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 90 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge todo.md -t x > "$TN/hang.log" 2>&1
# the watchdog's kill is a restart, not a failure of the run
check "N1 exit" "$?" "0"
# its own line, once per hung launch
check "N1 watchdog line" "$(grep -c '❄ Watchdog · no progress from claude for 5s . killing it (KAIZERO_WATCHDOG=5)' "$TN/hang.log")" "2"
# SIGTERM, so the tested restart path
check "N1 restart line" "$(grep -c 'Claude exited after 1 runs . restarting in' "$TN/hang.log")" "1"
# the watchdog's own reason, above each of the two report lines
check "N1 restart code" "$(grep -c 'Code 91 - no progress for 5s' "$TN/hang.log")" "2"
# the loop went on instead of parking on run 1
check "N1 runs" "$(grep -c 'stub hung' "$TN/hang.log")" "2"
check "N1 orphans" "$(pgrep -f "$TN/bin/claude" | wc -l | tr -d ' ')" "0"
# N1 PASS — exit = 0, watchdog line = 2, restart line = 1, restart code = 2, runs = 2, orphans = 0.

# N2 — a claude that ignores SIGTERM is SIGKILLed
cd "$TN/repo"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\ntrap "" TERM\necho "stub deaf"\nsleep 1000\n' > "$TN/bin/claude"; chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 90 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TN/deaf.log" 2>&1
# not 124: the timer, not the harness, ended it
check "N2 exit" "$?" "0"
# the escalation ~10s after the ignored TERM, told apart from the TERM-only 91
check "N2 kill code" "$(grep -c 'Code 92 - ' "$TN/deaf.log")" "1"
check "N2 orphans" "$(pgrep -f "$TN/bin/claude" | wc -l | tr -d ' ')" "0"
# N2 PASS — exit = 0, kill code = 1, orphans = 0.

# N3 — off by request, silent on a healthy claude, default on a mistyped value
cd "$TN/repo"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\necho "stub hung"\nsleep 1000\n' > "$TN/bin/claude"; chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" KAIZERO_WATCHDOG=0 timeout 20 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TN/off.log" 2>&1
# 0 disables the timer, so the hang is left alone
check "N3 off exit" "$?" "124"
check "N3 off line" "$(grep -c '❄ Watchdog ·' "$TN/off.log")" "0"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\necho "stub ran"\nexit 0\n' > "$TN/bin/claude"; chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 40 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TN/ok.log" 2>&1
check "N3 healthy exit" "$?" "0"
# a claude that exits on its own retires its own timer
check "N3 healthy line" "$(grep -c '❄ Watchdog ·' "$TN/ok.log")" "0"
PATH="$TN/bin:$PATH" KAIZERO_WATCHDOG=15min timeout 40 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TN/bad.log" 2>&1
check "N3 bad exit" "$?" "0"
# a typo falls back to the default, never to no watchdog
check "N3 bad warning" "$(grep -c 'Ignoring KAIZERO_WATCHDOG=15min' "$TN/bad.log")" "1"
# N3 PASS — off exit = 124 with off line = 0, healthy exit = 0 with healthy line = 0, and bad exit = 0 with bad warning = 1.

# N5 — the KILL escalation reaches a deaf descendant even when the session itself obeys the TERM (BUG 057)
cd "$TN/repo"
# BUG 057: claude's own pid obeys the TERM (default disposition, no trap) and exits promptly —
# the case a bare re-walk after the grace period cannot handle, because by then the child is
# reparented to init and nothing links it to the session any more. The child backgrounds a
# marked, TERM-deaf process (trap "" TERM) standing in for an in-flight git/forge subprocess.
# The oracle is a positive count of that marked process, matched by a distinctive PATH-embedded
# marker rather than a `kill -0` on a pid read from a file — a file the stub never wrote would
# make the old oracle pass whether or not the child died.
MARK="n5child-$RANDOM"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\nbash -c '"'"'trap "" TERM; exec sleep 1000'"'"' "%s" &\necho "stub obedient parent, deaf child"\nsleep 1000\n' "$MARK" > "$TN/bin/claude"
chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 90 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TN/tree.log" 2>&1
check "N5 exit" "$?" "0"
# reached via the TERM-pass snapshot, not a re-walk after claude's own pid is already gone
check "N5 child survivors" "$(pgrep -f "$MARK" | wc -l | tr -d ' ')" "0"
# N5 PASS — exit = 0, child survivors = 0.

# N6 — -h/--help names KAIZERO_WATCHDOG and its default
H="$(bash "$SCRIPT" -h)"
check "N6 names the var" "$(printf '%s' "$H" | grep -c 'KAIZERO_WATCHDOG=duration')" "1"
check "N6 says default" "$(printf '%s\n' "$H" | grep -A2 'KAIZERO_WATCHDOG=duration' | grep -c '15m')" "1"
check "N6 0 disables it" "$(printf '%s' "$H" | grep -c '0 disables the watchdog')" "1"
# N6 PASS — all three = 1.

# N9 — the watchdog kills a `zero.sh mr` child stalled on the forge, not just claude's own pid
cd "$TN/repo"
# stands in for claude mid-Bash-tool-call running .git/zero.sh mr <id> <twt>, stalled on a
# blocked forge call: a stub zero.sh backgrounded, then a plain default-TERM wait — bash does
# not forward a signal from an exiting script to a job it merely backgrounded, so this child
# only dies if the watchdog's kill walks the tree (terminator.sh's descendant TERM/KILL sweep)
# instead of signaling claude's own pid alone
printf '#!/usr/bin/env bash\nsleep 1000\n' > "$TN/bin/zero.sh"; chmod +x "$TN/bin/zero.sh"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\n"%s/bin/zero.sh" mr FAKE-1 /fake/wt &\necho "$!" > "%s/mr-child.pid"\necho "stub running zero.sh mr"\nwait\n' "$TN" "$TN" > "$TN/bin/claude"
chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 90 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TN/mr-watchdog.log" 2>&1
# the watchdog's kill is a restart, not a failure of the run
check "N9 exit" "$?" "0"
check "N9 watchdog line" "$(grep -c '❄ Watchdog · no progress from claude for 5s' "$TN/mr-watchdog.log")" "1"
MRCHILD="$(cat "$TN/mr-child.pid" 2>/dev/null)"
sleep 0.3
kill -0 "$MRCHILD" 2>/dev/null
# killed via the watchdog's terminator.sh descendant sweep, not left running against the forge
check "N9 mr child orphaned" "$?" "1"
# N9 PASS — exit = 0, watchdog line = 1, mr child orphaned = 1.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
