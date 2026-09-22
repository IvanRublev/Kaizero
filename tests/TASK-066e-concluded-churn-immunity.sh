#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=90s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# TASK-066e-concluded-churn-immunity — once every tracked turn (main and all live subagents) has
# concluded, CPU activity from a child process unrelated to any pending tool call no longer resets
# the window at all: an ordinary end_turn record followed by unrelated short-lived child churn
# still decays to a kill.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/TASK-066e-concluded-churn-immunity

TW="$TESTROOT/TASK-066e-concluded-churn-immunity"; mkdir -p "$TW/repo" "$TW/bin"
cd "$TW/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] T1 x\n' > todo.md; git add -A; git commit -qm init

CONCLUDED='{"type":"assistant","message":{"stop_reason":"end_turn"}}'

# TW5 — concluded, then unrelated short-lived child churn the whole time: still killed
cd "$TW/repo"
cat > "$TW/bin/claude" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo "stub tw5"
mkdir -p "\$(dirname "\$KAIZERO_SESSION_TRANSCRIPT")"
printf '%s\n' '$CONCLUDED' >> "\$KAIZERO_SESSION_TRANSCRIPT"
( for i in \$(seq 1 20); do : & wait; sleep 0.3; done ) &
sleep 1000
STUB
chmod +x "$TW/bin/claude"
PATH="$TW/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TW/tw5.log" 2>&1
check "TW5 exit" "$?" "0"
check "TW5 watchdog kill" "$(grep -c '❄ Watchdog · no progress from claude for 5s' "$TW/tw5.log")" "1"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
