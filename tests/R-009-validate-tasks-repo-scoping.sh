#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# R-009-validate-tasks-repo-scoping — `zero.sh validate-tasks`: what `find`'s root does and
# does not see — a task worktree's own copy, the target repo in two-repo mode — and the id-folding
# and directory rules that decide what counts as a match.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/R-009-validate-tasks-repo-scoping
# Wall-clock budget: seconds — no Run command of this scenario wraps itself in timeout
#
# `zero.sh validate-tasks` is a new sibling of `validate-ids` (ISSUE 051): for every unchecked id
# on the Release Todo List's own tail, it resolves the Task file by id and checks it for a
# checkboxed Acceptance Criteria section. Each case gets its own throwaway repo, single-repo mode
# ($COORD_ROOT = $TARGET_ROOT) unless a case says otherwise.

# Setup
TR="$TESTROOT/R-009-validate-tasks-repo-scoping"; mkdir -p "$TR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/claude"; chmod +x "$TR/bin/claude"

# fresh repo under $TR/$1, one seed commit, real zero.sh emitted (no claude launch needed).
# Sets $ZERO for the caller and leaves cwd inside the new repo.
newrepo(){
  local d="$TR/$1"; mkdir -p "$d"; cd "$d"
  git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [x] Z0 seed\n' > todo.md; git add -A; git commit -qm init
  KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
  ZERO="$d/.git/zero.sh"
}

# R4-10 — a task worktree's own copy of the Task file is not a second match
newrepo r10
mkdir -p tasks
printf -- '- [x] Z0 seed\n- [ ] TASK-7 wt\n' > todo.md; git add -A; git commit -qm t10
printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/TASK-7.md
git worktree add -q -b main-task-TASK-7 "$TR/r10-ts-TASK-7" main >/dev/null 2>&1
mkdir -p "$TR/r10-ts-TASK-7/tasks"
printf -- '### Acceptance criteria\n- [ ] a\n' > "$TR/r10-ts-TASK-7/tasks/TASK-7.md"
"$ZERO" validate-tasks > "$TR/r10.out" 2>&1
# no ambiguous-task-file
check "R4-10 exit" "$?" "0"
check "R4-10 no ambiguous" "$([ "$(grep -c ambiguous "$TR/r10.out")" = 0 ] && echo yes || echo NO)" "yes"
# R4-10 PASS — find "$COORD_ROOT" … is rooted there and structurally cannot see a sibling
# worktree under $WT_PARENT.

# R4-12 — two-repo mode: a Task file placed only under $TARGET_ROOT resolves as missing
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mkrepo "$TR/r12-code"; mkrepo "$TR/r12-plan"
( cd "$TR/r12-plan"; printf -- '- [ ] TASK-99 two-repo\n' > todo.md; git add todo.md; git commit -qm todo )
( cd "$TR/r12-code"; KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge "$TR/r12-plan/todo.md" -t x > /dev/null 2>&1 )
mkdir -p "$TR/r12-code/tasks"
printf -- '### Acceptance criteria\n- [ ] a\n' > "$TR/r12-code/tasks/TASK-99.md"
Z12="$TR/r12-plan/.git/zero.sh"
"$Z12" validate-tasks > "$TR/r12.out" 2>&1
check "R4-12 exit" "$?" "1"
# find never searches $TARGET_ROOT
check "R4-12 finding" "$(grep -c '^missing-task-file TASK-99:' "$TR/r12.out")" "1"
# R4-12 PASS — a Task file that exists only in the target (code) repo is invisible to the
# resolver, which is rooted at $COORD_ROOT alone; it reports missing-task-file, not a silent
# cross-repo pick.

# R4-13 — id-token folding, a space in a Task file's own name, and an unrelated third directory
newrepo r13
mkdir -p tasks spec
printf -- '### Acceptance criteria\n- [ ] a\n' > "tasks/TASK-14 notes.md"
printf -- '### Acceptance criteria\n- [ ] a\n' > "spec/TASK-15.md"
printf -- '### Acceptance criteria\n- [ ] a\n' > "tasks/TASK-16.md"
for tok in "TASK-16" "TASK_16" "task_16"; do
  printf -- '- [x] Z0 seed\n- [ ] %s variant\n' "$tok" > todo.md; git add -A; git commit -qm "v" -q
  "$ZERO" validate-tasks
  # folds onto TASK-16.md regardless of case/separator
  check "R4-13 token '$tok'" "$?" "0"
done
printf -- '- [x] Z0 seed\n- [ ] TASK-14 spacey file\n' > todo.md; git add -A; git commit -qm sp
"$ZERO" validate-tasks
# result handling is null-delimited
check "R4-13 space-in-filename" "$?" "0"
printf -- '- [x] Z0 seed\n- [ ] TASK-15 third dir\n' > todo.md; git add -A; git commit -qm td
"$ZERO" validate-tasks
# no tasks/docs-first special case
check "R4-13 unrelated third directory" "$?" "0"
# R4-13 PASS — canon() folds case and separator differences onto one identity; a Task
# file's own name may contain a space; resolution reaches any directory under $COORD_ROOT, not
# just tasks/ / docs/.

# R PASS — R4-10, R4-12 and R4-13 all report PASS.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
