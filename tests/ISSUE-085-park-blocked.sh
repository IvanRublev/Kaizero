#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=120s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# ISSUE-085-park-blocked — `zero.sh park` hands a claimed Task back as `[🚧]`: Blocked line
# required, work committed to the kept branch, worktree gone, base touched only by the box tick and
# the Blocked line, ownership refusals as merge's, todo-list shows the Blocked line, a cleared box
# reclaims the kept branch.
# Needs real claude: no — a stub `claude` stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/ISSUE-085-park-blocked

TR="$TESTROOT/ISSUE-085-park-blocked"; mkdir -p "$TR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/claude"; chmod +x "$TR/bin/claude"
export KAIZERO_INSTANCE=ti1
BLK='> Blocked 2026-10-03 12:00+0000 shared limiter rejects every test run; evidence: HTTP 429 from the limiter; unblocks when: the limiter quota resets'

d="$TR/one"; mkdir -p "$d/tasks"; cd "$d"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] B1 blocked task\n- [ ] B2 plain task\n- [ ] B3 held task\n' > todo.md
for i in B1 B2 B3; do printf '### Acceptance criteria\n\n- [ ] first\n- [ ] second\n' > "tasks/$i.md"; done
echo base > f.txt
git add -A; git commit -qm init
KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
Z="$d/.git/zero.sh"; G="$d/.git"
own_session "$TR/session1"

# add_blocked <id>: the session's own write — the Blocked line at the end of the AC section
add_blocked(){ printf '%s\n' "$BLK" >> "$d/tasks/$1.md"; }

# --- refusal without a Blocked line
t2=$("$Z" claim B2)
out=$("$Z" park B2 2>&1); rc=$?
check "A1 park without Blocked line exits 5" "$rc" "5"
check "A1 stderr names the missing line" "$(printf '%s' "$out" | grep -c 'Blocked')" "1"
check "A1 box stays [ ]" "$(grep -c '^- \[ \] B2' todo.md)" "1"
check "A1 worktree stays" "$([ -d "$t2" ] && echo yes)" "yes"
check "A1 branch stays" "$(git rev-parse -q --verify main-task-B2 >/dev/null && echo yes)" "yes"
"$Z" release B2 >/dev/null 2>&1

# --- park B1 with ticked criteria, no gate notes, uncommitted + untracked work
t1=$("$Z" claim B1)
echo wip > "$t1/f.txt"; echo new > "$t1/untracked.txt"
printf '### Acceptance criteria\n\n- [x] first\n  > 2026-10-03 11:00+0000 done before the block\n- [ ] second\n' > "$d/tasks/B1.md"
add_blocked B1
ac_before=$(sed '/^> Blocked/d' tasks/B1.md)
main_before=$(git rev-parse main)
refs_before=$(git for-each-ref --format='%(refname)' | sort)
out=$("$Z" park B1 2>&1); rc=$?
check "A2 park exits 0" "$rc" "0"
check "A2 single stdout line" "$out" "park B1: blocked as [🚧]; worktree removed, branch main-task-B1 kept"
check "A2 box [🚧] on base" "$(git show main:todo.md | grep -c '^- \[🚧\] B1')" "1"
check "A2 worktree removed" "$([ -d "$t1" ] && echo yes || echo no)" "no"
check "A2 branch kept" "$(git rev-parse -q --verify main-task-B1 >/dev/null && echo yes)" "yes"
check "A3 tracked wip committed to branch" "$(git show main-task-B1:f.txt)" "wip"
check "A3 untracked file committed to branch" "$(git show main-task-B1:untracked.txt)" "new"
check "A4 ticked criteria and evidence unchanged" "$(git show main:tasks/B1.md | sed '/^> Blocked/d')" "$ac_before"
check "A5 park with ticked criteria and no gate notes accepted" "$rc" "0"
check "A6 base differs only by todo.md and the task file" "$(git diff --name-only "$main_before" main | sort | tr '\n' ' ')" "tasks/B1.md todo.md "
check "A6 branch commits not on base" "$(git merge-base --is-ancestor main-task-B1 main && echo yes || echo no)" "no"
check "A7 Blocked line committed on base" "$(git show main:tasks/B1.md | grep -c '^> Blocked')" "1"
check "A8 Blocked line commit not in branch history" "$(git log --format=%s main-task-B1 | grep -c 'commit_ac_checkoff')" "0"
check "A9 no ref created or deleted" "$(git for-each-ref --format='%(refname)' | sort | diff - <(printf '%s\n' "$refs_before") >/dev/null && echo same)" "same"
check "A9 no [?] written" "$(git show main:todo.md | grep -c '^- \[?\]')" "0"
check "A10 blocked counted" "$(cat "$G/todos-blocked-main-ti1" 2>/dev/null)" "1"
check "A10 landed count untouched" "$(cat "$G/todos-done-main-ti1" 2>/dev/null || echo 0)" "0"
check "A10 machine landed count untouched" "$(cat "$XDG_STATE_HOME/kaizero/landed-count" 2>/dev/null || echo 0)" "0"
check "A11 session state cleared" "$(cat "$G/session/$$" | sed -n 2p)" "none"

# --- todo-list and claim after park
tl=$("$Z" todo-list)
check "B1 Blocked line lists B1" "$(printf '%s\n' "$tl" | grep -c '^Blocked: B1$')" "1"
check "B1 Landed line omits B1" "$(printf '%s\n' "$tl" | grep '^Landed:' | grep -c 'B1')" "0"
check "B1 not offered as candidate" "$(printf '%s\n' "$tl" | grep -c '^- \[ \] B1')" "0"
"$Z" claim B1 > "$TR/claim-blocked.out" 2>&1; rc=$?
check "B2 claim of a blocked id refused" "$([ "$rc" != 0 ] && echo refused)" "refused"
check "B2 branch survives the refused claim" "$(git rev-parse -q --verify main-task-B1 >/dev/null && echo yes)" "yes"

# --- reclaim after a human clears the box
sed -i.bak 's/^- \[🚧\] B1/- [ ] B1/' todo.md; rm -f todo.md.bak
git add todo.md; git commit -qm "human clears the box"
t1b=$("$Z" claim B1); rc=$?
check "C1 reclaim exits 0" "$rc" "0"
check "C1 kept work present in the new worktree" "$(cat "$t1b/untracked.txt" 2>/dev/null)" "new"
check "C1 Blocked line stays in the Task file on base" "$(git show main:tasks/B1.md | grep -c '^> Blocked')" "1"
"$Z" release B1 >/dev/null 2>&1

# --- ownership refusals, nothing committed, ticked or removed
t3=$("$Z" claim B3)
sleep 300 & other=$!
own_session "$TR/session2" "$other"
before=$(git rev-parse main)
out=$("$Z" park B3 2>&1); rc=$?
check "D1 park by a session that never claimed exits 9" "$rc" "9"
mkdir -p "$G/session"
printf '%s\n%s\n' "$(ps -o lstart= -p "$other" | awk '{$1=$1;print}')" B3 > "$G/session/$other"
add_blocked B3
out=$("$Z" park B3 2>&1); rc=$?
check "D2 park against a Task a live peer holds exits 6" "$rc" "6"
check "D2 nothing committed" "$(git rev-parse main)" "$before"
check "D2 box stays" "$(grep -c '^- \[ \] B3' todo.md)" "1"
check "D2 worktree stays" "$([ -d "$t3" ] && echo yes)" "yes"
kill "$other" 2>/dev/null
own_session "$TR/session1"

# --- park runs one at a time with merge: it waits for the merge lock another call holds
"$Z" release B3 >/dev/null 2>&1
t2=$("$Z" claim B2); add_blocked B2
flock "$G/merge.lock" sleep 3 & holder=$!
sleep 0.5
t0=$(date +%s)
"$Z" park B2 >/dev/null 2>&1; rc=$?
check "E1 park waited for the merge lock, then exited 0" "$rc $([ $(( $(date +%s) - t0 )) -ge 2 ] && echo waited)" "0 waited"
wait "$holder" 2>/dev/null

cd "$TESTROOT"
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
