#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=47s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# AG-001-kill-tree-self-descendant — kill_tree signals the pid it was called with even when its
# own running process turns up as a descendant of that pid during the walk (BUG-058b).
# Needs real claude: no.
# Tools beyond the shared prerequisites: none.
# Folder under $TESTROOT: $TESTROOT/AG-001-kill-tree-self-descendant
# Wall-clock budget: its longest Run command (G3) polls up to 15s — allow at least 30s for the
# whole case.
#
# A Stop hook (or the watchdog's on_term) runs kill_tree from inside the very tree it was asked
# to kill — its own pid shows up as a descendant of the owner pid mid-walk. kill_tree must still
# signal the owner pid; a depth-first walk that signals descendants before the owner can kill the
# walker itself before it ever reaches the owner.
# BUG-058k: kill_tree/kill_tree_descendants no longer live in kaizero.sh itself — they exist
# in exactly one place now, terminator.sh's own emitted heredoc (write_terminator_sh) — so there
# is only one copy to check directly (G1), not two. G2 below is the more important coverage post-
# 058k: it drives the real emitted Stop hook end to end, through term_owner -> terminator.sh's own
# sequence, which never lets the tree-walk (kill_tree_descendants, run against the wrapper's
# descendants) or the final direct `kill -9 "$WRAPPER_PID"` signal the wrapper before claude
# itself is confirmed dead.

# Setup
TG="$TESTROOT/AG-001-kill-tree-self-descendant"; mkdir -p "$TG/bin"
extract_kill_tree() {
  # nth "kill_tree() {" ... matching "}" body in $REAL_SCRIPT
  awk -v n="$1" '
    /^kill_tree\(\) \{$/ { c++; if (c==n) { p=1 } }
    p { print }
    p && /^}$/ { exit }
  ' "$REAL_SCRIPT"
}
write_target() {
  # $1 = occurrence index, $2 = output path. The target script defines kill_tree, then forks a
  # child that calls kill_tree on the target's OWN pid — that child is thus a live descendant of
  # the pid kill_tree is told to kill, reproducing the Stop-hook-inside-its-own-tree case. The
  # trailing `sleep 30` after `wait` is load-bearing: without it the target script falls off its
  # own end and exits on its own the instant the (killed) child job is reaped, regardless of
  # whether kill_tree ever reached MYPID — indistinguishable from the fix actually working. 30s
  # is well past this scenario's own poll window (3s) so a target that survives kill_tree is
  # reliably caught still running, not racing the poll against its own natural exit.
  { printf '#!/usr/bin/env bash\n'
    extract_kill_tree "$1"
    printf '\nMYPID=$$\n( kill_tree TERM "$MYPID" ) &\nwait\nsleep 30\n'
  } > "$2"
  chmod +x "$2"
}

# G1 — the sole copy (terminator.sh's own kill_tree, emitted by write_terminator_sh): owner pid dies
write_target 1 "$TG/bin/target1.sh"
bash "$TG/bin/target1.sh" > "$TG/target1.out" 2>&1 &
TPID=$!
# poll window (3s) is well short of the target's own 30s fallback sleep, so "still alive at the
# end of the poll" reliably means kill_tree never reached the owner pid, not a race against its
# natural exit
i=0; while kill -0 "$TPID" 2>/dev/null && [ "$i" -lt 12 ]; do sleep 0.25; i=$((i+1)); done
kill -0 "$TPID" 2>/dev/null; ALIVE=$?
kill -KILL "$TPID" 2>/dev/null; wait "$TPID" 2>/dev/null
# dead, kill_tree reached the owner pid
check "G1 target alive after self-descendant kill_tree" "$ALIVE" "1"
# G1 PASS — target alive after self-descendant kill_tree = 1.

# G2 — the real emitted Stop hook (term_owner/compact-exit-hook.sh), run as a child of the owner
# it is asked to kill, still ends the owner within WATCHDOG_GRACE — the exact reproduction from
# BUG-058b's Steps to reproduce, with a disposable stub standing in for claude/script (this
# suite's standard driver pattern; see tests/AE-001-term-owner-escalation.sh)
cd "$TG"
mkdir -p "$TG/g3repo"
cd "$TG/g3repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] G2 x\n' > todo.md; git add -A; git commit -qm init
KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1   # writes the real emitted hook, no claude needed
HOOK="$TG/g3repo/.git/compact-exit-hook.sh"
# OWNER stands in for the `script` pty wrapper: it launches the hook itself as ITS OWN CHILD
# (exactly how a real Stop hook runs — a child of the session it is asked to end), with a
# session record pointing at OWNER's own pid, then sleeps well past WATCHDOG_GRACE so "OWNER
# gone" can only be kill_tree actually reaching it.
cat > "$TG/g3owner.sh" <<EOF
#!/usr/bin/env bash
MYPID=\$\$
st="\$(ps -o lstart= -p "\$MYPID" 2>/dev/null | awk '{\$1=\$1;print}')"
printf '%s\n%s\n%s\n' "\$MYPID" "\$st" 1 > "$TG/g3.rec"
printf 'x\n' > "$TG/g3.safe"
KAIZERO_INSTANCE=AG001G2 KAIZERO_SESSION_RECORD="$TG/g3.rec" KAIZERO_SESSION_EPOCH=1 \
  KAIZERO_SAFE_TO_EXIT="$TG/g3.safe" KAIZERO_EXIT_REASON="$TG/g3.reason" \
  bash -c 'printf "%s" "{}" | bash "\$1" >/dev/null 2>&1' _ "$HOOK" &
wait
sleep 30
EOF
chmod +x "$TG/g3owner.sh"
bash "$TG/g3owner.sh" > "$TG/g3owner.out" 2>&1 &
OPID=$!
t0=$(date +%s)
i=0; while kill -0 "$OPID" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.5; i=$((i+1)); done
t1=$(date +%s)
kill -0 "$OPID" 2>/dev/null; ALIVE=$?
kill -KILL "$OPID" 2>/dev/null; wait "$OPID" 2>/dev/null
check "G2 owner dead" "$ALIVE" "1"
# WATCHDOG_GRACE=10 plus a small margin
check "G2 within WATCHDOG_GRACE+margin" "$([ $((t1 - t0)) -le 15 ] && echo yes || echo "no ($((t1 - t0)))")" "yes"
# term_owner's ordinary safe-to-exit value
check "G2 exit reason written" "$(head -n1 "$TG/g3.reason" 2>/dev/null)" "0"
# G2 PASS — owner dead = 1, within WATCHDOG_GRACE+margin = yes, exit reason written = 0.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
