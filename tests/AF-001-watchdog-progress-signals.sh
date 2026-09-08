#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=347s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# AF-001-watchdog-progress-signals — BUG 058a: the watchdog's liveness sample widens from the main
# transcript alone to three OR'd signals — transcript mtime (unchanged, N-002), progress anywhere
# under the session directory (not limited to subagents/*.jsonl), and CPU activity across
# CLAUDE_WRAPPER_PID's live descendants (never CLAUDE_WRAPPER_PID itself). Any one advancing resets the window;
# all three flat still kills, exactly as before.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it.
# Tools beyond the shared prerequisites: none.
# Folder under $TESTROOT: $TESTROOT/AF-001-watchdog-progress-signals
# Wall-clock budget: its longest Run command is `timeout 60` — allow that command at least 60s.

# Setup
TF="$TESTROOT/AF-001-watchdog-progress-signals"; mkdir -p "$TF/repo" "$TF/bin"
cd "$TF/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] F1 x\n' > todo.md; git add -A; git commit -qm init

# AF1 — a file appearing under a differently-named subdirectory of the session dir (not
# subagents/) counts as progress
cd "$TF/repo"
rm -f "$TF/af1.transcript_path"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\necho "stub af1"\nprintf "%%s" "$KAIZERO_SESSION_TRANSCRIPT" > "%s/af1.transcript_path"\nsleep 15\nexit 0\n' "$TF" > "$TF/bin/claude"
chmod +x "$TF/bin/claude"
( for i in $(seq 1 25); do
    sleep 1
    if [ -f "$TF/af1.transcript_path" ]; then
      d="$(cat "$TF/af1.transcript_path")"; d="${d%.jsonl}/otherdir"
      mkdir -p "$d"; date +%s > "$d/marker-$i"
    fi
  done ) > "$TF/toucher.out" 2>&1 &
TOUCHER=$!
PATH="$TF/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TF/af1.log" 2>&1
RC=$?
kill "$TOUCHER" 2>/dev/null
# the stub slept out 3x the window and exited on its own
check "AF1 exit" "$RC" "0"
# a file under any subdirectory of the session dir resets the window, not only subagents/*.jsonl
check "AF1 watchdog line" "$(grep -c '❄ Watchdog ·' "$TF/af1.log")" "0"
# AF1 PASS — exit = 0, watchdog line = 0.

# AF2 — CPU activity in a live descendant of CLAUDE_WRAPPER_PID (not CLAUDE_WRAPPER_PID itself) counts as
# progress, with the transcript and session dir flat
cd "$TF/repo"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\necho "stub af2"\n( end=$((SECONDS+15)); while [ $SECONDS -lt $end ]; do :; done ) &\nwait\nexit 0\n' > "$TF/bin/claude"
chmod +x "$TF/bin/claude"
PATH="$TF/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TF/af2.log" 2>&1
# a busy descendant ticking CPU the whole time is not a hang
check "AF2 exit" "$?" "0"
check "AF2 watchdog line" "$(grep -c '❄ Watchdog ·' "$TF/af2.log")" "0"
# AF2 PASS — exit = 0, watchdog line = 0.

# AF3 — regression: transcript flat, session dir flat, and a live descendant whose CPU ticks stay
# flat is still killed, worded "no progress" not "no CPU progress"
cd "$TF/repo"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-v" ] && { echo "stub-claude 0.0.0"; exit 0; }\necho "stub af3"\nsleep 1000 &\nwait\n' > "$TF/bin/claude"
chmod +x "$TF/bin/claude"
PATH="$TF/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 90 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TF/af3.log" 2>&1
# the watchdog's kill is a restart, not a failure of the run
check "AF3 exit" "$?" "0"
# an idle descendant, sleeping, ticks no CPU
check "AF3 watchdog line" "$(grep -c '❄ Watchdog · no progress from claude for 5s' "$TF/af3.log")" "1"
# the exit-reason text
check "AF3 code text present" "$([ "$(grep -c 'no progress for 5s' "$TF/af3.log")" -ge 1 ] && echo yes || echo no)" "yes"
# the stale wording is gone
check "AF3 no CPU wording" "$(grep -c 'no CPU progress' "$TF/af3.log")" "0"
# AF3 PASS — exit = 0, watchdog line = 1, code text >= 1, no CPU wording = 0.

# AF4 — absence: no new liveness-detection environment variable, and transcript_mtime is still
# sampled every tick
# the three liveness signals still share KAIZERO_WATCHDOG alone — KAIZERO_WATCHDOG_GRACE is a
# later, separate knob (the SIGTERM→SIGKILL escalation delay, not liveness detection), so it's
# the one KAIZERO_WATCHDOG_* name this count expects, not a sign the three signals fragmented.
check "AF4 no new env var" "$(grep -c 'KAIZERO_WATCHDOG_' "$REAL_SCRIPT")" "1"
# the original signal is not replaced
check "AF4 mtime kept" "$([ "$(grep -c 'transcript_mtime "\$tp"' "$REAL_SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
# AF4 PASS — no new env var = 0, mtime kept >= 1.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
