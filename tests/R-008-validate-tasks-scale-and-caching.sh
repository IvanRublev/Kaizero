#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# R-008-validate-tasks-scale-and-caching — `zero.sh validate-tasks`: the findings cap and its
# trailing count, the absence of any cache (a real-filesystem read every call), and a 250-id tail
# that crosses a `find` batch boundary.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/R-008-validate-tasks-scale-and-caching
# Wall-clock budget: seconds — no Run command of this scenario wraps itself in timeout
# Cross-references: R-003-validate-ids-cache-and-the-launch-gate.sh shares its launch-gate/cache
# shape by contrast — validate-tasks caches nothing.
#
# `zero.sh validate-tasks` is a new sibling of `validate-ids` (ISSUE 051): for every unchecked id
# on the Release Todo List's own tail, it resolves the Task file by id and checks it for a
# checkboxed Acceptance Criteria section. Each case gets its own throwaway repo, single-repo mode
# ($COORD_ROOT = $TARGET_ROOT) unless a case says otherwise.

# Setup
TR="$TESTROOT/R-008-validate-tasks-scale-and-caching"; mkdir -p "$TR/bin"
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

# R4-8 — cap at 5 findings plus a trailing count; 5 or fewer prints every one
newrepo r8
{
  printf -- '- [x] Z0 seed\n'
  for i in 1 2 3 4 5 6 7; do printf -- '- [ ] MISS%s x\n' "$i"; done
} > todo.md; git add -A; git commit -qm t8
"$ZERO" validate-tasks > "$TR/r8.out" 2>&1
check "R4-8 exit" "$?" "1"
check "R4-8 shown" "$(grep -c '^missing-task-file' "$TR/r8.out")" "5"
check "R4-8 more" "$(grep -c '… and 2 more' "$TR/r8.out")" "1"

newrepo r8b
{
  printf -- '- [x] Z0 seed\n'
  for i in 1 2 3; do printf -- '- [ ] MISS%s x\n' "$i"; done
} > todo.md; git add -A; git commit -qm t8b
"$ZERO" validate-tasks > "$TR/r8b.out" 2>&1
check "R4-8b exit" "$?" "1"
check "R4-8b shown" "$(grep -c '^missing-task-file' "$TR/r8b.out")" "3"
check "R4-8b no more line" "$([ "$(grep -c '… and' "$TR/r8b.out")" = 0 ] && echo yes || echo NO)" "yes"
# R4-8 PASS — capped at 5 with a trailing "… and N more"; a tail of 5 or fewer prints every
# finding with no trailing line.

# R4-9 — no cache: an uncommitted, on-disk-only edit is caught on the very next call
newrepo r9
mkdir -p tasks
printf -- '- [x] Z0 seed\n- [ ] TASK-9x live\n' > todo.md; git add -A; git commit -qm t9
printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/TASK-9x.md
"$ZERO" validate-tasks
check "R4-9 clean" "$?" "0"
printf -- 'no ac heading\n' > tasks/TASK-9x.md
"$ZERO" validate-tasks > "$TR/r9.out" 2>&1
# no cache, real filesystem read every call
check "R4-9 after uncommitted edit" "$?" "1"
check "R4-9 finding" "$(grep -c '^empty-acceptance-criteria TASK-9x:' "$TR/r9.out")" "1"
git add -A; git commit -qm "commit the edit"
"$ZERO" validate-tasks > "$TR/r9b.out" 2>&1
# same, committing changes nothing
check "R4-9 after commit" "$?" "1"
# R4-9 PASS — a real-filesystem edit is caught immediately, committed or not; there is no
# cache to go stale either way, unlike validate-ids' SHA-keyed one (R-003).

# R4-11 — a 250-id tail (two `find` batches, unioned before any `canon()` check runs)
newrepo r11
mkdir -p tasks
{
  printf -- '- [x] Z0 seed\n'
  for i in $(seq 1 250); do printf -- '- [ ] TASK-%s x\n' "$i"; done
} > todo.md
for i in $(seq 1 250); do printf -- '### Acceptance criteria\n- [ ] a\n' > "tasks/TASK-$i.md"; done
git add -A; git commit -qm t11
"$ZERO" validate-tasks > "$TR/r11.out" 2>&1
check "R4-11 exit" "$?" "0"
check "R4-11 output" "$(wc -c < "$TR/r11.out" | tr -d ' ')" "0"
# R4-11 PASS — all 250 resolve clean, no false ambiguous-task-file from a file that matches
# a loose -iname glob in both the 1-200 and 201-250 batches (resolve_task_ids dedupes a path on
# insert before it is ever attributed to an id). The batching loop itself runs one find per
# ceil(n/200), so a 250-id tail invokes it exactly twice by construction.

# R PASS — R4-8, R4-9 and R4-11 all report PASS.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
