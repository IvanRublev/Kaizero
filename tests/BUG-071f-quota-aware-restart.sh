#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=90s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# BUG-071f-quota-aware-restart — mechanism 2: a main-session turn whose newest record carries
# quotaLimits.status:"rejected" classifies distinctly from an ordinary concluded turn, prints its
# own message text verbatim on kaizero's console, and holds run_loop's relaunch until the next
# scheduled retry or resetsAt — never immediately, never subagent-special-cased, never blocking a
# Ctrl+C/SIGTERM, and never hanging on a missing/unparseable/past resetsAt.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/BUG-071f-quota-aware-restart

TW="$TESTROOT/BUG-071f-quota-aware-restart"; mkdir -p "$TW/repo" "$TW/bin"
cd "$TW/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] T1 x\n' > todo.md; git add -A; git commit -qm init

# ---- Q1/Q2/Q5/Q7 unit checks: turn_record_class / newest_record_resets_at /
# newest_record_message_text / turn_tree_state extracted directly from kaizero.sh (not the hook —
# these run in run_loop's own process, never in the emitted Stop hook), same idiom BUG-071c uses
# for the hook's own copies.
FUNCS="$TW/funcs.sh"
sed -n '/^newest_relevant_line() {/,/^}/p;/^newest_record_uuid() {/,/^}/p;/^turn_record_class() {/,/^}/p;/^newest_record_resets_at() {/,/^}/p;/^newest_record_message_text() {/,/^}/p;/^turn_tree_state() {/,/^}/p' "$REPO/kaizero.sh" > "$FUNCS"

run_class() { bash -c '. "$1"; turn_record_class "$2"' _ "$FUNCS" "$1"; }
run_resets() { bash -c '. "$1"; newest_record_resets_at "$2"' _ "$FUNCS" "$1"; }
run_msg() { bash -c '. "$1"; newest_record_message_text "$2"' _ "$FUNCS" "$1"; }

FUTURE=$(( $(date +%s) + 3600 ))
QREC="$TW/quota.jsonl"
printf '%s\n' "{\"type\":\"assistant\",\"model\":\"<synthetic>\",\"uuid\":\"q-uuid-1\",\"stop_reason\":\"stop_sequence\",\"message\":{\"stop_reason\":\"stop_sequence\",\"content\":[{\"type\":\"text\",\"text\":\"You've hit your session limit \\u00b7 resets 6:30am (Europe/Berlin)\"}]},\"quotaLimits\":{\"status\":\"rejected\",\"resetsAt\":$FUTURE}}" > "$QREC"

# Q1 — classifies distinctly from ordinary concluded
CLS="$(run_class "$QREC")"
check "Q1 quota record classifies distinctly" "$([ "$CLS" != concluded ] && [ -n "$CLS" ] && echo yes || echo "got=$CLS")" "yes"

CONCL="$TW/concluded.jsonl"
printf '%s\n' '{"type":"assistant","uuid":"c-uuid-1","message":{"stop_reason":"end_turn"}}' > "$CONCL"
check "Q1 ordinary record still concluded" "$(run_class "$CONCL")" "concluded"

# Q2/message: resetsAt parses to the fixture epoch, message text carries the API's own literal
# text with no reformatting (a literal apostrophe survives untouched)
check "Q1 resetsAt parses" "$(run_resets "$QREC")" "$FUTURE"
MSG="$(run_msg "$QREC")"
check "Q2 message text non-empty" "$([ -n "$MSG" ] && echo yes || echo no)" "yes"
check "Q2 message text mentions session limit verbatim" "$(printf '%s' "$MSG" | grep -c "hit your session limit")" "1"

# Q7 — absence: missing/unparseable/past resetsAt
NOQUOTA="$TW/no-resets.jsonl"
printf '%s\n' '{"type":"assistant","uuid":"nq-1","stop_reason":"stop_sequence","message":{"stop_reason":"stop_sequence","content":[{"type":"text","text":"weird"}]},"quotaLimits":{"status":"rejected"}}' > "$NOQUOTA"
check "Q7 missing resetsAt is empty" "$(run_resets "$NOQUOTA")" ""

# Q5 — a subagent-only quota rejection reads as ordinary concluded in turn_tree_state: main
# transcript ordinarily concluded, one subagent file's newest record is quota-rejected, nothing
# else pending anywhere in the tree
MAINTP="$TW/main.jsonl"; SDIR="$TW/main"; mkdir -p "$SDIR"
printf '%s\n' '{"type":"assistant","uuid":"main-1","message":{"stop_reason":"end_turn"}}' > "$MAINTP"
cp "$QREC" "$SDIR/sub1.jsonl"
OUT="$(bash -c '. "$1"; turn_tree_state "$2" "$3" ""; echo "ACTIVE=$TURN_ACTIVE PENDING=$TURN_PENDING"' _ "$FUNCS" "$MAINTP" "$SDIR")"
check "Q5 subagent quota rejection reads as ordinary concluded (no hold)" "$OUT" "ACTIVE=0 PENDING=0"

# ---- Q3/Q4/Q6/Q7b full run_loop checks: a stub claude that itself writes the quota-rejected
# record and marks SAFE_TO_EXIT before exiting on its own (same idiom M-001's own stubs use — no
# real Stop hook is invoked, the stub stands in for the whole session).
quota_stub() {
  # $1 = resetsAt epoch to embed, $2 = launch counter file
  cat <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
N=\$(( \$(cat "$2" 2>/dev/null || echo 0) + 1 )); printf '%s' "\$N" > "$2"
echo "stub launch #\$N"
mkdir -p "\$(dirname "\$KAIZERO_SESSION_TRANSCRIPT")"
printf '%s\n' "marked" > "\$KAIZERO_SAFE_TO_EXIT"
printf '%s\n' '{"type":"assistant","model":"<synthetic>","uuid":"q-run-'"\$N"'","stop_reason":"stop_sequence","message":{"stop_reason":"stop_sequence","content":[{"type":"text","text":"You'"'"'ve hit your session limit resets soon"}]},"quotaLimits":{"status":"rejected","resetsAt":$1}}' >> "\$KAIZERO_SESSION_TRANSCRIPT"
exit 0
STUB
}

# Q3/console — resetsAt well past this test's own outer timeout: the quota wait must still be
# parked (not yet relaunched) when the outer `timeout` kills the whole run, and the message must
# already have printed verbatim on kaizero's own console right when the classification was reached
# (no MAX_LOOPS here — a hold that let a second launch through shows up as a second stub launch)
cd "$TW/repo"
RESETS_SOON=$(( $(date +%s) + 3600 ))
COUNTER="$TW/q3-count"
quota_stub "$RESETS_SOON" "$COUNTER" > "$TW/bin/claude"; chmod +x "$TW/bin/claude"
PATH="$TW/bin:$PATH" KAIZERO_QUOTA_RETRY=1800 timeout 8 bash "$SCRIPT" --local-merge todo.md -t x > "$TW/q3.log" 2>&1
check "Q3 message prints verbatim" "$(grep -c "hit your session limit resets soon" "$TW/q3.log")" "1"
check "Q3 no second launch before resetsAt" "$(cat "$COUNTER")" "1"

# Q4 — a second retry that is NOT rejected resumes the ordinary restart path immediately, before
# the fixture's resetsAt: first launch quota-rejected with resetsAt a bit out, second launch (the
# retry) ends ordinarily; both must complete before resetsAt, well inside KAIZERO_QUOTA_RETRY's gap
cd "$TW/repo"
RESETS_Q4=$(( $(date +%s) + 20 ))
Q4STATE="$TW/q4-state"; printf '0' > "$Q4STATE"
cat > "$TW/bin/claude" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
N=\$(( \$(cat "$Q4STATE") + 1 )); printf '%s' "\$N" > "$Q4STATE"
echo "stub launch #\$N"
mkdir -p "\$(dirname "\$KAIZERO_SESSION_TRANSCRIPT")"
printf '%s\n' "marked" > "\$KAIZERO_SAFE_TO_EXIT"
if [ "\$N" = 1 ]; then
  printf '%s\n' '{"type":"assistant","model":"<synthetic>","uuid":"q4-r1","stop_reason":"stop_sequence","message":{"stop_reason":"stop_sequence","content":[{"type":"text","text":"session limit hit"}]},"quotaLimits":{"status":"rejected","resetsAt":$RESETS_Q4}}' >> "\$KAIZERO_SESSION_TRANSCRIPT"
else
  printf '%s\n' '{"type":"assistant","uuid":"q4-r2","message":{"stop_reason":"end_turn"}}' >> "\$KAIZERO_SESSION_TRANSCRIPT"
fi
exit 0
STUB
chmod +x "$TW/bin/claude"
PATH="$TW/bin:$PATH" KAIZERO_QUOTA_RETRY=3 timeout 30 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge todo.md -t x > "$TW/q4.log" 2>&1
check "Q4 exit" "$?" "0"
check "Q4 two launches happened" "$(cat "$Q4STATE")" "2"
ENDQ4=$(date +%s)
check "Q4 second launch resumed before resetsAt" "$([ "$ENDQ4" -lt "$RESETS_Q4" ] && echo yes || echo no)" "yes"
check "Q4 message printed once (only the rejected attempt)" "$(grep -c "session limit hit" "$TW/q4.log")" "1"

# Q6 — Ctrl+C/SIGTERM during the quota wait exits cleanly, not blocked on one long sleep
cd "$TW/repo"
RESETS_FAR=$(( $(date +%s) + 3600 ))
Q6COUNTER="$TW/q6-count"
quota_stub "$RESETS_FAR" "$Q6COUNTER" > "$TW/bin/claude"; chmod +x "$TW/bin/claude"
PATH="$TW/bin:$PATH" KAIZERO_QUOTA_RETRY=1800 bash "$SCRIPT" --local-merge todo.md -t x > "$TW/q6.log" 2>&1 &
Q6PID=$!
sleep 3
kill -TERM "$Q6PID" 2>/dev/null || true
Q6START=$(date +%s)
wait "$Q6PID" 2>/dev/null; Q6RC=$?
Q6DUR=$(( $(date +%s) - Q6START ))
check "Q6 exits promptly on SIGTERM during quota wait" "$([ "$Q6DUR" -le 15 ] && echo yes || echo "took=${Q6DUR}s")" "yes"
check "Q6 exit code is the interrupt path (143)" "$Q6RC" "143"

# Q7b — resetsAt already in the past falls back to the ordinary immediate-restart path
cd "$TW/repo"
RESETS_PAST=$(( $(date +%s) - 3600 ))
COUNTER7="$TW/q7-count"
quota_stub "$RESETS_PAST" "$COUNTER7" > "$TW/bin/claude"; chmod +x "$TW/bin/claude"
PATH="$TW/bin:$PATH" KAIZERO_QUOTA_RETRY=1800 KAIZERO_RESTART_WAIT=1 timeout 30 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge todo.md -t x > "$TW/q7.log" 2>&1
check "Q7b exit" "$?" "0"
check "Q7b past resetsAt still relaunched (no hang)" "$(cat "$COUNTER7")" "2"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
