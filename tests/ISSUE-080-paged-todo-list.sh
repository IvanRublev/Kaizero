#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=120s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# ISSUE-080-paged-todo-list — `zero.sh todo-list [ID]` prints short pages (Landed line, leading
# context, held Tasks, three free Tasks, `Next page:` line); `zero.sh task-file ID` looks up a file.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/ISSUE-080-paged-todo-list
# Wall-clock budget: seconds — no Run command of this scenario wraps itself in `timeout`

TB="$TESTROOT/ISSUE-080-paged-todo-list"; mkdir -p "$TB/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TB/bin/claude"; chmod +x "$TB/bin/claude"
TAG=$' \xe2\x9a\x92\xef\xb8\x8f held by a live peer'
PEERS=()

# newrepo <name>: throwaway repo, real zero.sh emitted; leaves cwd inside, sets $ZERO
newrepo(){
  local d="$TB/$1"; mkdir -p "$d"; cd "$d"
  git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] SEED seed\n' > todo.md; mkdir -p tasks; git add -A; git commit -qm init
  KAIZERO_TEST_EMIT=1 PATH="$TB/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
  ZERO="$d/.git/zero.sh"; mkdir -p .git/session
}
# hold <id>: a LIVE peer holds the Task, exactly what acquire writes
hold(){
  sleep 600 > /dev/null 2>&1 & local p=$!; PEERS+=("$p")
  local st; st="$(ps -o lstart= -p "$p" | awk '{$1=$1;print}')"
  git worktree add -q -b "main-task-$1" "$PWD/../wt-$1" main
  printf '%s\n%s\n%s\n%s\n' "$p" "$st" "$(date +%s)" PEERINST > "$PWD/../wt-$1/.owner"
  printf '%s\n%s\n' "$st" "$1" > ".git/session/$p"
}
body(){ printf -- '### Acceptance criteria\n- [ ] a\n' > "tasks/$1.md"; }
ids(){ grep '^- \[ \] ' | awk '{print $4}' | tr '\n' ' '; }          # ids of unchecked lines
freeids(){ grep '^- \[ \] ' | grep -v 'held by a live peer' | grep '/tasks/' | awk '{print $4}' | tr '\n' ' '; }

# --- small list: L1..L3 landed, LQ other symbol, T01..T20; T03 T04 have no file
newrepo small
{ printf -- '- [x] L1 one\n- [x] L2 two\n- [x] L3 three\n'
  for i in $(seq -w 1 20); do
    printf -- '- [ ] T%s task %s\n' "$i" "$i"
    [ "$i" = 10 ] && printf -- '- [?] LQ review\n'
  done; } > todo.md
for i in $(seq -w 1 20); do case "$i" in 03|04) ;; *) body "T$i" ;; esac; done
for l in L1 L2 L3 LQ; do body "$l"; done
git add -A; git commit -qm list
hold T02; hold T12
P="$PWD/tasks"

"$ZERO" todo-list > "$TB/p1.out" 2> "$TB/p1.err"; rc=$?
check "P1 exit" "$rc" "0"; check "P1 stderr empty" "$(wc -c < "$TB/p1.err" | tr -d ' ')" "0"
exp1=$(printf -- 'Landed: L1 L2 L3\n- [x] L2 two\n- [x] L3 three\n- [ ] T01 task 01  %s/T01.md\n- [ ] T02%s task 02  %s/T02.md\n- [ ] T03 task 03\n- [ ] T04 task 04\n- [ ] T05 task 05  %s/T05.md\n- [ ] T06 task 06  %s/T06.md\n- [ ] T12%s task 12  %s/T12.md\nNext page: todo-list T06\n' "$P" "$TAG" "$P" "$P" "$P" "$TAG" "$P")
check "P1 first page exact" "$(diff <(printf '%s\n' "$exp1") "$TB/p1.out" > /dev/null && echo yes || echo NO)" "yes"

"$ZERO" todo-list T06 > "$TB/p2.out" 2>&1
exp2=$(printf -- '- [ ] T02%s task 02  %s/T02.md\n- [ ] T07 task 07  %s/T07.md\n- [ ] T08 task 08  %s/T08.md\n- [ ] T09 task 09  %s/T09.md\n- [ ] T12%s task 12  %s/T12.md\nNext page: todo-list T09\n' "$TAG" "$P" "$P" "$P" "$P" "$TAG" "$P")
check "P2 next page exact" "$(diff <(printf '%s\n' "$exp2") "$TB/p2.out" > /dev/null && echo yes || echo NO)" "yes"

# a resolved list built by the loop gives the same bytes as live resolution
"$ZERO" resolve-tasks > /dev/null 2>&1
check "P3 cached == live (page 1)" "$("$ZERO" todo-list 2>&1 | cmp -s - "$TB/p1.out" && echo same || echo DIFF)" "same"
check "P3 cached == live (page 2)" "$("$ZERO" todo-list T06 2>&1 | cmp -s - "$TB/p2.out" && echo same || echo DIFF)" "same"

# walk every page: each free Task once, in order; each no-file Task once; held on every page
walk=""; nofile=""; heldpages=0; pages=0; arg=""
while :; do
  "$ZERO" todo-list $arg > "$TB/w.out" 2>&1; pages=$((pages+1))
  walk="$walk$(freeids < "$TB/w.out")"
  nofile="$nofile$(grep '^- \[ \] ' "$TB/w.out" | grep -v '/tasks/' | awk '{print $4}' | tr '\n' ' ')"
  [ "$(grep -c "T02${TAG}" "$TB/w.out")" = 1 ] && [ "$(grep -c "T12${TAG}" "$TB/w.out")" = 1 ] && heldpages=$((heldpages+1))
  last=$(tail -n 1 "$TB/w.out"); [ "$last" = "Next page: none" ] && break
  arg=${last#Next page: todo-list }; [ $pages -gt 20 ] && break
done
check "W1 every free Task once in order" "$walk" "T01 T05 T06 T07 T08 T09 T10 T11 T13 T14 T15 T16 T17 T18 T19 T20 "
check "W2 no-file Tasks printed once" "$nofile" "T03 T04 "
check "W3 held on every page" "$heldpages" "$pages"
check "W4 last page ends none" "$(tail -n 1 "$TB/w.out")" "Next page: none"
check "W5 later pages: no Landed/context" "$(grep -c '^Landed:\|^- \[x\]\|^- \[?\]' "$TB/p2.out")" "0"
check "W6 no checkbox-shaped nav line, no counts" "$(grep -c '^- \[.*Next page\|[Pp]age [0-9]\|of [0-9]* pages' "$TB/p1.out" "$TB/p2.out" | awk -F: '{s+=$2} END{print s}')" "0"

# cursor positions: Landed, held, free, last
check "C1 landed cursor starts at first free" "$("$ZERO" todo-list L3 | freeids)" "T01 T05 T06 "
check "C2 held cursor" "$("$ZERO" todo-list T02 | freeids)" "T05 T06 T07 "
check "C3 past last free: held, no free, none" "$("$ZERO" todo-list T20 | tr '\n' '|')" "- [ ] T02${TAG} task 02  $P/T02.md|- [ ] T12${TAG} task 12  $P/T12.md|Next page: none|"
check "C4 other-symbol cursor" "$("$ZERO" todo-list LQ | freeids)" "T11 T13 T14 "

# a peer takes the second free Task between calls: the cursor still yields the fourth free Task
hold T05
check "S1 stable cursor after a peer takes T05" "$("$ZERO" todo-list T06 | freeids)" "T07 T08 T09 "
check "S2 taken Task now tagged held" "$("$ZERO" todo-list T06 | grep -c "T05${TAG}")" "1"

# unknown id, empty-box list
"$ZERO" todo-list NOPE > "$TB/n.out" 2> "$TB/n.err"; rc=$?
check "N1 unknown id exit" "$rc" "0"
check "N1 unknown id line" "$(cat "$TB/n.out")" "Task NOPE is not on the Todo List, start with: todo-list"
check "N1 stderr empty" "$(wc -c < "$TB/n.err" | tr -d ' ')" "0"

# task-file
check "F1 landed" "$("$ZERO" task-file L1)" "$P/L1.md"
check "F1 unchecked" "$("$ZERO" task-file T01)" "$P/T01.md"
check "F1 held" "$("$ZERO" task-file T02)" "$P/T02.md"
printf -- '- [x] AMB two files\n- [x] NOF no file\n' >> todo.md; mkdir -p docs; body AMB; cp tasks/AMB.md docs/AMB-x.md
git add -A; git commit -qm more
"$ZERO" task-file NOPE > "$TB/f.out" 2>&1; check "F2 not on list" "$(cat "$TB/f.out"): rc=$?" "No Task file for NOPE: not on the Todo List: rc=0"
check "F2 several" "$("$ZERO" task-file AMB | grep -c '^No Task file for AMB: several')" "1"
check "F2 none" "$("$ZERO" task-file NOF | grep -c '^No Task file for NOF: no file')" "1"
git status --porcelain > "$TB/st.out"; check "F3 no state change" "$(wc -c < "$TB/st.out" | tr -d ' ')" "0"

# held scan failure: all usable-file Tasks free, untagged, one warning, exit 0
REALGIT=$(type -P git)
printf '#!/usr/bin/env bash\ncase " $* " in *" worktree list "*) exit 3;; esac\nexec "%s" "$@"\n' "$REALGIT" > "$TB/bin/git"; chmod +x "$TB/bin/git"
PATH="$TB/bin:$PATH" "$ZERO" todo-list > "$TB/fail.out" 2> "$TB/fail.err"; rc=$?
check "E1 exit" "$rc" "0"; check "E1 untagged" "$(grep -c 'held by a live peer' "$TB/fail.out")" "0"
check "E1 held Task counts free" "$(freeids < "$TB/fail.out")" "T01 T02 T05 "
check "E1 one warning" "$(wc -l < "$TB/fail.err" | tr -d ' ')" "1"
rm "$TB/bin/git"

# few free Tasks: everything on page 1, none
newrepo few
printf -- '- [ ] A a\n- [ ] B b\n' > todo.md; body A; body B; git add -A; git commit -qm f
check "G1 three or fewer free" "$("$ZERO" todo-list | tail -n 1)" "Next page: none"
printf -- '- [x] A a\n' > todo.md; git add -A; git commit -qm g
check "G2 no unchecked prints nothing" "$("$ZERO" todo-list ANY | wc -c | tr -d ' ')" "0"
check "G2 no landed line out of an all-landed list" "$("$ZERO" todo-list | wc -c | tr -d ' ')" "0"

# unusable Task after the last free Task is printed on the last page
newrepo tailnf
printf -- '- [ ] A a\n- [ ] B b\n- [ ] C c\n- [ ] N nofile\n' > todo.md; body A; body B; body C; git add -A; git commit -qm t
check "G3 no-file Task after third free printed, then none" "$("$ZERO" todo-list | tail -n 2 | tr '\n' '|')" "- [ ] N nofile|Next page: none|"

# --- the 349-Task list: short first page; live resolution stops early
newrepo big
{ printf -- '- [x] D1 done\n- [x] D2 done\n'; for i in $(seq 1 349); do printf -- '- [ ] B%s big %s\n' "$i" "$i"; body "B$i"; done; } > todo.md
git add -A; git commit -qm big
hold B2; hold B9
REALFIND=$(type -P find)
printf '#!/usr/bin/env bash\necho "$*" >> "%s/find.log"\nexec "%s" "$@"\n' "$TB" "$REALFIND" > "$TB/bin/find"; chmod +x "$TB/bin/find"
: > "$TB/find.log"
PATH="$TB/bin:$PATH" "$ZERO" todo-list > "$TB/big.out" 2>&1
check "B1 at most 25 lines" "$([ "$(wc -l < "$TB/big.out")" -le 25 ] && echo yes || echo NO)" "yes"
check "B1 held tagged, three free, nav" "$(grep -c "held by a live peer" "$TB/big.out"):$(freeids < "$TB/big.out"):$(tail -n 1 "$TB/big.out")" "2:B1 B3 B4 :Next page: todo-list B4"
check "B2 live page resolves only what it needs" "$([ "$(grep -o -- '-iname' "$TB/find.log" | wc -l | tr -d ' ')" -lt 60 ] && echo yes || echo NO)" "yes"
rm "$TB/bin/find"

# prompts, usage, README
check "D1 both prompts: next page rules" "$(grep -c "Next page: none" "$REAL_SCRIPT" | awk '{print ($1>=4)?"ok":"few"}')" "ok"
check "D2 prompts name task-file" "$(grep -c 'zero.sh task-file\|@@ZERO_SH@@ task-file' "$REAL_SCRIPT" | awk '{print ($1>=2)?"ok":"few"}')" "ok"
check "D3 usage" "$("$ZERO" 2>&1 | grep -c 'todo-list \[ID\].*task-file ID')" "1"
check "D4 README" "$(grep -c 'Next page' "$REPO/README.md" | awk '{print ($1>=1)?"ok":"none"}')" "ok"

kill "${PEERS[@]}" 2>/dev/null || true
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
