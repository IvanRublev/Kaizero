#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=30s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# BUG-071c-uuid-edge-cases — unit-level checks on newest_record_uuid, run directly against the
# emitted Stop hook (same function, spliced byte-for-byte — see BUG-071a's own comment) so both the
# main-process copy and the hook's copy are exercised the same way.
# Needs real claude: no — the hook is invoked/extracted directly
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/BUG-071c-uuid-edge-cases

TW="$TESTROOT/BUG-071c-uuid-edge-cases"; mkdir -p "$TW/repo" "$TW/bin"
cd "$TW/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] T1 x\n' > todo.md; git add -A; git commit -qm init
printf '#!/usr/bin/env bash\nexit 0\n' > "$TW/bin/claude"; chmod +x "$TW/bin/claude"
PATH="$TW/bin:$PATH" KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md -t x >/dev/null 2>&1 || true
HOOK="$TW/repo/.git/compact-exit-hook.sh"

# extract just newest_relevant_line/newest_record_uuid from the emitted hook into a standalone,
# sourceable file — same functions the hook itself runs, isolated from the rest of its Stop-event
# gating so they can be called directly here.
FUNCS="$TW/funcs.sh"
sed -n '/^newest_relevant_line ()/,/^}/p;/^newest_record_uuid ()/,/^}/p' "$HOOK" > "$FUNCS"

run_check() {
  bash -c '. "$1"; newest_record_uuid "$2"' _ "$FUNCS" "$3"
}

# C1 — missing file: empty, no crash
OUT="$(run_check x x "$TW/does-not-exist.jsonl")"; RC=$?
check "C1 missing file exit" "$RC" "0"
check "C1 missing file empty" "$OUT" ""

# C2 — unreadable file: empty, no crash
UNREAD="$TW/unreadable.jsonl"
printf '%s\n' '{"type":"assistant","uuid":"u1","message":{"stop_reason":"end_turn"}}' > "$UNREAD"
chmod 000 "$UNREAD"
OUT="$(run_check x x "$UNREAD")"; RC=$?
chmod 644 "$UNREAD"
check "C2 unreadable exit" "$RC" "0"
check "C2 unreadable empty" "$OUT" ""

# C3 — zero parseable assistant/user records (only a system record): empty, no crash
NOREC="$TW/no-records.jsonl"
printf '%s\n' '{"type":"system","text":"init"}' > "$NOREC"
OUT="$(run_check x x "$NOREC")"; RC=$?
check "C3 no records exit" "$RC" "0"
check "C3 no records empty" "$OUT" ""

# C4 — trailing system record(s) after the concluding assistant message: uuid still resolves to
# the assistant record's own uuid, not blank, not the system record
TRAIL="$TW/trailing-system.jsonl"
{
  printf '%s\n' '{"type":"assistant","uuid":"concluding-uuid","message":{"stop_reason":"end_turn"}}'
  printf '%s\n' '{"type":"system","text":"stop-hook-housekeeping-1"}'
  printf '%s\n' '{"type":"system","text":"stop-hook-housekeeping-2"}'
} > "$TRAIL"
OUT="$(run_check x x "$TRAIL")"; RC=$?
check "C4 trailing system exit" "$RC" "0"
check "C4 trailing system uuid" "$OUT" "concluding-uuid"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
