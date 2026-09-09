#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=660s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# AA-001-exit-reason-code — the EXIT_REASON code for a session's own end: a turn end (0), claude's
# own status (passthrough), the context-rot hook (90), and the per-launch clear that keeps a stale
# code from bleeding into the next loop.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it.
# Tools beyond the shared prerequisites: none.
# Folder under $TESTROOT: $TESTROOT/AA-001-exit-reason-code
# Wall-clock budget: its longest Run command is `timeout 120` — allow that command at least 120s.
#
# Every restart/stop line is preceded by one "Code <N> - <reason>." line built from a single
# Kaizero-owned code. The code is written by whichever path kills claude, the instant it acts —
# wait collapses every SIGTERM into 143 and every SIGKILL into 137, so a cause re-derived after
# the fact could only guess. This scenario drives each write site for real and reads back the line
# the loop printed.
#
# Coverage of the two numbering schemes the script produces (both tabled in the README's
# ### Exit codes): EXIT_REASON 0 (AA1, AA7), 90 (AA8), 91 (AA7, written then cleared; AA9),
# passthrough (AA2). kaizero.sh's own final status: 0 (AA1 and most other scenarios). AA9
# additionally pins the per-launch clear against a signal-ended second loop, and its paired
# mutation-check note proves AA1/AA7 alone cannot stand in for that pin. Scenario AA-002 covers
# the watchdog and outside-signal codes (91 AA3, 92 AA4, 93/94 AA5, 95 AA6) this scenario used to
# hold.

# Setup
TAA="$TESTROOT/AA-001-exit-reason-code"; mkdir -p "$TAA/repo" "$TAA/bin" "$TAA/tx"
cd "$TAA/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] AA1 x\n' > todo.md; git add -A; git commit -qm init
aaexit(){ printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\necho "stub ran"\nexit %s\n' "$1" > "$TAA/bin/claude"; chmod +x "$TAA/bin/claude"; }

# AA1 — a claude that ends its own turn, and the old "with code" wording is gone
cd "$TAA/repo"
aaexit 0
PATH="$TAA/bin:$PATH" timeout 60 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge todo.md -t x > "$TAA/ok.log" 2>&1
check "AA1 exit" "$?" "0"
# one above the restart line, one above the stop line
check "AA1 code 0" "$(grep -c 'Code 0 - claude ended the turn normally\.' "$TAA/ok.log")" "2"
check "AA1 restart line" "$(grep -c 'Claude exited after 1 runs . restarting in' "$TAA/ok.log")" "1"
check "AA1 stop line" "$(grep -c 'Claude exited after 2 runs . reached KAIZERO_MAX_LOOPS=2 . stopping' "$TAA/ok.log")" "1"
# the code moved to the line above
check "AA1 no old wording" "$(grep -c 'claude exited with code' "$TAA/ok.log")" "0"
# AA1 PASS — exit = 0, code 0 = 2, restart line = 1, stop line = 1, no old wording = 0.

# AA2 — claude's own status passes through unchanged
cd "$TAA/repo"
aaexit 7
PATH="$TAA/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TAA/seven.log" 2>&1
# no 90-95 code invented for a status claude chose itself
check "AA2 passthrough" "$(grep -c "Code 7 - claude's own exit status 7 — see its output above\." "$TAA/seven.log")" "1"
# AA2 PASS — passthrough = 1.

# AA7 — the code file is cleared per launch, never carried into the next loop
cd "$TAA/repo"
cat > "$TAA/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }
# run 1 hangs (the watchdog writes 91); run 2 ends its own turn. A stale 91 would be reported twice.
# BUG 058k: bash's own `trap` can't un-ignore a signal already SIG_IGN when a non-interactive
# shell starts (POSIX), so the wrapper's inherited TERM-ignore defeats a plain bash hang here —
# python3's real sigaction()-based handler (same mechanism real claude uses) is needed instead.
n=$(( $(cat "$ZTX/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$ZTX/count"
echo "stub run $n"
if [ "$n" = 1 ]; then exec python3 -c "
import signal, sys, time
signal.signal(signal.SIGTERM, lambda s, f: sys.exit(143))
time.sleep(1000)"
fi
exit 0
EOF
chmod +x "$TAA/bin/claude"; rm -f "$TAA/tx/count"
PATH="$TAA/bin:$PATH" ZTX="$TAA/tx" KAIZERO_WATCHDOG=5 timeout 120 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge todo.md -t x > "$TAA/stale.log" 2>&1
check "AA7 exit" "$?" "0"
check "AA7 run 1 code 91" "$(grep -c 'Code 91' "$TAA/stale.log")" "1"
# run 1's 91 was cleared before run 2 launched
check "AA7 run 2 code 0" "$(grep -c 'Code 0 - claude ended the turn normally\.' "$TAA/stale.log")" "1"
# AA7 PASS — exit = 0, run 1 code 91 = 1, run 2 code 0 = 1.

# AA8 — the context-rot restart is 90, and names the threshold it crossed
cd "$TAA/repo"
cat > "$TAA/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }
# an over-threshold transcript, then the REAL Stop hook — which resolves claude-opus-5's 200000 row
# and records 90 before it kills. BUG 057: no decoy ancestor needed any more — kaizero.sh already
# exported KAIZERO_SESSION_RECORD/KAIZERO_SESSION_EPOCH naming THIS stub's own pid into this
# very process's env when it launched it, and the hook inherits both unchanged, so its term_owner
# validates against this stub's real identity and really SIGTERMs it: no `exit 143` stand-in needed,
# the signal itself ends this script with that status.
echo "stub rot"
t="$ZTX/rot.jsonl"
printf '{"type":"assistant","requestId":"r1","message":{"model":"claude-opus-5","usage":{"input_tokens":9000,"cache_read_input_tokens":250000,"cache_creation_input_tokens":1000,"output_tokens":500}}}\n' > "$t"
hook=""
for a in "$@"; do case "$a" in *compact-exit-hook.sh*) hook="$(printf '%s' "$a" | sed -n 's/.*"command":"\([^"]*\)".*/\1/p')";; esac; done
bash -c 'printf "%s" "$2" | bash "$1" >/dev/null 2>&1' _ \
  "$hook" "$(printf '{"session_id":"stub","transcript_path":"%s"}' "$t")"
exit 143
EOF
chmod +x "$TAA/bin/claude"
PATH="$TAA/bin:$PATH" ZTX="$TAA/tx" timeout 90 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TAA/rot.log" 2>&1
check "AA8 exit" "$?" "0"
check "AA8 code 90" "$(grep -c 'Code 90 - context threshold 200000 reached (claude-opus-5) . Kaizero restarted it with fresh context\.' "$TAA/rot.log")" "1"
# the hook's own 143 is Kaizero's, not an outside signal
check "AA8 not 93" "$(grep -c 'Code 93' "$TAA/rot.log")" "0"
# AA8 PASS — exit = 0, code 90 = 1, not 93 = 0.

# AA9 — the clear survives into a signal-status second loop, not just a normal-ended one
cd "$TAA/repo"
rm -f "$TAA/tx/count"
cat > "$TAA/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }
# run 1 hangs (the watchdog writes 91 for real); run 2 exits 143 on its own, the same status
# wait(2) reports for an unhandled SIGTERM — the write-site-silent case the clear has to survive,
# without racing a real external signal's delivery against the 5s watchdog window.
# BUG 058k: same non-interactive-shell trap restriction as AA7 above — python3's real handler
# is needed for run 1's hang to actually be TERM-killable at all.
n=$(( $(cat "$ZTX/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$ZTX/count"
echo "stub run $n"
if [ "$n" = 1 ]; then exec python3 -c "
import signal, sys, time
signal.signal(signal.SIGTERM, lambda s, f: sys.exit(143))
time.sleep(1000)"
else exit 143; fi
EOF
chmod +x "$TAA/bin/claude"
PATH="$TAA/bin:$PATH" ZTX="$TAA/tx" KAIZERO_WATCHDOG=5 timeout 90 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge todo.md -t x > "$TAA/stale2.log" 2>&1
check "AA9 exit" "$?" "0"
# the watchdog fired for real, no stub-chosen shortcut
check "AA9 run1 code 91" "$(grep -c 'Code 91' "$TAA/stale2.log")" "1"
# cleared before run 2, so run 1's 91 never leaks into a run 2 that ends 143 with neither write site firing
check "AA9 run2 code 93" "$(grep -c 'Code 93 - received SIGTERM from outside Kaizero' "$TAA/stale2.log")" "1"
# a second 91 would mean run 2 also read the stale value
check "AA9 91 not repeated" "$(grep -c 'Code 91' "$TAA/stale2.log")" "1"
# AA9 PASS — exit = 0, run1 code 91 = 1, run2 code 93 = 1, 91 not repeated = 1.

# AA9 mutation check — the clear is load-bearing, not just present. Reverting kaizero.sh's
# per-launch `: > "$EXIT_REASON_FILE"` to a no-op (so run 2 launches without clearing run 1's
# leftover file) must fail AA9's "run2 code 93" assertion — run 2 would instead read the stale 91
# from run 1 and print "Code 91" a second time instead of "Code 93". AA1's "code 0 = 2" assertion
# is unaffected by the same mutation (CLAUDE_EXIT=0 resolves EXIT_REASON=0 unconditionally,
# without reading the file), which is exactly why AA1 alone could never stand in for this check.
# AA9 mutation PASS — confirmed empirically: reverting line 587's `: > "$EXIT_REASON_FILE"` to a
# no-op and re-running this scenario makes run 2 print a second "Code 91" instead of "Code 93",
# exactly as predicted above. EXIT_REASON for CLAUDE_EXIT=0 is always overwritten to 0 at
# kaizero.sh:634 regardless of what the file held (the file is still read unconditionally at
# :630, its value just never survives past :634 on that path), so only a scenario ending on a
# signal status can observe the leftover write — which is exactly what AA9 does and AA1/AA7 do
# not. No fenced code accompanies this note in the source .md — nothing to run here.

# AA PASS — AA1, AA2, AA7, AA8 and AA9 all report PASS.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
