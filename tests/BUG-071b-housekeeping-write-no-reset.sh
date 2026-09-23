#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=90s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# BUG-071b-housekeeping-write-no-reset — tree_write_signature's per-file signature is each file's
# own newest assistant|user record uuid (BUG-071 mechanism 1), never a raw mtime: a subagent-dir
# write that carries no new assistant/user content (a hook-log/housekeeping record) must not reset
# an "active" (unanswered) window on its own. Pairs with TASK-066d-active-churn-immunity.sh (CPU
# churn, not a real file write) — this scenario is a real write, of the wrong record type.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/BUG-071b-housekeeping-write-no-reset

TW="$TESTROOT/BUG-071b-housekeeping-write-no-reset"; mkdir -p "$TW/repo" "$TW/bin"
cd "$TW/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] T1 x\n' > todo.md; git add -A; git commit -qm init

ACTIVE='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}'

# TW1b — active, then only a housekeeping (non-assistant/user) write into the session dir every
# tick: still killed, since that write carries no new assistant/user uuid
cd "$TW/repo"
cat > "$TW/bin/claude" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo "stub tw1b"
mkdir -p "\$(dirname "\$KAIZERO_SESSION_TRANSCRIPT")"
printf '%s\n' '$ACTIVE' >> "\$KAIZERO_SESSION_TRANSCRIPT"
sdir="\${KAIZERO_SESSION_TRANSCRIPT%.jsonl}"
mkdir -p "\$sdir"
( while true; do printf '%s\n' '{"type":"system","text":"housekeeping"}' >> "\$sdir/hook-log.jsonl"; sleep 0.5; done ) &
sleep 1000
STUB
chmod +x "$TW/bin/claude"
PATH="$TW/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TW/tw1b.log" 2>&1
check "TW1b exit" "$?" "0"
check "TW1b watchdog kill" "$(grep -c '❄ Watchdog · no progress from claude for 5s' "$TW/tw1b.log")" "1"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
