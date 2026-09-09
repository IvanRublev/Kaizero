#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-021-target-worktree-adoption — a live sibling's worktree is never stolen or scanned into, and
# the target's own main checkout is never adopted as $twt.
# Needs real claude: no — a disposable driver process writes its own KAIZERO_SESSION_RECORD
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T19, $TESTROOT/T20
#
# The paired target worktree claim acquires is never stolen from a live sibling, never adopts the
# target's own main checkout.

mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }

# T19 — a live sibling's adopted target worktree is never taken, stolen, or scanned into
# Task 7's session stays ALIVE while task 7-1 claims, so its driver is backgrounded and held open
# with a sleep, then killed at the end. No 7-1 todo line exists yet when 7 claims, so 7 adopts the
# pre-existing branch 7-1-x (T13's "no sibling" rule); 7-1 is added to the todo only afterward.
T19="$TESTROOT/T19"; mkdir -p "$T19/code" "$T19/plan" "$T19/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T19/bin/claude"; chmod +x "$T19/bin/claude"
mkrepo "$T19/code"
( cd "$T19/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] 7 first task\n' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/7.md
  git add -A; git commit -qm todo )
( cd "$T19/code"; git branch 7-1-x )
( cd "$T19/code"; PATH="$T19/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T19/plan/todo.md" >/dev/null 2>&1 || true )
ZERO19="$T19/plan/.git/zero.sh"

cat > "$T19/hold7.sh" <<DRIVE
set -uo pipefail
cd "$T19/plan"
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
"$ZERO19" claim 7 > "$T19/wt7.out" 2>"$T19/wt7.err"
echo done > "$T19/hold7.claimed"
echo mark > "\$(cat "$T19/wt7.out")/mark.txt" 2>/dev/null || true
sleep 25
DRIVE
bash "$T19/hold7.sh" > "$T19/hold7.log" 2>&1 &
HOLD7=$!
for i in $(seq 1 100); do [ -f "$T19/hold7.claimed" ] && break; sleep 0.2; done
wt7=$(cat "$T19/wt7.out")
# diagnostic only, not a verdict — the case's own checks below cover this state
echo "T19 setup: 7 claimed on 7-1-x: $([ -n "$wt7" ] && [ "$(git -C "$wt7" symbolic-ref --short HEAD 2>/dev/null)" = 7-1-x ] && echo yes || echo NO)"

( cd "$T19/plan"; printf -- '- [ ] 7-1 subtask\n' >> todo.md
  printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/7-1.md
  git add -A; git commit -qm retitle )

cat > "$T19/claim71.sh" <<DRIVE2
set -uo pipefail
cd "$T19/plan"
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
FAILED=0; ERRORED=0
out=\$("$ZERO19" claim 7-1 2>&1 >/dev/null); rc=\$?
check "T19 7-1 exit" "\$rc" "1"
# want yes — git's real refusal, not the generic fallback; wording itself varies by git version
check "T19 7-1 stderr is git's own" "\$(case "\$out" in *already*) echo yes;; *) echo NO;; esac)" "yes"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE2
bash "$T19/claim71.sh" || FAILED=1

check "T19 7's worktree untouched" "$([ -d "$wt7" ] && [ -f "$wt7/mark.txt" ] && [ "$(git -C "$wt7" symbolic-ref --short HEAD 2>/dev/null)" = 7-1-x ] && echo yes || echo NO)" "yes"
# want 1 — the undo never forked or reattached a second one
check "T19 one tt- on 7-1-x total" "$(git -C "$T19/code" worktree list --porcelain | grep -c 'branch refs/heads/7-1-x$')" "1"
# want 2 — main checkout + 7's own tt-, nothing created for the failed 7-1 attempt
check "T19 total worktree count" "$(git -C "$T19/code" worktree list --porcelain | grep -c '^worktree ')" "2"

kill "$HOLD7" 2>/dev/null; wait "$HOLD7" 2>/dev/null || true
# T19 PASS — 7-1's claim fails with git's own refusal (the reattach onto 7-1-x collides with 7's
# live worktree — the exact wording is git's own and varies by version), exits 1, and the
# failed-acquire undo (release_task, called with nothing to hand it since nothing target-side was
# created) never picks up 7's worktree by scanning TARGET_ROOT for 7-1's candidate branches — 7's
# worktree, its branch and its uncommitted marker file are exactly as 7 left them, and no second
# worktree exists anywhere for 7-1-x.

# T20 — the target's main checkout is never adopted as $twt
T20="$TESTROOT/T20"; mkdir -p "$T20/code" "$T20/plan" "$T20/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T20/bin/claude"; chmod +x "$T20/bin/claude"
mkrepo "$T20/code"
( cd "$T20/code"; git checkout -qb SMTH-855-hotfix )
( cd "$T20/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] SMTH-855 fix it\n' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/SMTH-855.md
  git add -A; git commit -qm todo )
( cd "$T20/code"; PATH="$T20/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T20/plan/todo.md" >/dev/null 2>&1 || true )
ZERO20="$T20/plan/.git/zero.sh"
cat > "$T20/drive.sh" <<DRIVE
set -uo pipefail
FAILED=0; ERRORED=0
cd "$T20/plan"
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
out=\$("$ZERO20" claim SMTH-855 2>&1 >/dev/null); rc=\$?
check "T20 exit" "\$rc" "3"
# want to name the checkout and say 'switch it away'
check "T20 stderr names checkout" "\$(printf '%s' "\$out" | grep -c 'SMTH-855-hotfix')" "1"
check "T20 stderr says switch it away" "\$(printf '%s' "\$out" | grep -c 'switch it away')" "1"
check "T20 no wt" "\$(git worktree list | grep -c 'task-SMTH-855')" "0"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
bash "$T20/drive.sh" || FAILED=1
check "T20 code untouched" "$(cd "$T20/code" && git symbolic-ref --short HEAD)" "SMTH-855-hotfix"
# T20 PASS — with the operator's own checkout on SMTH-855-hotfix (the target's branch), claim
# SMTH-855 exits 3, names the checkout and says "switch it away", creates no coordination
# worktree, and never treats $TARGET_ROOT as $twt.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
