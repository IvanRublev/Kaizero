#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# BUG-071e-startup-decay-guard — mechanism 3: the watchdog never decays before the transcript has
# at least one parseable assistant/user record. A launch slow enough to still be starting up (no
# transcript file yet, or one that exists but is still empty) must not be misread as
# "already concluded" from tick one; once the first real record lands, the full WATCHDOG_SECS
# budget still applies.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/BUG-071e-startup-decay-guard

TW="$TESTROOT/BUG-071e-startup-decay-guard"; mkdir -p "$TW/repo" "$TW/bin"
cd "$TW/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] T1 x\n' > todo.md; git add -A; git commit -qm init

# TW1e — claude delays creating the transcript for 8s (KAIZERO_WATCHDOG=5), well past the window,
# then writes an ordinary concluded record and holds forever: must NOT be killed for the
# missing-transcript span, and once the first record lands the full 5s budget still applies
# (killed only after 5 MORE seconds, not immediately) — also proves an all-concluded tree still
# decays normally once real content exists (the startup guard does not linger past it)
cd "$TW/repo"
cat > "$TW/bin/claude" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo "stub tw1e"
sleep 8
mkdir -p "\$(dirname "\$KAIZERO_SESSION_TRANSCRIPT")"
printf '%s\n' '{"type":"assistant","uuid":"concl-1","message":{"stop_reason":"end_turn"}}' >> "\$KAIZERO_SESSION_TRANSCRIPT"
echo "transcript written"
sleep 1000
STUB
chmod +x "$TW/bin/claude"
PATH="$TW/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TW/tw1e.log" 2>&1
RC=$?
check "TW1e exit" "$RC" "0"
check "TW1e watchdog fired once" "$(grep -c '❄ Watchdog ·' "$TW/tw1e.log")" "1"
# LOG ORDER is what actually proves it: "transcript written" (the first real record landing) must
# appear BEFORE the watchdog kill line — a premature kill during the missing-transcript span would
# print the kill line first (the marker only appears afterwards, once the killed stub's own `sleep
# 8` happens to finish under its SIGTERM grace period) even though total wall-clock duration can
# coincidentally still clear a naive threshold (TERM-then-KILL's own 10s grace period alone very
# nearly covers it) — grep -n line NUMBERS, not elapsed time, are the only reliable signal here.
WRITE_LINE="$(grep -n 'transcript written' "$TW/tw1e.log" | head -1 | cut -d: -f1)"
KILL_LINE="$(grep -n '❄ Watchdog ·' "$TW/tw1e.log" | head -1 | cut -d: -f1)"
check "TW1e first record precedes the kill (no premature kill)" "$([ -n "$WRITE_LINE" ] && [ -n "$KILL_LINE" ] && [ "$WRITE_LINE" -lt "$KILL_LINE" ] && echo yes || echo "write=$WRITE_LINE kill=$KILL_LINE")" "yes"

# TW2e — same as TW1e, but the transcript file exists (created empty by claude itself, as real
# Claude Code does before its first write) for the whole missing-record span rather than never
# existing at all: same "not started yet" case, exercised on the other input newest_relevant_line
# degrades on ([ -f "$1" ] true, tail/grep just find no assistant/user line yet).
cd "$TW/repo"
cat > "$TW/bin/claude" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo "stub tw2e"
mkdir -p "\$(dirname "\$KAIZERO_SESSION_TRANSCRIPT")"
: > "\$KAIZERO_SESSION_TRANSCRIPT"
sleep 8
printf '%s\n' '{"type":"assistant","uuid":"concl-2","message":{"stop_reason":"end_turn"}}' >> "\$KAIZERO_SESSION_TRANSCRIPT"
echo "transcript written"
sleep 1000
STUB
chmod +x "$TW/bin/claude"
PATH="$TW/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TW/tw2e.log" 2>&1
RC=$?
check "TW2e exit" "$RC" "0"
check "TW2e watchdog fired once" "$(grep -c '❄ Watchdog ·' "$TW/tw2e.log")" "1"
WRITE_LINE2="$(grep -n 'transcript written' "$TW/tw2e.log" | head -1 | cut -d: -f1)"
KILL_LINE2="$(grep -n '❄ Watchdog ·' "$TW/tw2e.log" | head -1 | cut -d: -f1)"
check "TW2e first record precedes the kill (empty-file span not decayed)" "$([ -n "$WRITE_LINE2" ] && [ -n "$KILL_LINE2" ] && [ "$WRITE_LINE2" -lt "$KILL_LINE2" ] && echo yes || echo "write=$WRITE_LINE2 kill=$KILL_LINE2")" "yes"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
