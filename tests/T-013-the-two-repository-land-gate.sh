#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=210s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-013-the-two-repository-land-gate — code on the target base before the box, the teardown that
# follows, and two racing `merge` calls landing the code once, all with two fixture repositories
# (`code` the target, `plan` holding the todo).
# Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor tests
#   `command -v claude` before any startup guard runs)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: T19, T20, T21, T23, T26, T27, T28
#
# What happens when a task lands with two fixture repositories, code (target) and plan (holds the
# todo): the gate puts the code on the target base before it ticks the box on the coordination
# base, release_task tears the paired target worktree down through teardown_target, two racing
# merge calls land the code once and credit once, the crash marker never straddles the two
# repositories, a human's bisect or a mid-flight longer id survive a merge untouched, the banner
# and success line read verbatim, and a non-owner's merge call is refused.

mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktodo(){ ( cd "$1"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }

# T19 — the land gate lands code on the target base before the box (stub claude)
T19="$TESTROOT/T19"; mkdir -p "$T19/code" "$T19/plan" "$T19/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T19/bin/claude"; chmod +x "$T19/bin/claude"
( cd "$T19/code"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo z > f.txt; git add f.txt; git commit -qm init )
( cd "$T19/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] W1 conflict task\n- [ ] W2 diff-empty task\n- [ ] W3 already-landed task\n- [ ] W4 guard task\n' > todo.md
  mkdir -p tasks
  for f in W1 W2 W3 W4; do printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/$f.md"; done
  git add -A; git commit -qm todo )
( cd "$T19/code"; PATH="$T19/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T19/plan/todo.md" >/dev/null 2>&1 || true )
ZERO19="$T19/plan/.git/zero.sh"
# runs in its own bash subprocess (own KAIZERO_SESSION_RECORD); check() is exported so it can
# call it directly — the driver's own FAILED/ERRORED are local to it, folded into this process's
# FAILED via the driver's own trailing exit-status line + `|| FAILED=1` below.
cat > "$T19/drive.sh" <<DRIVE
set -uo pipefail
FAILED=0; ERRORED=0
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
cd "$T19/plan"

# W1: a real target-side conflict — exit 2, aborted, base clean, branch + worktree kept, box [ ].
t1=\$("$ZERO19" claim W1)
echo mine > "\$t1/f.txt"; git -C "\$t1" add f.txt; git -C "\$t1" commit -qm mine
echo theirs > "$T19/code/f.txt"; git -C "$T19/code" add f.txt; git -C "$T19/code" commit -qm theirs
out=\$("$ZERO19" merge W1 "\$t1" 2>&1); rc=\$?
check "T19 W1 conflict exit" "\$rc" "2"
check "T19 W1 base clean" "\$(git -C "$T19/code" status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0"
check "T19 W1 worktree kept" "\$([ -d "\$t1" ] && echo yes || echo NO)" "yes"
check "T19 W1 box unchecked" "\$(grep -c '\[ \] W1' todo.md)" "1"
"$ZERO19" release W1 >/dev/null 2>&1 || true   # one task per session: free the slot before W2's own claim

# W2: branch that only merged base back in (peers' work) — diff empty, not an ancestor — exit 5.
t2=\$("$ZERO19" claim W2)
GIT_EDITOR=true git -C "\$t2" revert --no-edit HEAD --no-commit >/dev/null 2>&1 || true
echo change > "\$t2/g.txt"; git -C "\$t2" add g.txt; git -C "\$t2" commit -qm change
git -C "\$t2" revert --no-edit HEAD >/dev/null
out=\$("$ZERO19" merge W2 "\$t2" 2>&1); rc=\$?
check "T19 W2 diff-empty exit" "\$rc" "5"
check "T19 W2 says land gate" "\$(printf '%s' "\$out" | grep -c 'land gate failed at local')" "1"
check "T19 W2 box unchecked" "\$(grep -c '\[ \] W2' todo.md)" "1"
"$ZERO19" release W2 >/dev/null 2>&1 || true   # one task per session: free the slot before W3's own claim

# W3: a human lands the branch on the target base first — merge PASSES with no second code merge,
# only the box tick is new on TARGET_ROOT.
t3=\$("$ZERO19" claim W3)
echo work3 > "\$t3/h.txt"; git -C "\$t3" add h.txt; git -C "\$t3" commit -qm work3
br3=\$(git -C "\$t3" symbolic-ref --short HEAD)
before=\$(git -C "$T19/code" rev-list --count main)
git -C "$T19/code" checkout -q main; git -C "$T19/code" merge -q --no-ff -m "human pre-merge" "\$br3"
git -C "\$t3" fetch -q "$T19/code" main; git -C "\$t3" reset -q --hard FETCH_HEAD
out=\$("$ZERO19" merge W3 "\$t3" 2>&1); rc=\$?
after=\$(git -C "$T19/code" rev-list --count main)
check "T19 W3 already-landed exit" "\$rc" "0"
# +2 for the human's own merge alone: the branch's commit plus its merge commit, none from zero.sh
check "T19 W3 no second merge" "\$([ "\$after" -eq "\$((before + 2))" ] && echo yes || echo NO)" "yes"
check "T19 W3 box checked" "\$(grep -c '\[x\] W3' todo.md)" "1"

# W4: a coordination claim branch carrying a commit beyond its fork point refuses — exit 5, no merge.
t4=\$("$ZERO19" claim W4)
echo work4 > "\$t4/k.txt"; git -C "\$t4" add k.txt; git -C "\$t4" commit -qm work4
cwt4=\$(git worktree list --porcelain | awk -v b="refs/heads/main-task-W4" '/^worktree /{p=substr(\$0,10)} /^branch /{if(substr(\$0,8)==b){print p;exit}}')
git -C "\$cwt4" commit -q --allow-empty -m "stray"
before4=\$(git -C "$T19/code" rev-list --count main)
out=\$("$ZERO19" merge W4 "\$t4" 2>&1); rc=\$?
after4=\$(git -C "$T19/code" rev-list --count main)
check "T19 W4 claim-branch guard exit" "\$rc" "5"
check "T19 W4 says claim not carrier" "\$(printf '%s' "\$out" | grep -c 'is a claim, not a carrier')" "1"
check "T19 W4 no code merged" "\$([ "\$before4" -eq "\$after4" ] && echo yes || echo NO)" "yes"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
bash "$T19/drive.sh" || FAILED=1
# T19 PASS — W1's real conflict exits 2, aborts, and leaves the target base, the branch, and the
# worktree exactly as a single-repository conflict would; W2's branch (content-equal to base, not
# literally on it) is refused at the land gate with exit 5 and the fixed "land gate failed at
# local:" wording, box left [ ]; W3 proves test 2's "already on base" pass-through — a human's own
# pre-merge is the only new commit on TARGET_BASE, and the box still lands; W4 proves the
# coordination claim-branch guard — a branch this fleet's own claim never carries a commit past
# its fork point, and a stray one there refuses before any code merge runs.

# T20 — `release_task` tears the target worktree down through `teardown_target` (stub claude)
T20="$TESTROOT/T20"; mkdir -p "$T20/code" "$T20/plan" "$T20/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T20/bin/claude"; chmod +x "$T20/bin/claude"
( cd "$T20/code"; git init -q -b main; git config user.email t@t.t; git config user.name test
  git commit -q --allow-empty -m init )
( cd "$T20/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] V1 release task\n' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/V1.md
  git add -A; git commit -qm todo )
( cd "$T20/code"; PATH="$T20/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T20/plan/todo.md" >/dev/null 2>&1 || true )
ZERO20="$T20/plan/.git/zero.sh"
cat > "$T20/drive.sh" <<DRIVE
set -uo pipefail
FAILED=0; ERRORED=0
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
cd "$T20/plan"
t1=\$("$ZERO20" claim V1)
echo work > "\$t1/f.txt"; git -C "\$t1" add f.txt; git -C "\$t1" commit -qm work
out=\$("$ZERO20" release V1 "" 2>&1); rc=\$?
check "T20 release exit" "\$rc" "0"
check "T20 target worktree gone" "\$([ -d "\$t1" ] && echo NO || echo yes)" "yes"
# want 1 — teardown_target keeps an unmerged branch, -D never runs on it
check "T20 unmerged branch kept" "\$(git -C "$T20/code" branch --list | grep -c V1-)" "1"
check "T20 coord worktree gone" "\$(git worktree list --porcelain | grep -c '^worktree.*/ts-main-task-V1-')" "0"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
bash "$T20/drive.sh" || FAILED=1
# T20 PASS — release_task reads .owner line 5, hands it straight to teardown_target, which removes
# the target worktree and — since the branch is not yet an ancestor of TARGET_BASE — keeps the
# branch (no -D), then the coordination worktree comes down after it.

# T21 — two racing `merge` calls land the code once and credit once (stub claude)
T21="$TESTROOT/T21"; mkdir -p "$T21/code" "$T21/plan" "$T21/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T21/bin/claude"; chmod +x "$T21/bin/claude"
( cd "$T21/code"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo z > f.txt; git add f.txt; git commit -qm init )
( cd "$T21/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] R1 race task\n' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/R1.md
  git add -A; git commit -qm todo )
( cd "$T21/code"; PATH="$T21/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T21/plan/todo.md" >/dev/null 2>&1 || true )
ZERO21="$T21/plan/.git/zero.sh"
cat > "$T21/drive.sh" <<DRIVE
set -uo pipefail
FAILED=0; ERRORED=0
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
cd "$T21/plan"
t1=\$("$ZERO21" claim R1)
echo work > "\$t1/r.txt"; git -C "\$t1" add r.txt; git -C "\$t1" commit -qm work
before=\$(git -C "$T21/code" rev-list --count main)
lockfile="$T21/plan/.git/merge.lock"
{ flock 9; touch "$T21/held"; sleep 3; } 9>"\$lockfile" > "$T21/lockhold.out" 2>&1 &
holdpid=\$!
while [ ! -f "$T21/held" ]; do sleep 0.05; done
"$ZERO21" merge R1 "\$t1" > "$T21/out1" 2> "$T21/err1" &
p1=\$!
"$ZERO21" merge R1 "\$t1" > "$T21/out2" 2> "$T21/err2" &
p2=\$!
sleep 0.3
wait "\$holdpid"
wait "\$p1"; rc1=\$?
wait "\$p2"; rc2=\$?
after=\$(git -C "$T21/code" rev-list --count main)
landed=0; alreadyn=0
for f in "$T21/out1" "$T21/out2"; do
  grep -q 'merged to' "\$f" && landed=\$((landed+1))
  grep -q 'already landed' "\$f" && alreadyn=\$((alreadyn+1))
done
check "T21 both exit 0" "\$([ "\$rc1" -eq 0 ] && [ "\$rc2" -eq 0 ] && echo yes || echo NO)" "yes"
check "T21 one merge commit" "\$([ "\$after" -eq "\$((before + 2))" ] && echo yes || echo NO)" "yes"
check "T21 one box symbol" "\$(grep -c '\[x\] R1' todo.md)" "1"
check "T21 one landed line" "\$landed" "1"
check "T21 one already line" "\$alreadyn" "1"
# want 1 — only the winner's file
check "T21 loser silent" "\$(grep -lE 'merged to|box landed|cleaned' "$T21/out1" "$T21/out2" | wc -l | tr -d ' ')" "1"
GC="$T21/plan/.git"
check "T21 done credit once" "\$(cat "\$GC/todos-done-main-shared" 2>/dev/null || echo 0)" "1"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
bash "$T21/drive.sh" || FAILED=1
# T21 PASS — with MERGE_LOCK held by a third party so both merge R1 calls queue before either can
# act, releasing it lets exactly one of them do the real work: one --no-ff merge commit lands on
# TARGET_BASE, one symbol lands on the box, and only that caller's output carries merged
# to/box landed/cleaned. The other, finding under the lock that the target worktree it was handed
# is already gone and the box already carries a symbol, reports the already-landed state and exits
# 0 without repeating any merge step. Only the caller that actually ticked the box is credited a
# Landed Task.

# T23 — the two-repository crash marker: one file per landing checkout, never shared
T23="$TESTROOT/T23"; mkdir -p "$T23/code" "$T23/plan" "$T23/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T23/bin/claude"; chmod +x "$T23/bin/claude"
( cd "$T23/code"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo z > f.txt; git add f.txt; git commit -qm init )
( cd "$T23/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] M1 marker task\n- [ ] M2 bisect task\n' > todo.md
  mkdir -p tasks
  for f in M1 M2; do printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/$f.md"; done
  git add -A; git commit -qm todo )
( cd "$T23/code"; PATH="$T23/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T23/plan/todo.md" >/dev/null 2>&1 || true )
ZERO23="$T23/plan/.git/zero.sh"
eval "$(sed -n '/^inflight_file_for() {/,/^}/p' "$ZERO23")"
eval "$(grep '^mark_inflight()' "$ZERO23")"
eval "$(grep '^clear_inflight()' "$ZERO23")"
eval "$(sed -n '/^inflight_dead_for() {/,/^}/p' "$ZERO23")"
eval "$(grep '^proc_start()' "$ZERO23" | head -1)"
COORD_ROOT="$T23/plan"; TARGET_ROOT="$T23/code"; SAME_REPO=0
COORD_GITDIR="$COORD_ROOT/.git"
MERGE_INFLIGHT_TARGET="$COORD_GITDIR/merge-inflight-target"
MERGE_INFLIGHT_COORD="$COORD_GITDIR/merge-inflight-coord"

f_t=$(inflight_file_for "$TARGET_ROOT"); f_c=$(inflight_file_for "$COORD_ROOT")
check "T23 X1 files differ" "$([ "$f_t" != "$f_c" ] && echo yes || echo NO)" "yes"

# X2 (the Absence check): a dead peer's marker for the coordination root, planted first, survives
# this call marking the TARGET root — the two never share a file.
( sleep 30 ) > "$T23/x2peer.out" 2>&1 & peer=$!; sleep 0.3; st="$(ps -o lstart= -p "$peer" | awk '{$1=$1;print}')"
kill "$peer" 2>/dev/null; wait "$peer" 2>/dev/null
printf '%s\n%s\n%s\n' "$peer" "$st" "$COORD_ROOT" > "$f_c"
mark_inflight "$TARGET_ROOT"
check "T23 X2 coord marker intact" "$(tr '\n' '|' < "$f_c" 2>/dev/null)" "$peer|$st|$COORD_ROOT|"
clear_inflight
rm -f "$f_c" "$f_t"

# X3: our own dead wreck (marker names this root, pid dead) reads as abortable.
( sleep 30 ) > "$T23/x3peer.out" 2>&1 & peer2=$!; sleep 0.3; st2="$(ps -o lstart= -p "$peer2" | awk '{$1=$1;print}')"
kill "$peer2" 2>/dev/null; wait "$peer2" 2>/dev/null
printf '%s\n%s\n%s\n' "$peer2" "$st2" "$TARGET_ROOT" > "$f_t"
check "T23 X3 dead-own wreck" "$(inflight_dead_for "$TARGET_ROOT" && echo yes || echo NO)" "yes"

# X4: nothing at the coordination file, so its root is never read as abortable either.
check "T23 X4 no coord marker" "$(inflight_dead_for "$COORD_ROOT" && echo NO || echo yes)" "yes"

# X5: a live pid's marker is never abortable.
( sleep 30 ) > "$T23/x5peer.out" 2>&1 & peer3=$!; sleep 0.3; st3="$(ps -o lstart= -p "$peer3" | awk '{$1=$1;print}')"
printf '%s\n%s\n%s\n' "$peer3" "$st3" "$TARGET_ROOT" > "$f_t"
check "T23 X5 live pid not dead" "$(inflight_dead_for "$TARGET_ROOT" && echo NO || echo yes)" "yes"
kill "$peer3" 2>/dev/null; wait "$peer3" 2>/dev/null
rm -f "$f_t" "$f_c"
# T23 X1-X5 PASS — inflight_file_for maps the target and coordination roots to two distinct paths;
# marking one root's merge in flight never disturbs a dead peer's marker already on file for the
# other (the land gate's own Absence check); a marker naming this root with a pid no longer
# running reads as this fleet's own abortable wreck, a live pid's or an unmarked root's never does.

# T24 — `merge_two_repos`' own test 3: a claimed branch with no commit of its own is refused
own_session "$TESTROOT/T23/diag-session"
t1=$("$ZERO23" claim M1)
before1=$(git -C "$T23/code" rev-list --count main)
out=$("$ZERO23" merge M1 "$t1" 2>&1); rc=$?
after1=$(git -C "$T23/code" rev-list --count main)
check "T24 M1 no-commit exit" "$rc" "5"
check "T24 M1 says carries no change" "$(printf '%s' "$out" | grep -c 'carries no change')" "1"
check "T24 M1 no code merged" "$([ "$before1" -eq "$after1" ] && echo yes || echo NO)" "yes"
check "T24 M1 box unchecked" "$(grep -c '\[ \] M1' "$T23/plan/todo.md")" "1"
# T24 M1 PASS — a freshly claimed two-repository branch that never picked up a commit of its own
# is refused by test 3 with no code merge attempted, box left [ ].
"$ZERO23" release M1 "$t1" >/dev/null 2>&1   # T24's merge refused, so M1 is still claimed by this
# session — one-task-per-session refuses T25's claim M2 otherwise (M-001's own invariant)

# T25 — a human's `git bisect` in the target root refuses the gate, read by root not by cwd
own_session "$TESTROOT/T23/diag-session"
git -C "$T23/code" commit -q --allow-empty -m "extra for bisect"
git -C "$T23/code" commit -q --allow-empty -m "c1"
git -C "$T23/code" commit -q --allow-empty -m "c2"
git -C "$T23/code" commit -q --allow-empty -m "c3"
root=$(git -C "$T23/code" rev-list --max-parents=0 HEAD)
( cd "$T23/code" && git bisect start >/dev/null && git bisect bad >/dev/null && git bisect good "$root" >/dev/null )
before_head=$(git -C "$T23/code" rev-parse HEAD)
t2=$("$ZERO23" claim M2)
echo m2work > "$t2/m2.txt"; git -C "$t2" add m2.txt; git -C "$t2" commit -qm "M2 work"
out=$(cd "$t2" && "$ZERO23" merge M2 "$t2" 2>&1); rc=$?
check "T25 M2 bisect-guard exit" "$rc" "5"
check "T25 M2 names target root" "$(printf '%s' "$out" | grep -c "$T23/code")" "1"
check "T25 M2 bisect head unmoved" "$([ "$(git -C "$T23/code" rev-parse HEAD)" = "$before_head" ] && echo yes || echo NO)" "yes"
check "T25 M2 still bisecting" "$([ -f "$T23/code/.git/BISECT_LOG" ] && echo yes || echo NO)" "yes"
check "T25 M2 box unchecked" "$(grep -c '\[ \] M2' "$T23/plan/todo.md")" "1"
git -C "$T23/code" bisect reset >/dev/null 2>&1
# T25 M2 PASS — invoked with the cwd set to $t2 (never the target root), the gate still finds the
# target root's own BISECT_LOG and refuses naming that root; the human's bisect stays exactly
# where it was — detached HEAD unmoved, BISECT_LOG still present — and the box stays [ ].

# T26 — two-repository `--local-merge` banner and the merge success line, verbatim
T26="$TESTROOT/T26"; mkdir -p "$T26/code" "$T26/plan" "$T26/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T26/bin/claude"; chmod +x "$T26/bin/claude"
mkrepo "$T26/code"; mkrepo "$T26/plan"; mktodo "$T26/plan"
( cd "$T26/plan"; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/G1.md; git add -A; git commit -qm "task file" )
banner=$( ( cd "$T26/code"; PATH="$T26/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T26/plan/todo.md" 2>&1 ) )
check "T26 banner ends fork..merge" "$(echo "$banner" | grep -c "Todo $T26/plan@main \. Target $T26/code@main \. Fork -> implement -> commit -> merge")" "1"
check "T26 no one-repo banner" "$(echo "$banner" | grep -c 'Base ')" "0"
ZERO26="$T26/plan/.git/zero.sh"
cat > "$T26/drive.sh" <<DRIVE
set -uo pipefail
FAILED=0; ERRORED=0
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
cd "$T26/plan"
t=\$("$ZERO26" claim G1)
echo work > "\$t/n.txt"; git -C "\$t" add n.txt; git -C "\$t" commit -qm work
out=\$("$ZERO26" merge G1 "\$t" 2>&1); rc=\$?
check "T26 merge exit" "\$rc" "0"
check "T26 success line verbatim" "\$(printf '%s' "\$out" | grep -c "merge G1: merged to main in $T26/code; box landed on main; worktrees + branches cleaned")" "1"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
bash "$T26/drive.sh" || FAILED=1
# T26 PASS — the two-repository --local-merge banner ends fork → implement → commit → merge, never
# the one-repository banner; the merge success line matches the UX behavior section's quoted text
# verbatim, naming the target root and the coordination base.

# T27 — a longer id added mid-flight while a merge is also in flight (human + peer) (stub claude)
T27="$TESTROOT/T27"; mkdir -p "$T27/code" "$T27/plan" "$T27/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T27/bin/claude"; chmod +x "$T27/bin/claude"
( cd "$T27/code"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo z > f.txt; git add f.txt; git commit -qm init )
( cd "$T27/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] 7 base task\n' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/7.md
  git add -A; git commit -qm todo )
( cd "$T27/code"; PATH="$T27/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T27/plan/todo.md" >/dev/null 2>&1 || true )
ZERO27="$T27/plan/.git/zero.sh"
before=$(git -C "$T27/code" rev-list --count main)
cat > "$T27/drive.sh" <<DRIVE
set -uo pipefail
FAILED=0; ERRORED=0
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
cd "$T27/plan"
t7=\$("$ZERO27" claim 7)
echo work7 > "\$t7/r7.txt"; git -C "\$t7" add r7.txt; git -C "\$t7" commit -qm work7
lockfile="$T27/plan/.git/merge.lock"
{ flock 9; touch "$T27/held"; sleep 3; } 9>"\$lockfile" > "$T27/lockhold.out" 2>&1 &
holdpid=\$!
while [ ! -f "$T27/held" ]; do sleep 0.05; done
"$ZERO27" merge 7 "\$t7" > "$T27/out7" 2> "$T27/err7" &
p7=\$!
sleep 0.3
# a human edits the todo mid-flight of 7's merge, adding a longer id
printf -- '- [ ] 7-1-add-flag mid-flight task\n' >> todo.md
mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/7-1-add-flag.md
git add -A; git commit -qm "add 7-1-add-flag mid-flight"
# a peer session claims and lands the new id — distinct from task 7's own in-flight session (a
# session may hold only one task at a time), so the one-task-per-session guard never applies
# between them and task 7's still-in-flight merge is never touched by 7-1's claim.
( sleep 10 ) > "$T27/peer.out" 2>&1 & peerpid=\$!
sleep 0.3
PEERREC="$T27/peer.rec"
printf '%s\n%s\n%s\n' "\$peerpid" "\$(ps -o lstart= -p \$peerpid | awk '{\$1=\$1;print}')" 1 > "\$PEERREC"
export KAIZERO_SESSION_RECORD="\$PEERREC" KAIZERO_SESSION_EPOCH=1
t71=\$("$ZERO27" claim 7-1-add-flag); claim71_rc=\$?
echo work71 > "\$t71/r71.txt"; git -C "\$t71" add r71.txt; git -C "\$t71" commit -qm work71
"$ZERO27" merge 7-1-add-flag "\$t71" > "$T27/out71" 2> "$T27/err71" &
p71=\$!
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
wait "\$holdpid"
wait "\$p7"; rc7=\$?
wait "\$p71"; rc71=\$?
# want yes — claim needs no MERGE_LOCK
check "T27 claim 7-1 not lock-blocked" "\$([ "\$claim71_rc" -eq 0 ] && echo yes || echo NO)" "yes"
check "T27 both merges exit 0" "\$([ "\$rc7" -eq 0 ] && [ "\$rc71" -eq 0 ] && echo yes || echo NO)" "yes"
check "T27 both boxes ticked" "\$(grep -c '\[x\]' todo.md)" "2"
kill "\$peerpid" 2>/dev/null; wait "\$peerpid" 2>/dev/null
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
bash "$T27/drive.sh" || FAILED=1
after=$(git -C "$T27/code" rev-list --count main)
# want yes — +2 per landed task: its own commit plus the merge commit
check "T27 both landings' commits" "$([ "$after" -eq "$((before + 4))" ] && echo yes || echo NO)" "yes"
( cd "$T27/code"; git checkout -q main )
# want yes — 7's and 7-1's work both landed, not conflated
check "T27 both files present on main" "$([ -f "$T27/code/r7.txt" ] && [ -f "$T27/code/r71.txt" ] && echo yes || echo NO)" "yes"
# T27 PASS — claiming the longer id 7-1-add-flag that a human commits to the todo while 7's merge
# holds MERGE_LOCK is never blocked by that lock (claim takes no MERGE_LOCK); both merges queue on
# the same global lock, land serially, exit 0, and each ticks its own box — the mid-flight arrival
# of a longer id never steals or corrupts the in-flight merge's target branch, and both bodies of
# work land as two distinct --no-ff commits on main, neither overwriting the other.

# T28 — `merge` called by a session that does not hold the id exits 6, in both `--local-merge` layouts
# single-repository layout: BUG 057, this shell writes its own KAIZERO_SESSION_RECORD naming
# itself, inherited by the subshell below.
T28="$TESTROOT/T28"; mkdir -p "$T28/repo"
( cd "$T28/repo"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] N1 non-owner task\n' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/N1.md
  git add -A; git commit -qm init )
( cd "$T28/repo"; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge todo.md >/dev/null 2>&1 || true )
ZERO28="$T28/repo/.git/zero.sh"
own_session "$T28/repo-session"
( cd "$T28/repo"
  t=$("$ZERO28" claim N1)
  echo work > "$t/n.txt"; git -C "$t" add n.txt; git -C "$t" commit -qm work
  cwt=$(git worktree list --porcelain | awk -v b="refs/heads/main-task-N1" '/^worktree /{p=substr($0,10)} /^branch /{if(substr($0,8)==b){print p;exit}}')
  cp "$cwt/.owner" "$T28/n1-owner-backup"
  before_main1=$(git rev-parse main)
  printf '999999\nThu Jan  1 00:00:00 1970\n%s\n%s\n' "$(sed -n 3p "$cwt/.owner")" "$(sed -n 4p "$cwt/.owner")" > "$cwt/.owner"
  out=$("$ZERO28" merge N1 "$t" 2>&1); rc=$?
  check "T28 1-repo non-owner exit" "$rc" "6"
  check "T28 1-repo says not yours" "$(printf '%s' "$out" | grep -c 'not your task')" "1"
  check "T28 1-repo box unchanged" "$(grep -c '\[ \] N1' todo.md)" "1"
  # want unchanged from before, no merge happened
  check "T28 1-repo target unchanged" "$(git rev-parse main)" "$before_main1"
  cp "$T28/n1-owner-backup" "$cwt/.owner"
  out2=$("$ZERO28" merge N1 "$t" 2>&1); rc2=$?
  check "T28 1-repo owner then lands" "$rc2" "0"
  [ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
) || FAILED=1

# two-repository layout: a disposable driver script's own session record, stable for its whole
# run, so a race-prone intermediate subshell (from a trailing 2>&1) can never spoof a different owner.
mkdir -p "$T28/code" "$T28/plan" "$T28/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T28/bin/claude"; chmod +x "$T28/bin/claude"
( cd "$T28/code"; git init -q -b main; git config user.email t@t.t; git config user.name test
  git commit -q --allow-empty -m init )
( cd "$T28/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] N2 non-owner task\n' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/N2.md
  git add -A; git commit -qm todo )
( cd "$T28/code"; PATH="$T28/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T28/plan/todo.md" >/dev/null 2>&1 || true )
ZERO28P="$T28/plan/.git/zero.sh"
TARGET_MAIN_BEFORE=$(git -C "$T28/code" rev-parse main)
cat > "$T28/drive.sh" <<DRIVE
set -uo pipefail
FAILED=0; ERRORED=0
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
cd "$T28/plan"
t=\$("$ZERO28P" claim N2)
echo work > "\$t/n.txt"; git -C "\$t" add n.txt; git -C "\$t" commit -qm work
cwt=\$(git worktree list --porcelain | awk -v b="refs/heads/main-task-N2" '/^worktree /{p=substr(\$0,10)} /^branch /{if(substr(\$0,8)==b){print p;exit}}')
cp "\$cwt/.owner" "$T28/n2-owner-backup"
printf '999999\nThu Jan  1 00:00:00 1970\n%s\n%s\n' "\$(sed -n 3p "\$cwt/.owner")" "\$(sed -n 4p "\$cwt/.owner")" > "\$cwt/.owner"
out=\$("$ZERO28P" merge N2 "\$t" 2>&1); rc=\$?
check "T28 2-repo non-owner exit" "\$rc" "6"
check "T28 2-repo says not yours" "\$(printf '%s' "\$out" | grep -c 'not your task')" "1"
check "T28 2-repo box unchanged" "\$(grep -c '\[ \] N2' todo.md)" "1"
# want unchanged from before, no merge happened
check "T28 2-repo target unchanged" "\$(git -C "$T28/code" rev-parse main)" "$TARGET_MAIN_BEFORE"
check "T28 2-repo worktree kept" "\$([ -d "\$t" ] && echo yes || echo NO)" "yes"
cp "$T28/n2-owner-backup" "\$cwt/.owner"
out2=\$("$ZERO28P" merge N2 "\$t" 2>&1); rc2=\$?
check "T28 2-repo owner then lands" "\$rc2" "0"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
bash "$T28/drive.sh" || FAILED=1
# T28 PASS — in both layouts, a caller whose .owner line 1/2 name a different session is refused
# with exit 6, not 5: nothing merges, the box stays [ ], and (two-repository layout) the worktree
# and branch survive untouched. The gate does not swallow the land gate's own answers: once .owner
# is restored, the actual owner lands the same id normally with exit 0.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
