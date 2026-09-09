#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=228s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# M-001-one-task-per-session — one task per session, the shell waits. The claimable-task probe
# lives in the shell now: nothing left -> close; everything unchecked held by a live peer -> wait
# with no claude launched; anything free (including a crashed peer's branch) -> launch.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/M-001-one-task-per-session
#
# The claimable probe moved out of claude and into the shell: nothing left -> the closer;
# everything unchecked held by a LIVE peer -> wait, launching no claude at all; anything free
# (including a crashed peer's branch, which only claude can rescue) -> launch. The Stop hook is
# the other half — it ends the session at every turn end, so one session zeroes one task; a hook
# fired outside a Kaizero session kills nothing, leaving only the context-rot guard.

TM="$TESTROOT/M-001-one-task-per-session"; mkdir -p "$TM/repo" "$TM/bin"
cat > "$TM/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$STUB_LAUNCHED"
exit 0
EOF
chmod +x "$TM/bin/claude"
cd "$TM/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] M1 x\n' > todo.md; git add -A; git commit -qm init
# a LIVE peer holding M1: claim branch + worktree .owner + session marker, exactly what
# zero.sh's acquire writes and what held_todos reads back.
sleep 600 > "$TM/peer.out" 2>&1 &
PEER=$!
git worktree add -q -b main-task-M1 "$TM/wt1" main
printf '%s\n%s\n%s\n%s\n' "$PEER" "$(ps -o lstart= -p "$PEER" | awk '{$1=$1;print}')" "$(date +%s)" "PEERINST" > "$TM/wt1/.owner"
mkdir -p "$TM/repo/.git/session"
printf '%s\n%s\n' "$(ps -o lstart= -p "$PEER" | awk '{$1=$1;print}')" "M1" > "$TM/repo/.git/session/$PEER"

# M1 — every unchecked task peer-held: no claude, plain waiting lines when stdout is not a tty
cd "$TM/repo"
export STUB_LAUNCHED="$TM/launched"; : > "$STUB_LAUNCHED"
# stands in for the caller's own session: Claude Code exports CLAUDE_PID
sleep 600 > "$TM/decoy.out" 2>&1 &
DECOY=$!
PATH="$TM/bin:$PATH" CLAUDE_PID=$DECOY timeout 55 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TM/wait.log" 2>&1
# still waiting when the timeout fired, never launched
check "M1 exit" "$?" "124"
# the TERM trap must never kill an INHERITED CLAUDE_PID; nothing was launched yet
check "M1 decoy alive" "$(kill -0 $DECOY 2>/dev/null && echo yes || echo no)" "yes"
kill "$DECOY" 2>/dev/null; wait "$DECOY" 2>/dev/null || true
# no claude process, no transcript, no tokens
check "M1 launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "0"
# LOG_TICK=20 over a 55s wait — ticks land at ~0/20/40s; a 60s fourth tick would also fit inside a
# wider ceiling, so 55s stays strictly between the third tick and the fourth, a real 15s margin
# under load, NOT one per WAIT_TICK probe
check "M1 waiting line" "$(grep -c 'Waiting for a claimable Task · 1 held by peers' "$TM/wait.log")" "3"
# -F, two -e patterns: \| alternation is a GNU BRE extension and \033[ leaves an unbalanced
# bracket, so the single-pattern form dies "brackets not balanced" on the macOS leg's BSD grep
check "M1 no escapes" "$(LC_ALL=C grep -cF -e $'\r' -e $'\033[' "$TM/wait.log")" "0"
# exit = 124, decoy alive = yes, launches = 0, waiting line = 3, no escapes = 0.


# M2 — a dead peer's branch is claimable: claude IS launched to rescue it
cd "$TM/repo"
kill "$PEER" 2>/dev/null; wait "$PEER" 2>/dev/null || true
: > "$STUB_LAUNCHED"
PATH="$TM/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TM/rescue.log" 2>&1
check "M2 exit" "$?" "0"
# held_todos counts only LIVE owners, else a crash parks the fleet forever
check "M2 launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "1"
check "M2 no wait line" "$(grep -c 'waiting for a claimable Task' "$TM/rescue.log")" "0"
# exit = 0, launches = 1, no wait line = 0.

# M3 — every box checked: the closer runs, claude never starts
cd "$TM/repo"
git worktree remove --force "$TM/wt1"; git branch -qD main-task-M1
printf -- '- [x] M1 x\n' > todo.md; git add -A; git commit -qm "done"
: > "$STUB_LAUNCHED"
PATH="$TM/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TM/done.log" 2>&1
check "M3 exit" "$?" "0"
# nothing to zero, so nothing to launch
check "M3 launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "0"
# broke straight to the closer
check "M3 closing report" "$([ "$(grep -c 'Execution stats' "$TM/done.log")" -ge 1 ] && echo yes || echo no)" "yes"
# exit = 0, launches = 0, closing report >= 1.

# M4 — the Stop hook: ends a Kaizero turn only once something signals it is safe to
cd "$TM/repo"
KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
HOOK="$TM/repo/.git/compact-exit-hook.sh"
# BUG 057: the old channel drove the hook under a decoy claude ancestor (a real bash binary named
# claude) and read term_owner's verdict off THAT ancestor's own exit status (143 = it got
# SIGTERMed). The gate + session record replace it: run_hook backgrounds a disposable stub, writes
# it a session record naming its pid/proc_start/epoch, and hands the hook that record through the
# environment the way kaizero.sh itself would — the verdict is then whether the STUB survived
# (0 = left alone) or was SIGTERMed (143), the same two values every assertion below already wants.
# $MARK is the env prefix that decides whether this session carries Kaizero's instance marker;
# $SAFE_ENV decides whether it carries a safe-to-exit marker file. Both unset forms have to be an
# explicit env -u, since an agent running this file autonomously already has KAIZERO_INSTANCE
# (and, potentially, a stale KAIZERO_SAFE_TO_EXIT) in its own env.
SAFE="$TM/safe-to-exit"
MARK=(-u KAIZERO_INSTANCE); SAFE_ENV=(-u KAIZERO_SAFE_TO_EXIT)
run_hook(){ local payload="$1"
  bash -c 'sleep 60 & wait' > "$TM/own-session-stub.out" 2>&1 &
  local stub=$!
  local rec="$TM/rec-$stub" st
  st="$(ps -o lstart= -p "$stub" 2>/dev/null | awk '{$1=$1;print}')"
  printf '%s\n%s\n%s\n' "$stub" "$st" 1 > "$rec"
  env "${MARK[@]}" "${SAFE_ENV[@]}" KAIZERO_SESSION_RECORD="$rec" KAIZERO_SESSION_EPOCH=1 \
    KAIZERO_EXIT_REASON="$TM/reason-$stub" \
    bash -c 'printf "%s" "$2" | bash "$1" >/dev/null 2>&1' _ "$HOOK" "$payload"
  sleep 0.3
  if kill -0 "$stub" 2>/dev/null; then
    kill -KILL "$stub" 2>/dev/null; wait "$stub" 2>/dev/null
    echo 0
  else
    wait "$stub" 2>/dev/null
    echo 143
  fi
}
run_as_claude(){ run_hook "$1"; }

MARK=(-u KAIZERO_INSTANCE)
# a hand-fired hook kills nothing, regardless of the safe-to-exit marker
check "M4 marker unset" "$(run_as_claude '{}')" "0"

MARK=(KAIZERO_INSTANCE=a1b2c3d4)
: > "$SAFE"; SAFE_ENV=(KAIZERO_SAFE_TO_EXIT="$SAFE")
# turn ended but nothing signaled safe-to-exit; the fork-still-running case
check "M4 not safe yet" "$(run_as_claude '{}')" "0"

printf 'x\n' > "$SAFE"
# the marker is set, ordinary turn end SIGTERMs the owning claude
check "M4 safe to exit" "$(run_as_claude '{}')" "143"

: > "$SAFE"   # empty again — the guard below must still fire without a safe-to-exit signal
# a transcript whose newest usage record is at/over claude-opus-5's 200000 threshold
# (9000 + 250000 + 1000 = 260000) — the context-rot guard's own trigger shape.
TP="$TM/ctx-over.jsonl"
printf '%s\n' '{"type":"assistant","requestId":"r1","message":{"model":"claude-opus-5","usage":{"input_tokens":9000,"cache_read_input_tokens":250000,"cache_creation_input_tokens":1000,"output_tokens":500}}}' > "$TP"
# the context-rot guard is unchanged, forced, and still first — fires even with an empty
# safe-to-exit marker
check "M4 bucket branch" "$(run_as_claude "$(printf '{"transcript_path":"%s"}' "$TP")")" "143"
rm -f "$TP" "$SAFE"
# marker unset = 0, not safe yet = 0, safe to exit = 143, bucket branch = 143.

# M5 — SAFE_TO_EXIT_FILE is truncated before every launch, never carried over from the last one
cd "$TM/repo"
printf -- '- [ ] M5 x\n' > todo.md; git add -A; git commit -qm "M5 fixture"
: > "$TM/m5launched"
cat > "$TM/bin/claude" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
n=\$(( \$(wc -l < "$TM/m5launched" 2>/dev/null | tr -d ' ') + 1 ))
echo launched >> "$TM/m5launched"
if [ "\$n" -eq 1 ]; then
  printf 'stale\n' > "\$KAIZERO_SAFE_TO_EXIT"   # simulate a prior turn that landed a task, marker left non-empty
else
  echo "\$([ -s "\$KAIZERO_SAFE_TO_EXIT" ] && echo STALE || echo clean)" > "$TM/m5-second-launch.state"
fi
exit 0
EOF
chmod +x "$TM/bin/claude"
PATH="$TM/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge todo.md -t x > "$TM/m5.log" 2>&1
check "M5 launches" "$(wc -l < "$TM/m5launched" | tr -d ' ')" "2"
# the first launch's marker must not survive into the second launch's own SAFE_TO_EXIT_FILE reset
check "M5 second launch safe" "$(cat "$TM/m5-second-launch.state" 2>/dev/null)" "clean"
# launches = 2, second launch safe = clean.
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
