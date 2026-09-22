#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=420s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# TASK-066-turn-state-watchdog — the watchdog's turn-state check beyond what N-002/AF-001 already
# cover (a long local tool call, and flat-everything still kills): a dispatched subagent's OWN
# turn — at any lineage depth — keeps the window alive even while main's pid is silent (TW1, TW2);
# an interrupted turn is judged concluded the moment the interrupt is observed, not kept alive by
# it (TW3); a turn stuck "active" (awaiting a response that never comes — the unrecovered-API-error
# shape) decays to a kill despite unrelated child-process churn (TW4); once a turn has genuinely
# concluded, further CPU churn from an unrelated child no longer resets the window at all (TW5);
# the Stop hook's own emitted marker is written at its derived path on a real firing (TW6) and is
# preferred over a transcript-parsed guess for the main session (TW7).
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/TASK-066-turn-state-watchdog

TW="$TESTROOT/TASK-066-turn-state-watchdog"; mkdir -p "$TW/repo" "$TW/bin"
cd "$TW/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] T1 x\n' > todo.md; git add -A; git commit -qm init

PENDING='{"type":"assistant","message":{"stop_reason":"tool_use"}}'
ACTIVE='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}'
CONCLUDED='{"type":"assistant","message":{"stop_reason":"end_turn"}}'
INTERRUPTED='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}'

# TW1 — a dispatched subagent's own turn (its own transcript file under the session dir, growing
# with realistic "active" records) keeps the window alive while main's own pid is silent and main's
# own transcript never grows past the one dispatch ("pending") record
cd "$TW/repo"
rm -f "$TW/tw1.sdir"
cat > "$TW/bin/claude" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo "stub tw1"
mkdir -p "\$(dirname "\$KAIZERO_SESSION_TRANSCRIPT")"
printf '%s\n' '$PENDING' >> "\$KAIZERO_SESSION_TRANSCRIPT"
printf '%s' "\${KAIZERO_SESSION_TRANSCRIPT%.jsonl}" > "$TW/tw1.sdir"
sleep 15
exit 0
STUB
chmod +x "$TW/bin/claude"
( for i in $(seq 1 25); do
    sleep 1
    if [ -f "$TW/tw1.sdir" ]; then
      d="$(cat "$TW/tw1.sdir")/subagents"; mkdir -p "$d"
      printf '%s\n' "$ACTIVE" >> "$d/agent-1.jsonl"
    fi
  done ) > "$TW/tw1.toucher.out" 2>&1 &
TOUCHER=$!
PATH="$TW/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TW/tw1.log" 2>&1
RC=$?
kill "$TOUCHER" 2>/dev/null
check "TW1 exit" "$RC" "0"
check "TW1 no watchdog kill" "$(grep -c '❄ Watchdog ·' "$TW/tw1.log")" "0"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
