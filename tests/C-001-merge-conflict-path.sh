#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=310s
# KAIZERO_NEEDS_REAL_CLAUDE=1
# KAIZERO_TEST_ISOLATED=1
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCENARIO_DIR/test-setup.sh"

# C-001-merge-conflict-path — merge-conflict path. two tasks edit the same line; one merges, the
# other hits a conflict, and the zero run aborts cleanly leaving the base green and the branch
# for a human.
# Needs real claude: yes — it launches real claude sessions
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/C-001-merge-conflict-path
# Wall-clock budget: its longest Run command is `timeout 240` — allow that command at least 240s
#
# Two tasks overwrite the same line of conflict.txt. The barrier (need=2) forces both agents to
# branch off the same base before either merges, so the second merge is a guaranteed
# modify/modify conflict. Kaizero must abort it, keep the base green, and leave the losing
# branch for a human (zero algorithm, step 2.e).

TC="$HOME/.kaizero-test-root/C-001-merge-conflict-path"   # fixed, trusted once out-of-band — NOT under $TESTROOT (see TEST.md Prerequisites)
jq -e --arg p "$TC/repo" '.projects[$p].hasTrustDialogAccepted == true' "$HOME/.claude.json" >/dev/null 2>&1 \
  || { echo "REFUSING: $TC/repo is not trusted in ~/.claude.json — trust it once (see TEST.md Prerequisites) before running this scenario" >&2; exit 1; }
[ -d "$TC" ] && find "$TC" -mindepth 1 -delete   # reset from any previous run; $TC itself stays (that's the trusted path)
mkdir -p "$TC/repo"
write_gate "$TC/gate.sh"
cd "$TC/repo"
git init -q -b master; git config user.email t@t.t; git config user.name test
echo INIT > conflict.txt
: > todo.md
for i in 1 2; do
  echo "- [ ] C$i In your task worktree do IN ORDER: (a) run \`$TC/gate.sh <your label> 2\` and wait for it to exit 0; (b) overwrite conflict.txt so its ONLY line is \`owner=<your label>\`; (c) commit." >> todo.md
done
mkdir -p tasks
for i in 1 2; do printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/C$i.md"; done
git add -A; git commit -qm init

# C1 — two tasks conflict; the losing merge is refused cleanly, base green, branch kept for a human
cd "$TC/repo"
runc(){ timeout -k 10 240 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md \
  -t "You are agent $1. Do exactly what the task line instructs (run its gate command and wait for exit 0, make the edit, commit). Follow the zero algorithm's merge-failure handling: if your merge fails, STOP and report the conflicting task and its worktree to the human." \
  > "$TC/log_$1.txt" 2>&1; }
runc AGENT_A & runc AGENT_B &
wait
# Everything asserted here belongs to kaizero.sh, never to what the agent decides after a
# refused merge. Both readings of the task prompt are legitimate — stop and report, or merge the
# base into the task branch, resolve, and re-merge — and a real claude picks either run to run, so
# the todo count and the leftover-branch count are model behaviour, not the script's contract, and
# asserting them would make this scenario flake. What the script owes is the same either way: the
# conflicting merge never lands, the base is never left mid-merge or carrying conflict markers,
# and a box is only ever ticked once its code is on the base.
cd "$TC/repo"
check "base clean" "$([ -z "$(git status --porcelain)" ] && echo yes || echo no)" "yes"
check "merge in progress" "$([ -e .git/MERGE_HEAD ] && echo yes || echo no)" "no"
# a refused merge leaves none behind
check "no conflict markers on base" "$(git grep -lE '^(<<<<<<<|>>>>>>>) ' -- . 2>/dev/null | wc -l | tr -d ' ')" "0"
# one winner's line, whole
check "conflict.txt is one owner line" "$([ "$(wc -l < conflict.txt | tr -d ' ')" = 1 ] && grep -qE '^owner=AGENT_[AB]$' conflict.txt && echo yes || echo no)" "yes"
# the land gate ticks a box only after its code merged
check "every ticked box has landed work" "$([ "$(grep -c '^- \[x\]' todo.md)" = "$(git log --format=%s | grep -c '^zero C')" ] && echo yes || echo no)" "yes"
# never a half-merge
check "one merge commit per landed task" "$([ "$(git log --format=%s | grep -c '^merge master-task-C')" = "$(git log --format=%s | grep -c '^zero C')" ] && echo yes || echo no)" "yes"
# informational only — 1 if the agent stopped, 2 if it resolved, not asserted
echo "todos checked : $(grep -c '^- \[x\]' todo.md)/2"
echo "leftover branches :"; git branch --list '*-task-*'
check "log notes conflict" "$(grep -Eril 'conflict|merge fail|resolve|stop' "$TC"/log_*.txt >/dev/null && echo yes || echo no)" "yes"
# C1 PASS — base clean = yes, merge in progress = no, no conflict markers on the base,
# conflict.txt holds one whole winner line, every ticked box has a landed zero C<n> commit
# behind it, merge commits and landed tasks agree one-for-one, and a log notes the conflict. The
# todos checked line is printed for the reader, not asserted: the second merge is always refused
# (exit 2, base green, branch kept), and whether the agent then stops or resolves and re-merges is
# its call, not the script's.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
# A and C only: reset the fixed coordination directory directly — it lives outside $TESTROOT and
# neither shared teardown script ever touches it. Never remove $TC itself; that exact path is
# what stays permanently trusted.
find "$TC" -mindepth 1 -delete
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
