#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=35s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-014-the-same-repository-land-gate — `merge_same_repo`'s own land gate, with SAME_REPO=1 (one
# fixture repository holding both code and todo).
# Needs real claude: no — this shell writes its own KAIZERO_SESSION_RECORD (BUG 057)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T22
#
# What happens when a task lands with one fixture repository: merge_same_repo's own land gate — an
# unrelated staged file surviving the merge, a rejected tick commit failing at the land gate, a
# human-deleted checkbox line refusing the merge, a task branch that itself touches the todo file
# being refused rather than treated as a conflict, a branch with no commit of its own, a rejecting
# pre-merge-commit hook and the crash marker it leaves behind, and main held by a second worktree.

# T22 — `merge_same_repo`'s own land gate (single-repository case) (stub claude)
T22="$TESTROOT/T22"; mkdir -p "$T22/repo" "$T22/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T22/bin/claude"; chmod +x "$T22/bin/claude"
cd "$T22/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] S1 staged file task\n- [ ] S2 pre-commit task\n- [ ] S3 absent line task\n- [ ] S4 touches todo task\n- [ ] S5 two commits task\n- [ ] S6 no-commit task\n- [ ] S7 code-hook task\n- [ ] S8 second-worktree task\n' > todo.md
mkdir -p tasks
for f in S1 S2 S3 S4 S5 S6 S7 S8; do printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/$f.md"; done
git add -A; git commit -qm init
PATH="$T22/bin:$PATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge todo.md >/dev/null 2>&1 || true
ZERO="$(cd "$(git rev-parse --git-dir)" && pwd)/zero.sh"
# BUG 057: ensure_owner needs a valid KAIZERO_SESSION_RECORD — this shell IS the process the
# record names, so every "$ZERO" call below inherits it.
own_session "$T22/rec"

# S5: HEAD is the tick commit atop the --no-ff merge commit (zero.sh's own two writes), git show
# --stat HEAD lists only the todo file.
WT5=$("$ZERO" claim S5)
git -C "$WT5" commit -q --allow-empty -m "S5 work"
"$ZERO" merge S5 "$WT5" >/dev/null; rc=$?
check "T22 S5 merge exit" "$rc" "0"
check "T22 S5 last two subjects" "$(git log --format=%s -2 | tr '\n' '|')" "zero S5|merge main-task-S5|"
check "T22 S5 stat only todo" "$(git show --stat HEAD | grep -c 'todo.md')" "1"

# S1: an unrelated tracked file staged in the main checkout does not block the merge and survives.
WT1=$("$ZERO" claim S1)
git -C "$WT1" commit -q --allow-empty -m "S1 work"
echo staged > unrelated.txt; git add unrelated.txt
out=$("$ZERO" merge S1 "$WT1" 2>&1); rc=$?
check "T22 S1 merge exit" "$rc" "0"
check "T22 S1 stat only todo" "$(git show --stat HEAD | grep -c 'todo.md')" "1"
# want 1 — still staged, still uncommitted
check "T22 S1 unrelated staged" "$(git diff --cached --name-only | grep -c '^unrelated.txt$')" "1"

# S2: a pre-commit hook rejecting the tick's commit fails the merge at the land gate, todo left
# clean against HEAD, worktree + branch kept; a retry once the hook is gone lands with one tick.
WT2=$("$ZERO" claim S2)
git -C "$WT2" commit -q --allow-empty -m "S2 work"
mkdir -p .git/hooks
printf '#!/usr/bin/env bash\ngit diff --cached --name-only | grep -q "^todo.md$" && exit 1\nexit 0\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
out=$("$ZERO" merge S2 "$WT2" 2>&1); rc=$?
check "T22 S2 hook-reject exit" "$rc" "5"
check "T22 S2 no merged line" "$(printf '%s' "$out" | grep -c 'merged to')" "0"
check "T22 S2 worktree kept" "$([ -d "$WT2" ] && echo yes || echo NO)" "yes"
check "T22 S2 todo clean vs HEAD" "$(git diff --quiet HEAD -- todo.md && git diff --cached --quiet -- todo.md && echo yes || echo no)" "yes"
rm -f .git/hooks/pre-commit
"$ZERO" merge S2 "$WT2" >/dev/null; rc2=$?
check "T22 S2 retry exit" "$rc2" "0"
check "T22 S2 exactly one tick" "$(git log --format=%s | grep -c '^zero S2$')" "1"

# S3: a human deleting the task's line from base while it is in flight refuses the merge; restoring
# the line lets a retry land.
WT3=$("$ZERO" claim S3)
git -C "$WT3" commit -q --allow-empty -m "S3 work"
sed -i.bak '/S3 absent line task/d' todo.md; rm -f todo.md.bak
git add todo.md; git commit -qm "human deletes S3 line"
out=$("$ZERO" merge S3 "$WT3" 2>&1); rc=$?
check "T22 S3 absent exit" "$rc" "5"
check "T22 S3 no merge commit" "$(git log --format=%s | grep -c '^merge main-task-S3$')" "0"
printf -- '- [ ] S3 absent line task\n' >> todo.md
git add todo.md; git commit -qm "human restores S3 line"
"$ZERO" merge S3 "$WT3" >/dev/null; rc2=$?
check "T22 S3 retry exit" "$rc2" "0"

# S4: a task branch that itself edits todo.md is refused at the land gate (exit 5, never the
# conflict path's exit 2) — base left clean, branch and worktree kept, box left unchecked.
WT4=$("$ZERO" claim S4)
echo extra >> "$WT4/todo.md"; git -C "$WT4" add todo.md; git -C "$WT4" commit -qm "S4 touches todo"
out=$("$ZERO" merge S4 "$WT4" 2>&1); rc=$?
# want 5, not 2
check "T22 S4 touch-todo exit" "$rc" "5"
check "T22 S4 names todo" "$(printf '%s' "$out" | grep -c 'todo.md')" "1"
check "T22 S4 base clean" "$([ -z "$(git status --porcelain)" ] && echo yes || echo no)" "yes"
check "T22 S4 worktree kept" "$([ -d "$WT4" ] && echo yes || echo NO)" "yes"
check "T22 S4 box unchecked" "$(grep -c '\[ \] S4' todo.md)" "1"
"$ZERO" release S4 >/dev/null 2>&1   # one task per session: free the slot before S6's own claim

# S6: a claimed branch that never picked up a commit of its own (the land gate's test 3) is refused even
# though its tip is trivially an ancestor of main — no merge is attempted, the box stays open.
WT6=$("$ZERO" claim S6)
before6=$(git rev-list --count main)
out=$("$ZERO" merge S6 "$WT6" 2>&1); rc=$?
after6=$(git rev-list --count main)
check "T22 S6 no-commit exit" "$rc" "5"
check "T22 S6 says carries no change" "$(printf '%s' "$out" | grep -c 'carries no change')" "1"
check "T22 S6 no merge happened" "$([ "$before6" -eq "$after6" ] && echo yes || echo NO)" "yes"
check "T22 S6 box unchecked" "$(grep -c '\[ \] S6' todo.md)" "1"
"$ZERO" release S6 >/dev/null 2>&1   # one task per session: free the slot before S7's own claim

# S7: a pre-merge-commit hook that always rejects fails the code+box merge itself (no unmerged
# paths, so exit 5 — never the conflict path) and quotes the hook's own stderr; MERGE_HEAD and the
# crash marker both survive the failure, so once the hook is gone the very next merge recognises
# the leftover MERGE_HEAD as its own wreck, aborts it, and lands with exactly one merge commit.
WT7=$("$ZERO" claim S7)
git -C "$WT7" commit -q --allow-empty -m "S7 work"
printf '#!/usr/bin/env bash\necho "code hook blocked" >&2\nexit 1\n' > .git/hooks/pre-merge-commit
chmod +x .git/hooks/pre-merge-commit
out=$("$ZERO" merge S7 "$WT7" 2>&1); rc=$?
check "T22 S7 hook-reject exit" "$rc" "5"
check "T22 S7 quotes hook stderr" "$(printf '%s' "$out" | grep -c 'code hook blocked')" "1"
# want yes — a human's own state this same failure would leave behind too
check "T22 S7 merge-head present" "$([ -f .git/MERGE_HEAD ] && echo yes || echo NO)" "yes"
check "T22 S7 marker survives" "$(ls .git/merge-inflight-* 2>/dev/null | wc -l | tr -d ' ')" "1"
rm -f .git/hooks/pre-merge-commit
"$ZERO" merge S7 "$WT7" >/dev/null; rc2=$?
check "T22 S7 retry exit" "$rc2" "0"
check "T22 S7 exactly one merge" "$(git log --format=%s | grep -c '^merge main-task-S7$')" "1"
check "T22 S7 marker cleared" "$(ls .git/merge-inflight-* 2>/dev/null | wc -l | tr -d ' ')" "0"

# S8: the coordination main checkout is on another branch while main sits checked out in a second
# worktree of the same repository (a clean tree, so the quiet test alone would pass) — the checkout
# itself fails, so merge exits 5 rather than corrupting whatever HEAD happened to be; the
# operator's own branch, still checked out, is left exactly as it was.
WT8=$("$ZERO" claim S8)
git -C "$WT8" commit -q --allow-empty -m "S8 work"
git checkout -q -b operator-branch8
SIDE8="$T22/side8"
git worktree add -q "$SIDE8" main
out=$("$ZERO" merge S8 "$WT8" 2>&1); rc=$?
check "T22 S8 checkout-fail exit" "$rc" "5"
check "T22 S8 names coord root" "$(printf '%s' "$out" | grep -c "$T22/repo")" "1"
check "T22 S8 operator branch kept" "$([ "$(git symbolic-ref --short HEAD)" = "operator-branch8" ] && echo yes || echo NO)" "yes"
check "T22 S8 no zero commit elsewhere" "$(git log --format=%s operator-branch8 | grep -c '^zero S8$')" "0"
git worktree remove --force "$SIDE8" 2>/dev/null || true
git checkout -q main
# T22 PASS — S5 lands with exactly two new commits and a stat touching only the todo file; S1's
# unrelated staged file blocks nothing and survives untouched; S2's rejected tick fails the merge
# at the land gate (exit 5) leaving the todo clean and the worktree/branch in place, and a retry
# after the hook is gone lands with exactly one zero S2 commit; S3's deleted line refuses the merge
# and a restored line lets the retry land; S4's todo-editing branch is refused with exit 5, never
# the exit-2 conflict path, base left clean and nothing torn down; S6's branch with no commit of
# its own is refused by test 3 with no merge attempted; S7's pre-merge-commit hook fails the merge
# itself (not a conflict) and the crash marker it leaves behind is exactly what lets the retry,
# once the hook is gone, abort the leftover MERGE_HEAD and land with one merge commit, not two;
# S8's checkout failure (main already held by a second worktree) exits 5 and leaves the operator's
# own branch untouched.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
