#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=90s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# TASK-066c-interrupted-turn-watchdog — an interrupted turn ("[Request interrupted by user..." in
# the transcript) is judged concluded the moment it is observed, not kept alive by it: the pending
# record right before it would, on its own, keep the window alive forever
# (tests/TASK-066-turn-state-watchdog.sh's TW1) — the interrupt supersedes that.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/TASK-066c-interrupted-turn-watchdog

TW="$TESTROOT/TASK-066c-interrupted-turn-watchdog"; mkdir -p "$TW/repo" "$TW/bin"
cd "$TW/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] T1 x\n' > todo.md; git add -A; git commit -qm init

PENDING='{"type":"assistant","message":{"stop_reason":"tool_use"}}'
INTERRUPTED='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}'

# TW3 — pending, then interrupted, then silence: killed within the window
cd "$TW/repo"
cat > "$TW/bin/claude" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo "stub tw3"
mkdir -p "\$(dirname "\$KAIZERO_SESSION_TRANSCRIPT")"
printf '%s\n' '$PENDING' >> "\$KAIZERO_SESSION_TRANSCRIPT"
sleep 1
printf '%s\n' '$INTERRUPTED' >> "\$KAIZERO_SESSION_TRANSCRIPT"
sleep 1000
STUB
chmod +x "$TW/bin/claude"
PATH="$TW/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TW/tw3.log" 2>&1
check "TW3 exit" "$?" "0"
check "TW3 watchdog kill" "$(grep -c '❄ Watchdog · no progress from claude for 5s' "$TW/tw3.log")" "1"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
