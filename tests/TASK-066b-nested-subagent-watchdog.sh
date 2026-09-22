#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=90s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# TASK-066b-nested-subagent-watchdog — a subagent nested at any lineage depth (a subagent of a
# subagent) counts as "a turn is running" for the whole ancestor chain up to the main session,
# independent of whether that specific subagent's own file has grown: find's recursive walk of the
# session dir reaches it the same as a direct subagent (tests/TASK-066-turn-state-watchdog.sh's
# TW1).
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/TASK-066b-nested-subagent-watchdog

TW="$TESTROOT/TASK-066b-nested-subagent-watchdog"; mkdir -p "$TW/repo" "$TW/bin"
cd "$TW/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] T1 x\n' > todo.md; git add -A; git commit -qm init

PENDING='{"type":"assistant","message":{"stop_reason":"tool_use"}}'
ACTIVE='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}'

# TW2 — a subagent of a subagent still counts, independent of whether the top-level session dir
# itself has any DIRECT child file growing
cd "$TW/repo"
rm -f "$TW/tw2.sdir"
cat > "$TW/bin/claude" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo "stub tw2"
mkdir -p "\$(dirname "\$KAIZERO_SESSION_TRANSCRIPT")"
printf '%s\n' '$PENDING' >> "\$KAIZERO_SESSION_TRANSCRIPT"
printf '%s' "\${KAIZERO_SESSION_TRANSCRIPT%.jsonl}" > "$TW/tw2.sdir"
sleep 15
exit 0
STUB
chmod +x "$TW/bin/claude"
( for i in $(seq 1 25); do
    sleep 1
    if [ -f "$TW/tw2.sdir" ]; then
      d="$(cat "$TW/tw2.sdir")/subagents/agent-1/subagents"; mkdir -p "$d"
      printf '%s\n' "$ACTIVE" >> "$d/agent-2.jsonl"
    fi
  done ) > "$TW/tw2.toucher.out" 2>&1 &
TOUCHER=$!
PATH="$TW/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TW/tw2.log" 2>&1
RC=$?
kill "$TOUCHER" 2>/dev/null
check "TW2 exit" "$RC" "0"
check "TW2 no watchdog kill" "$(grep -c '❄ Watchdog ·' "$TW/tw2.log")" "0"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
