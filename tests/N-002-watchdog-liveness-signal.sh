#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=147s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# N-002-watchdog-liveness-signal — the KAIZERO_WATCHDOG timer's progress signal:
# transcript-mtime inactivity, not wall clock (ISSUE 032; BUG 058a in
# tests/AF-001-watchdog-progress-signals.sh widens this to two more OR'd signals), with claude
# launched under a freshly pinned --session-id so its transcript path is known before the
# process starts.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/N-002-watchdog-liveness-signal
#
# Progress is not wall clock, and not the claude's transcript file's mtime alone: a claude whose
# transcript keeps growing survives past the window (N4) even while its own pid burns zero CPU —
# the shape of a claude idling on a dispatched subagent's notification — and, since BUG 058a, a
# claude burning CPU with no transcript progress at all also survives (N4alt), because a live
# descendant ticking CPU is one of the two signals that bugfix OR'd in alongside the transcript.
# claude is launched with a freshly pinned --session-id, so its transcript path is known before
# the process starts, including for the first turn (N7).

# Setup
TN="$TESTROOT/N-002-watchdog-liveness-signal"; mkdir -p "$TN/repo" "$TN/bin"
cd "$TN/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] N1 x\n' > todo.md; git add -A; git commit -qm init

# N4 — a claude whose transcript keeps growing survives even while its own pid burns zero CPU (a subagent-wait proxy)
cd "$TN/repo"
rm -f "$TN/n4.transcript_path"
# claude's own pid does nothing but sleep for 3x the window — genuinely zero CPU, no forks, no
# ticks `ps -o time=` could ever see move. A separate background process stands in for a
# dispatched subagent, touching claude's transcript file once a second the whole time. Real
# claude creates the transcript's parent directory itself before writing to it; the stub does the
# same (mkdir -p) so the toucher's touch has somewhere to land — without it every touch fails
# silently and the scenario can pass by directory-existence luck left over from an unrelated
# earlier run.
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho "stub idle-but-progressing"\nprintf "%%s" "$KAIZERO_SESSION_TRANSCRIPT" > "%s/n4.transcript_path"\nmkdir -p "$(dirname "$KAIZERO_SESSION_TRANSCRIPT")"\nsleep 15\nexit 0\n' "$TN" > "$TN/bin/claude"
chmod +x "$TN/bin/claude"
( for i in $(seq 1 25); do
    sleep 1
    [ -f "$TN/n4.transcript_path" ] && touch "$(cat "$TN/n4.transcript_path")" 2>/dev/null
  done ) > "$TN/toucher.out" 2>&1 &
TOUCHER=$!
PATH="$TN/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TN/busy.log" 2>&1
RC=$?
kill "$TOUCHER" 2>/dev/null
# the stub slept out 3x the window and exited on its own
check "N4 busy exit" "$RC" "0"
# an advancing transcript mtime resets the window, independent of claude's own CPU
check "N4 busy line" "$(grep -c '❄ Watchdog ·' "$TN/busy.log")" "0"
# not a watchdog or signal code
check "N4 own exit code" "$(grep -c 'Code 0 - claude ended the turn normally' "$TN/busy.log")" "1"
# N4 PASS — busy exit = 0, busy line = 0, own exit code = 1. Wall clock alone, and the old
# CPU-time sample alike, would have killed this claude at 5s — it never burns a measurable CPU
# tick — which is exactly the case a claude idling on a dispatched subagent's notification looks
# like from the outside. Only the transcript-mtime sample tells that apart from a wedged socket.

# N4alt — burning CPU alone, with no transcript progress, now also saves a claude from the watchdog (BUG 058a)
cd "$TN/repo"
# mirror of N4: burns CPU but never touches its transcript file. ISSUE 032 deliberately excluded
# CPU time as a signal; BUG 058a (tests/AF-001-watchdog-progress-signals.sh, AF2) widened it back
# in as one of three OR'd signals precisely because a live descendant burning CPU (a long Bash
# tool child, or claude's own process servicing one) is not a hang either — this case now
# survives instead of being killed.
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho "stub busy no transcript"\nend=$((SECONDS+15))\nwhile [ $SECONDS -lt $end ]; do :; done\nexit 0\n' > "$TN/bin/claude"; chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 30 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TN/busynotp.log" 2>&1
check "N4alt exit" "$?" "0"
# CPU burn alone now resets the window
check "N4alt watchdog line" "$(grep -c '❄ Watchdog ·' "$TN/busynotp.log")" "0"
# N4alt PASS — exit = 0, watchdog line = 0.

# N7 — claude is launched with a fresh --session-id, and its transcript path is exported before launch
cd "$TN/repo"
cat > "$TN/bin/claude" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
printf "%s\\n" "\$@" > "$TN/n7.args"
printf "%s" "\$KAIZERO_SESSION_TRANSCRIPT" > "$TN/n7.transcript_var"
echo "stub ran"
exit 0
STUB
chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 20 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TN/n7.log" 2>&1
check "N7 exit" "$?" "0"
SID_ARG="$(grep -A1 '^--session-id$' "$TN/n7.args" | tail -1)"
# a real uuid, not empty or a placeholder
check "N7 session-id flag" "$(printf '%s' "$SID_ARG" | grep -cE '^[0-9a-f-]{36}$')" "1"
TVAR="$(cat "$TN/n7.transcript_var" 2>/dev/null)"
# matches Claude Code's own transcript-path convention for that session id
check "N7 transcript var" "$(printf '%s' "$TVAR" | grep -c "^$HOME/.claude/projects/.*/$SID_ARG\.jsonl\$")" "1"
# N7 PASS — exit = 0, session-id flag = 1, transcript var = 1.

# N8 — the transcript-mtime sample is never dropped (BUG 058a widens it, does not replace it)
N8_COUNT="$(grep -c 'transcript_mtime "\$tp"' "$REAL_SCRIPT")"
# the original ISSUE 032 signal is still sampled every tick
check "N8 mtime kept" "$([ "$N8_COUNT" -ge 1 ] && echo ok || echo "count=$N8_COUNT")" "ok"
# N8 PASS — mtime kept >= 1. BUG 058a (tests/AF-001-watchdog-progress-signals.sh, AF4) is where
# the CPU-descendant signal this once forbade (ps -o time=) is now asserted present, and where
# the exclusion of CLAUDE_WRAPPER_PID/$recorded_pid itself from that sample is asserted.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
