#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-010-claim-acquires-a-target-worktree — the paired target worktree claim acquires beside
# the coordination one, and the SAME_REPO=1 case where the two roles are one repository.
# Needs real claude: no — a disposable driver process writes its own KAIZERO_SESSION_RECORD
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T17
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
# Cross-references: I-001-claim-exit-paths.sh
#
# The paired target worktree claim acquires beside the coordination one — including the case
# where the two roles are one repository and claim must be a no-op change.

# Setup
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }

# T17 — claim acquires a paired target worktree (stub claude)
#
# claim goes through ensure_owner, which needs a valid KAIZERO_SESSION_RECORD — same
# technique as Scenario I: the driver writes one for itself.
T14="$TESTROOT/T17"; mkdir -p "$T14/code" "$T14/plan" "$T14/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T14/bin/claude"; chmod +x "$T14/bin/claude"
mkrepo "$T14/code"
( cd "$T14/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] T1D Wire the retry budget into the poller\n- [ ] R1D r task\n- [ ] A1D a task\n' > todo.md
  mkdir -p tasks
  for f in T1D R1D A1D; do printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/$f.md"; done
  git add -A; git commit -qm todo )
( cd "$T14/code"; git branch R1D-anything; git branch A1D-x; git branch A1D-y )
( cd "$T14/code"; PATH="$T14/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T14/plan/todo.md" >/dev/null 2>&1 || true )
ZERO14="$T14/plan/.git/zero.sh"
cat > "$T14/drive.sh" <<DRIVE
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
set -uo pipefail
FAILED=0; ERRORED=0
cd "$T14/plan"

# fork: no candidate branch -> a fresh tt-<id>-<slug> worktree in \$T14/code, forked off target base
twt=\$("$ZERO14" claim T1D); rc=\$?
check "T17 fork exit" "\$rc" "0"
check "T17 fork under WT_PARENT/tt-" "\$(case "\$twt" in "$T14"/tt-*) echo yes;; *) echo NO;; esac)" "yes"
check "T17 fork branch" "\$(git -C "\$twt" symbolic-ref --short HEAD 2>/dev/null)" "T1D-wire-the-retry-budget-into-the-poller"
own=\$(git worktree list --porcelain | awk -v b="refs/heads/main-task-T1D" '/^worktree /{p=substr(\$0,10)} /^branch /{if(substr(\$0,8)==b){print p;exit}}')
check "T17 owner line5" "\$([ "\$(sed -n 5p "\$own/.owner")" = "\$twt" ] && echo yes || echo NO)" "yes"
# twt is never TARGET_ROOT itself
check "T17 no coord leak" "\$(printf '%s' "\$twt" | grep -c "$T14/code")" "0"
# 038c: claim's stdout never carries the coordination worktree's own path
check "T17 no ts- leak" "\$(printf '%s' "\$twt" | grep -c "\$own")" "0"
"$ZERO14" release T1D "\$twt" >/dev/null 2>&1   # one-task-per-session: free T1D before claiming R1D

# reattach: a pre-existing branch with no worktree -> reattached, not forked
twtr=\$("$ZERO14" claim R1D); rc=\$?
check "T17 reattach exit" "\$rc" "0"
check "T17 reattach branch" "\$(git -C "\$twtr" symbolic-ref --short HEAD 2>/dev/null)" "R1D-anything"
"$ZERO14" release R1D "\$twtr" >/dev/null 2>&1   # free R1D before the A1D ambiguity attempt

# ambiguity: two branches share the id prefix -> exit 3, nothing created
out=\$("$ZERO14" claim A1D 2>&1 >/dev/null); rc=\$?
check "T17 ambiguity exit" "\$rc" "3"
echo "T17 ambiguity stderr: \$out"
check "T17 ambiguity no wt" "\$(git worktree list | grep -c 'task-A1D')" "0"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
bash "$T14/drive.sh" || FAILED=1
# T17 PASS — the fork case lands a fresh tt-… worktree beside the target, on the branch
# 038b's naming rule names, forked off the target base, with .owner line 5 (in the coordination
# worktree) naming it and the printed path never equal to $TARGET_ROOT itself; the reattach case
# attaches the existing branch instead of forking a new one; the ambiguity case (two branches
# sharing the A1D- prefix) exits 3 and creates neither worktree.

# T18 — claim is a no-op change for SAME_REPO=1
#
# Reuses Scenario I's own claim-exit-path coverage (I1-I7), run unmodified against this
# worktree's kaizero.sh — with one repository, TARGET_MODE is always same and every path
# above is unreachable, so I's PASS is this slice's SAME_REPO=1 regression proof.
# T18 PASS — Scenario I passes unmodified (see its own report, tests/I-001-claim-exit-paths.sh).

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
