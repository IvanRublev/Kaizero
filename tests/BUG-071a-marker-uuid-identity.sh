#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=90s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# BUG-071a-marker-uuid-identity — turn_tree_state's marker check compares the newest record's own
# `uuid` (written as the marker's CONTENT) against the transcript's own newest record `uuid`,
# never a `stat` mtime. A stale marker left over from a prior launch, with content that does not
# match the CURRENT transcript's newest record, must never be read as a confirmation for this
# transcript — same-second mtime race or not.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/BUG-071a-marker-uuid-identity

TW="$TESTROOT/BUG-071a-marker-uuid-identity"; mkdir -p "$TW/repo" "$TW/bin"
cd "$TW/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] T1 x\n' > todo.md; git add -A; git commit -qm init

# TW1a — a STALE marker (unrelated uuid, simulating a leftover from a prior launch) plus a fresh
# `pending` record for THIS transcript: the mismatch must not read as concluded. Survives the full
# watchdog window untouched, killed only by the outer harness timeout, same shape as
# TASK-066h's own "no watchdog kill" pending-lockwait check.
cd "$TW/repo"
cat > "$TW/bin/claude" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo "stub tw1a"
mkdir -p "$(dirname "$KAIZERO_SESSION_TRANSCRIPT")"
mf="${KAIZERO_EXIT_REASON%/*}/turn-concluded-${KAIZERO_EXIT_REASON##*/claude-exit-reason-}"
printf '%s' "unrelated-stale-uuid-0000" > "$mf"
printf '%s\n' '{"type":"assistant","uuid":"live-uuid-1","message":{"stop_reason":"tool_use"}}' >> "$KAIZERO_SESSION_TRANSCRIPT"
sleep 12
exit 0
STUB
chmod +x "$TW/bin/claude"
PATH="$TW/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TW/tw1a.log" 2>&1
check "TW1a exit" "$?" "0"
check "TW1a stale/mismatched marker does not force concluded" "$(grep -c '❄ Watchdog ·' "$TW/tw1a.log")" "0"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
