#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=90s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# TASK-066g-marker-overrides-parse — the Stop hook's own turn marker is preferred over a
# transcript-parsed guess for the main session: the last record in the tail window still reads
# "pending" (a stale, never-resolved tool call, which on its own would keep the window alive
# forever — tests/TASK-066-turn-state-watchdog.sh's TW1) but the marker's mtime is at least as new
# as the transcript's own — the watchdog trusts "concluded" and kills within the window.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/TASK-066g-marker-overrides-parse

TW="$TESTROOT/TASK-066g-marker-overrides-parse"; mkdir -p "$TW/repo" "$TW/bin"
cd "$TW/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] T1 x\n' > todo.md; git add -A; git commit -qm init

PENDING='{"type":"assistant","message":{"stop_reason":"tool_use"}}'

# TW7 — stale "pending" content + the marker touched at/after the transcript's own mtime: killed
cd "$TW/repo"
cat > "$TW/bin/claude" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo "stub tw7"
mkdir -p "\$(dirname "\$KAIZERO_SESSION_TRANSCRIPT")"
printf '%s\n' '$PENDING' >> "\$KAIZERO_SESSION_TRANSCRIPT"
mf="\${KAIZERO_EXIT_REASON%/*}/turn-concluded-\${KAIZERO_EXIT_REASON##*/claude-exit-reason-}"
: > "\$mf"
sleep 1000
STUB
chmod +x "$TW/bin/claude"
PATH="$TW/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TW/tw7.log" 2>&1
check "TW7 exit" "$?" "0"
check "TW7 watchdog kill" "$(grep -c '❄ Watchdog · no progress from claude for 5s' "$TW/tw7.log")" "1"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
