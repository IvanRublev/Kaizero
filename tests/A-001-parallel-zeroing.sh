#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=610s
# KAIZERO_NEEDS_REAL_CLAUDE=1
# KAIZERO_TEST_ISOLATED=1
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# A-001-parallel-zeroing — parallel zeroing + restart-resume + timing. 3 agents zero one todo in
# parallel; the script restarts each claude after every task (KAIZERO_MAX_LOOPS) and resumes.
# Also asserts the per-instance execution-time report and env-hop.
# Needs real claude: yes — it launches real claude sessions.
# Tools beyond the shared prerequisites: none.
# Folder under $TESTROOT: none — A/C use a fixed, pre-trusted $T under $ANCHOR instead (see
# TEST.md Prerequisites).
# Wall-clock budget: its longest Run command is `timeout 480` — allow that command at least 480s.
#
# KAIZERO_MAX_LOOPS=4 makes kaizero restart claude after each session; the -t prompt forces
# one task per session, so completing all five requires restart + resume — a broken restart would
# leave a missing/duplicate marker. The barrier (need=3) proves 3-way overlap. The extra timing
# asserts confirm each instance printed its own execution-time report and that
# KAIZERO_INSTANCE reached zero.sh.

# Setup
T="$HOME/.kaizero-test-root/A-001-parallel-zeroing"   # fixed, trusted once out-of-band — NOT under $TESTROOT (see TEST.md Prerequisites)
jq -e --arg p "$T/repo" '.projects[$p].hasTrustDialogAccepted == true' "$HOME/.claude.json" >/dev/null 2>&1 \
  || { echo "REFUSING: $T/repo is not trusted in ~/.claude.json — trust it once (see TEST.md Prerequisites) before running this scenario" >&2; exit 1; }
[ -d "$T" ] && find "$T" -mindepth 1 -delete   # reset from any previous run; $T itself stays (that's the trusted path)
mkdir -p "$T/repo"
write_gate "$T/gate.sh"
cd "$T/repo"
git init -q; git config user.email t@t.t; git config user.name test
U=(); for i in 1 2 3 4 5; do U+=("$(uuidgen)"); done
: > todo.md
for i in 1 2 3 4 5; do
  echo "- [ ] T$i In your task worktree do IN ORDER: (a) run \`$T/gate.sh <your label>\` and wait for it to exit 0; (b) create file markers/${U[i-1]}.done whose only line is \`agent=<your label> task=T$i\`; (c) commit. If the gate command exits non-zero, STOP and report failure." >> todo.md
done
mkdir -p tasks
for i in 1 2 3 4 5; do printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/T$i.md"; done
git add -A; git commit -qm todo
printf '%s\n' "${U[@]}" > "$T/uuids.txt"

# A1 — 3 agents zero one todo in parallel, with restart-resume and per-instance timing
cd "$T/repo"
run(){ timeout -k 10 480 env KAIZERO_MAX_LOOPS=4 bash "$SCRIPT" --local-merge todo.md \
  -t "You are agent $1. Process EXACTLY ONE unchecked task this session: do exactly what its line instructs (run the gate command it names and wait for that command to exit 0 before continuing), commit, and let the task merge. Then STOP — end the session without starting another task, so you can be restarted fresh for the next one. Any marker file must contain the single line: agent=$1 task=<that task's id>. Put $1 in every commit message." \
  > "$T/log_$1.txt" 2>&1; }
run AGENT_A & run AGENT_B & run AGENT_C &
wait

cd "$T/repo"
while read -r u; do [ -f "markers/$u.done" ] || echo "MISSING marker $u"; done < "$T/uuids.txt"
echo "--- markers (task -> agent) ---"; grep -h . markers/*.done 2>/dev/null | sort
check "distinct agents" "$(grep -h -o 'agent=[^ ]*' markers/*.done 2>/dev/null | sort -u | wc -l | tr -d ' ')" "3"
check "todos checked" "$(grep -c '^- \[x\]' todo.md)/5" "5/5"
check "git clean" "$([ -z "$(git status --porcelain)" ] && echo yes || echo no)" "yes"
check "latch opened" "$([ -f "$T/gate/opened" ] && echo yes || echo no)" "yes"
echo "restarts (A/B/C): $(grep -c restarting "$T/log_AGENT_A.txt") $(grep -c restarting "$T/log_AGENT_B.txt") $(grep -c restarting "$T/log_AGENT_C.txt")"
# timing / per-instance isolation:
check "instance ids" "$(grep -h -oE 'instance [^)]+' "$T"/log_AGENT_*.txt | sort -u | wc -l | tr -d ' ')" "3"
echo "report labels   : $(grep -h -cE '  (Tasks|Kaizero run loop):' "$T"/log_AGENT_A.txt | tr -d ' ')"
check "stale loop line" "$(grep -h -c 'Claude loops:' "$T"/log_AGENT_A.txt | tr -d ' ')" "0"
echo "todos counted   : $(awk '/❄ TOTAL/{exit} /Tasks:.*·[[:space:]]+[0-9]+ Landed/{l=$0} END{print l}' "$T"/log_AGENT_A.txt)"
# each agent ended its run with one fleet TOTAL block
check "TOTAL blocks" "$(grep -h -c '❄ TOTAL' "$T"/log_AGENT_*.txt | paste -sd' ' -)" "1 1 1"
echo "zero.sh wrote files: $(find "$T/repo/.git" -maxdepth 1 -name 'todos-seconds-*' 2>/dev/null | wc -l | tr -d ' ')"
echo "zero.sh wrote counts: $(find "$T/repo/.git" -maxdepth 1 -name 'todos-done-*' 2>/dev/null | wc -l | tr -d ' ')"
# five tasks landing from three parallel instances, each ticked by zero.sh serially under
# MERGE_LOCK — adjacent lines never conflict because the agent never writes the todo file at all
check "tick commits" "$(git -C "$T/repo" log --oneline | grep -c '^[0-9a-f]* zero ')" "5"
# A1 PASS — all 5 markers present, todos checked = 5/5, git clean = yes (zeroing); latch opened =
# yes AND distinct agents = 3 (parallel); restarts summed across the three logs >= 3
# (restart-resume); instance ids = 3 (each instance a distinct id -> isolation), each agent's log
# shows the Tasks:/Kaizero run loop: lines with stale loop line = 0, todos counted shows a
# non-zero N Landed for an agent that merged, the per-agent counts sum to 5, and zero.sh wrote
# files >= 1 / zero.sh wrote counts >= 1 — the env-hop proof: zero.sh only writes
# todos-seconds-<base>-<id> and todos-done-<base>-<id> when it received KAIZERO_INSTANCE from
# claude's env (an instance that merged 0 tasks writes no file, so the count can be < 3; >= 1 is
# the gate) (timing); TOTAL blocks = 1 1 1: each agent ended its run with one fleet TOTAL block,
# the todos counted reading taken from before it so it stays the per-instance figure (fleet);
# tick commits = 5.

# A/C only: $T lives outside $TESTROOT (a fixed, pre-trusted coordination repo), so neither
# shared teardown script ever touches it — reset its contents directly. Never remove $T itself:
# that exact path is what stays permanently trusted.
[ -d "$T" ] && find "$T" -mindepth 1 -delete
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
