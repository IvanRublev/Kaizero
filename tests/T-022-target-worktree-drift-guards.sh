#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=110s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-022-target-worktree-drift-guards — a missing target base fails cleanly, a hand-deleted
# worktree directory is pruned and reclaimed, a hand-set .owner line 5 that fails the candidate
# filters is treated as missing rather than repaired, and a target branch renamed out of its
# id's namespace is caught rather than silently re-adopted.
# Needs real claude: no — a disposable driver process writes its own KAIZERO_SESSION_RECORD
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T21, $TESTROOT/T22, $TESTROOT/T23, $TESTROOT/T24
#
# Each case drives kaizero's emitted zero.sh from a disposable child bash process (its own
# PID, own KAIZERO_SESSION_RECORD) — check() is exported by test-setup.sh, so the driver
# calls it directly; its own FAILED/ERRORED stay local to that process (variables don't cross a
# process boundary), so the driver ends with the same trailing exit-status line every scenario
# does, and this script folds the driver's own exit status into FAILED on nonzero.

mkrepo(){ mkdir -p "$1"; ( cd "$1" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }

fold(){ [ "$1" -eq 0 ] || FAILED=1; }   # $1: a driver subprocess's own exit status

# T21 — a missing target base fails a fork with git's own message; reattach/take still work
T21="$TESTROOT/T21"; mkdir -p "$T21/code" "$T21/plan" "$T21/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T21/bin/claude"; chmod +x "$T21/bin/claude"
mkrepo "$T21/code"
( cd "$T21/code"; git branch R1D-anything )
( cd "$T21/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] F1D fork me\n- [ ] R1D reattach me\n' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/F1D.md
  printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/R1D.md
  git add -A; git commit -qm todo )
( cd "$T21/code"; PATH="$T21/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T21/plan/todo.md" >/dev/null 2>&1 || true )
ZERO21="$T21/plan/.git/zero.sh"
( cd "$T21/code"; git checkout -q --detach; git branch -D main )   # detach first (main is the main checkout's own branch) — the target base itself is gone
cat > "$T21/drive.sh" <<DRIVE
set -uo pipefail
cd "$T21/plan"
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
FAILED=0; ERRORED=0
out=\$("$ZERO21" claim F1D 2>&1 >/dev/null); rc=\$?
check "T21 fork exit" "\$rc" "1"
case "\$out" in *"peer owns it"*) msgok=no ;; *fatal*|*FATAL*) msgok=yes ;; *) msgok=no ;; esac
# want git's own missing-ref message, not the generic "peer owns it"
check "T21 fork stderr names missing ref" "\$msgok" "yes"
# the coordination claim was released
check "T21 fork no wt" "\$(git worktree list | grep -c 'task-F1D')" "0"
twt=\$("$ZERO21" claim R1D); rc=\$?
# no base ref needed
check "T21 reattach exit" "\$rc" "0"
check "T21 reattach br" "\$(git -C "\$twt" symbolic-ref --short HEAD 2>/dev/null)" "R1D-anything"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
bash "$T21/drive.sh"; fold "$?"
# with main (the target base) deleted, a fork-mode claim (F1D, no existing branch) returns 1
# with git's own stderr naming the missing ref, prints nothing on stdout, and releases its
# coordination claim; a reattach-mode claim (R1D, existing branch) still succeeds, since
# reattach needs no base ref.

# T22 — a hand-deleted tt-…/ts-… directory is pruned and the branch reclaimed
T22="$TESTROOT/T22"; mkdir -p "$T22/code" "$T22/plan" "$T22/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T22/bin/claude"; chmod +x "$T22/bin/claude"
mkrepo "$T22/code"
( cd "$T22/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] P1D prune me\n' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/P1D.md
  git add -A; git commit -qm todo )
( cd "$T22/code"; PATH="$T22/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T22/plan/todo.md" >/dev/null 2>&1 || true )
ZERO22="$T22/plan/.git/zero.sh"
cat > "$T22/drive1.sh" <<DRIVE
set -uo pipefail
cd "$T22/plan"
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
twt=\$("$ZERO22" claim P1D)
echo "\$twt" > "$T22/wt1.out"
DRIVE
bash "$T22/drive1.sh"
wt1=$(cat "$T22/wt1.out")
own1=$(git -C "$T22/plan" worktree list --porcelain | awk -v b="refs/heads/main-task-P1D" '/^worktree /{p=substr($0,10)} /^branch /{if(substr($0,8)==b){print p;exit}}')

zap "$wt1"        # hand-deleted target worktree, registry entry survives
zap "$own1"        # hand-deleted coordination worktree too

cat > "$T22/drive2.sh" <<DRIVE2
set -uo pipefail
cd "$T22/plan"
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
FAILED=0; ERRORED=0
twt2=\$("$ZERO22" claim P1D); rc=\$?
# a fresh worktree, not stuck at rc 3
check "T22 exit" "\$rc" "0"
check "T22 fresh dir" "\$([ -d "\$twt2" ] && [ "\$twt2" != "$wt1" ] && echo yes || echo NO)" "yes"
# want P1D-prune-me or similar main-task branch name
check "T22 branch present" "\$(b=\$(git -C "\$twt2" symbolic-ref --short HEAD 2>/dev/null); case "\$b" in P1D-prune-me|main-task-P1D) echo yes;; *) echo NO;; esac)" "yes"
# prune cleared the stale entry
check "T22 registry clean" "\$(git worktree list --porcelain | grep -c "$wt1")" "0"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE2
bash "$T22/drive2.sh"; fold "$?"
# after both the target and coordination worktrees are deleted by hand while their registry
# entries survive, the next claim P1D returns 0 with fresh worktrees (not rc 3), git worktree
# list no longer names the deleted paths (worktree prune cleared them), and the branches are
# reattached rather than duplicated.

# T23 — .owner line 5 failing the candidate filters reads as missing, never repaired/reset
# $TARGET_ROOT itself is never a valid candidate (outside $WT_PARENT/tt-) — hand-setting line 5
# to it and leaving a conflicted merge there proves the merge is never touched.
T23="$TESTROOT/T23"; mkdir -p "$T23/code" "$T23/plan" "$T23/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T23/bin/claude"; chmod +x "$T23/bin/claude"
mkrepo "$T23/code"
( cd "$T23/code"; git checkout -qb side; echo y > f; git commit -qam side
  git checkout -q main; echo z > f; git commit -qam mainedit )   # diverge f on both sides -> a real conflict
( cd "$T23/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] O1D owner line5\n' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/O1D.md
  git add -A; git commit -qm todo )
( cd "$T23/code"; PATH="$T23/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T23/plan/todo.md" >/dev/null 2>&1 || true )
ZERO23="$T23/plan/.git/zero.sh"
cat > "$T23/drive1.sh" <<DRIVE
set -uo pipefail
cd "$T23/plan"
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
twt=\$("$ZERO23" claim O1D)
echo "\$twt" > "$T23/wt1.out"
DRIVE
bash "$T23/drive1.sh"
own1=$(git -C "$T23/plan" worktree list --porcelain | awk -v b="refs/heads/main-task-O1D" '/^worktree /{p=substr($0,10)} /^branch /{if(substr($0,8)==b){print p;exit}}')

# hand-set .owner line 5 to $TARGET_ROOT itself, then conflict a merge there
awk -v r="$T23/code" 'NR==5{$0=r} {print}' "$own1/.owner" > "$own1/.owner.tmp" && mv "$own1/.owner.tmp" "$own1/.owner"
( cd "$T23/code"; git merge side >/dev/null 2>&1 || true )
# shellcheck disable=SC2015
before_mh=$(cd "$T23/code" && git rev-parse -q --verify MERGE_HEAD || true)

cat > "$T23/drive2.sh" <<DRIVE2
set -uo pipefail
cd "$T23/plan"
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
"$ZERO23" release O1D
DRIVE2
bash "$T23/drive2.sh"

# shellcheck disable=SC2015
after_mh=$(cd "$T23/code" && git rev-parse -q --verify MERGE_HEAD || true)
# release never ran repair/abort/reset against $TARGET_ROOT
check "T23 merge untouched" "$([ "$before_mh" = "$after_mh" ] && [ -n "$after_mh" ] && echo yes || echo NO)" "yes"
( cd "$T23/code"; git merge --abort >/dev/null 2>&1 || true )
# a .owner line 5 hand-set to $TARGET_ROOT (which fails the $WT_PARENT/tt- filter) is treated as
# a missing line 5: release's teardown leaves the conflicted MERGE_HEAD at $TARGET_ROOT exactly
# as it was, runs no repair, abort or reset there.

# T24 — a target branch renamed out of the id's namespace is caught, not silently re-adopted
T24="$TESTROOT/T24"; mkdir -p "$T24/code" "$T24/plan" "$T24/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T24/bin/claude"; chmod +x "$T24/bin/claude"
mkrepo "$T24/code"
( cd "$T24/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] D1D drift me\n' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/D1D.md
  git add -A; git commit -qm todo )
( cd "$T24/code"; PATH="$T24/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T24/plan/todo.md" >/dev/null 2>&1 || true )
ZERO24="$T24/plan/.git/zero.sh"
cat > "$T24/drive1.sh" <<DRIVE
set -uo pipefail
cd "$T24/plan"
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
twt=\$("$ZERO24" claim D1D)
echo "\$twt" > "$T24/wt1.out"
DRIVE
bash "$T24/drive1.sh"
wt1=$(cat "$T24/wt1.out")
( cd "$wt1" && git branch -m feature-unrelated )   # renamed out of the D1D- namespace

cat > "$T24/drive2.sh" <<DRIVE2
set -uo pipefail
cd "$T24/plan"
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
FAILED=0; ERRORED=0
out=\$("$ZERO24" claim D1D 2>&1 >/dev/null); rc=\$?
check "T24 exit" "\$rc" "3"
case "\$out" in *checkout*) hint=yes ;; *) hint=no ;; esac
# want to name the drift and a checkout hint
check "T24 stderr names drift with checkout hint" "\$hint" "yes"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE2
bash "$T24/drive2.sh"; fold "$?"
# main checkout + the one tt-, never a second
check "T24 one tt- total" "$(git -C "$T24/code" worktree list --porcelain | grep -c '^worktree ')" "2"
# unchanged, no auto-checkout
check "T24 branch still" "$(git -C "$wt1" symbolic-ref --short HEAD 2>/dev/null)" "feature-unrelated"
# after the target branch is renamed out of D1D's namespace, the next claim D1D finds the
# worktree via .owner line 5 (no survivor branch names it any more), and exits 3 naming the
# drift instead of silently forking a duplicate — git worktree list still shows exactly one
# tt-… for this id, and the renamed branch is left exactly as it was.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
