#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=90s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# TASK-066h-pending-lockwait-watchdog — BUG-058a's own long-running-tool-call reproduction, re-run
# against turn-state-only: a claude mid-turn on a single tool call (a lock wait, or any other
# CPU-free I/O wait — no descendant_cpu_signature exists anymore to corroborate) survives the whole
# window as long as its last transcript record stays "pending", with zero further writes to any
# transcript and zero CPU ticking — the A-001-parallel-zeroing `zero.sh merge` lock-wait false
# positive this task's reopening exists to fix.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/TASK-066h-pending-lockwait-watchdog

TW="$TESTROOT/TASK-066h-pending-lockwait-watchdog"; mkdir -p "$TW/repo" "$TW/bin"
cd "$TW/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] T1 x\n' > todo.md; git add -A; git commit -qm init

PENDING='{"type":"assistant","message":{"stop_reason":"tool_use"}}'

# TW8 — a single pending tool call (e.g. a lock wait), no further writes, no CPU churn: survives
# the full window (5s) and is killed only by the outer harness timeout, never by the watchdog
cd "$TW/repo"
cat > "$TW/bin/claude" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo "stub tw8"
mkdir -p "\$(dirname "\$KAIZERO_SESSION_TRANSCRIPT")"
printf '%s\n' '$PENDING' >> "\$KAIZERO_SESSION_TRANSCRIPT"
sleep 12
exit 0
STUB
chmod +x "$TW/bin/claude"
PATH="$TW/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TW/tw8.log" 2>&1
check "TW8 exit" "$?" "0"
check "TW8 no watchdog kill" "$(grep -c '❄ Watchdog ·' "$TW/tw8.log")" "0"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
