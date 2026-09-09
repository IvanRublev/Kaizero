#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-009-target-branch-naming-and-id-matching — the branch name a task forks computed from the
# todo blob alone, and the longest-id-wins rule that matches a line to an id.
# Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor tests
# `command -v claude` before any startup guard runs)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T-009-target-branch-naming-and-id-matching
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# The target branch a task lands on: how its name is computed from the todo blob alone, and the
# longest-id-wins rule that matches a line to an id.

# Setup
TT="$TESTROOT/T-009-target-branch-naming-and-id-matching"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
# --local-merge: none of these fixture repos carry an origin, so a two-repo case
# (SAME_REPO=0) would otherwise hit the new default-to-mr detection's "no origin" refusal before
# ever reaching the role-detection guards this scenario exists to test; the flag opts every case
# back into today's local-merge path, same-repo cases included (a harmless no-op there).
emit(){ ( cd "$1"; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1 ); }   # $1=launch dir $2=todo arg

# T13 — target branch naming + id-prefix matching, direct function calls
mkrepo "$TT/code13"; mkrepo "$TT/plan13"
( cd "$TT/plan13"
  printf -- '- [ ] 7 first task\n- [ ] 7-1 subtask\n- [ ] SMTH-8 eight\n- [ ] I6/a slashy\n' > todo.md
  git add todo.md; git commit -qm todo )
emit "$TT/code13" "$TT/plan13/todo.md" >/dev/null
ZS13="$TT/plan13/.git/zero.sh"
zs13() { ( cd "$TT/plan13" && bash "$ZS13" "$@" ); }
( cd "$TT/code13"
  git branch 7-add-flag; git branch 7-1-add-flag; git branch SMTH-85-other; git branch SMTH-8-eight
  git branch I6-a-x; git branch SMTH-855-x; git branch SMTH-855-y )

check "T13 slug" "$(zs13 target-branch SMTH-855 'Fix the!! Root -- guard')" "SMTH-855-fix-the-root-guard"
check "T13 empty slug -> task" "$(zs13 target-branch 7 '')" "7-task"
# 7-1-add-flag excluded, claimed by longer id 7-1
check "T13 longest-wins 7" "$(zs13 target-branches-for-id 7 | tr '\n' ' ')" "7-add-flag "
check "T13 longest-wins 7-1" "$(zs13 target-branches-for-id 7-1 | tr '\n' ' ')" "7-1-add-flag "
# never SMTH-85-other
check "T13 trailing-dash" "$(zs13 target-branches-for-id SMTH-8 | tr '\n' ' ')" "SMTH-8-eight "
check "T13 raw id I6/a" "$(zs13 target-branches-for-id 'I6/a' | tr '\n' ' ')" "I6-a-x "
# same as raw form
check "T13 sanitized I6-a" "$(zs13 target-branches-for-id 'I6-a' | tr '\n' ' ')" "I6-a-x "
check "T13 two survivors" "$(zs13 target-branches-for-id SMTH-855 | sort | tr '\n' ' ')" "SMTH-855-x SMTH-855-y "

# collision fixture (038b): id SMTH-855 titled "API rate limiting" beside sibling id SMTH-855-api —
# the naive name SMTH-855-api-rate-limiting would be claimed by SMTH-855-api, so target_branch
# widens the separator.
mkrepo "$TT/code13c"; mkrepo "$TT/plan13c"
( cd "$TT/plan13c"
  printf -- '- [ ] SMTH-855 API rate limiting\n- [ ] SMTH-855-api Follow-up work\n' > todo.md
  git add todo.md; git commit -qm todo )
emit "$TT/code13c" "$TT/plan13c/todo.md" >/dev/null
ZS13C="$TT/plan13c/.git/zero.sh"
zs13c() { ( cd "$TT/plan13c" && bash "$ZS13C" "$@" ); }
MINTED=$(zs13c target-branch SMTH-855 'API rate limiting')
# the naive SMTH-855-api-rate-limiting is claimed by sibling id SMTH-855-api
check "T13 collision slug" "$MINTED" "SMTH-855--api-rate-limiting"
( cd "$TT/code13c" && git branch "$MINTED" )
# the minted, widened name round-trips
check "T13 collision resolves" "$(zs13c target-branches-for-id SMTH-855 | tr '\n' ' ')" "$MINTED "
( cd "$TT/code13c" && git branch SMTH-855-foo/bar && git branch SMTH-855-plain )
# a '/' after '<id>-' never excludes a candidate
check "T13 slash survivor" "$(zs13c target-branches-for-id SMTH-855 | sort | tr '\n' ' ')" "$MINTED SMTH-855-foo/bar SMTH-855-plain "
# want empty — none of the three is SMTH-855-api's
check "T13 collision isolated" "$(zs13c target-branches-for-id SMTH-855-api | tr '\n' ' ')" ""

# second collision fixture (038b), the exact wording of the spec: id 7 titled "1 of three
# rewrites" beside sibling id 7-1.
mkrepo "$TT/code13d"; mkrepo "$TT/plan13d"
( cd "$TT/plan13d"
  printf -- '- [ ] 7 1 of three rewrites\n- [ ] 7-1 the subtask\n' > todo.md
  git add todo.md; git commit -qm todo )
emit "$TT/code13d" "$TT/plan13d/todo.md" >/dev/null
ZS13D="$TT/plan13d/.git/zero.sh"
zs13d() { ( cd "$TT/plan13d" && bash "$ZS13D" "$@" ); }
MINTED7=$(zs13d target-branch 7 '1 of three rewrites')
# 7-1-of-three-rewrites is claimed by sibling id 7-1
check "T13 collision slug 7" "$MINTED7" "7--1-of-three-rewrites"
( cd "$TT/code13d" && git branch "$MINTED7" )
# the minted, widened name round-trips
check "T13 collision resolves 7" "$(zs13d target-branches-for-id 7 | tr '\n' ' ')" "$MINTED7 "
( cd "$TT/code13d" && git branch 7-1 )
# still — the exact-name branch 7-1 is excluded, claimed by longer id 7-1
check "T13 exact-name excluded" "$(zs13d target-branches-for-id 7 | tr '\n' ' ')" "$MINTED7 "
# a branch named exactly the longer id is its own candidate
check "T13 exact-name sibling" "$(zs13d target-branches-for-id 7-1 | tr '\n' ' ')" "7-1 "

# no 7-1 todo-line sibling: target_branches_for_id 7 now includes 7-1-add-flag (no longer id claims it)
mkrepo "$TT/code13b"; mkrepo "$TT/plan13b"
( cd "$TT/plan13b"; printf -- '- [ ] 7 first task\n' > todo.md; git add todo.md; git commit -qm todo )
emit "$TT/code13b" "$TT/plan13b/todo.md" >/dev/null
( cd "$TT/code13b"; git branch 7-1-add-flag )
check "T13 no sibling" "$( ( cd "$TT/plan13b" && bash "$TT/plan13b/.git/zero.sh" target-branches-for-id 7 ) | tr '\n' ' ')" "7-1-add-flag "

# retitled todo line: target_branches_for_id matches by id prefix alone, never the branch's slug
( cd "$TT/code13"; git branch 9-old-title-branch )
( cd "$TT/plan13"; printf -- '- [ ] 9 brand new title\n' >> todo.md; git commit -qam retitle )
check "T13 retitled resolves" "$(zs13 target-branches-for-id 9)" "9-old-title-branch"

# longest-id-wins leaves NO survivor for 7: todo carries both 7 and 7-1, target holds only
# 7-1-foo — a scan that finds nothing has succeeded (rc 0), not just empty stdout (ISSUE-039b).
mkrepo "$TT/code13e"; mkrepo "$TT/plan13e"
( cd "$TT/plan13e"; printf -- '- [ ] 7 first task\n- [ ] 7-1 subtask\n' > todo.md; git add todo.md; git commit -qm todo )
emit "$TT/code13e" "$TT/plan13e/todo.md" >/dev/null
( cd "$TT/code13e"; git branch 7-1-foo )
(
  cd "$TT/plan13e"
  out=$(bash "$TT/plan13e/.git/zero.sh" target-branches-for-id 7); rc=$?
  check "T13 no-survivor rc" "$rc" "0"
  check "T13 no-survivor out" "[$out]" "[]"
)
# T13 PASS — the slug is lowercase/[a-z0-9-]-only/never dash-bounded, an empty slug becomes
# task; longest-id-wins drops 7-1-add-flag from id 7's survivors and keeps it for 7-1; the
# trailing - in the glob alone (no todo sibling needed) keeps SMTH-8 from matching
# SMTH-85-other; raw (I6/a) and sanitized (I6-a) forms of the same id resolve to the same
# branch; two same-id branches both survive (fork/reattach/refuse is 038c's call, not this
# function's); dropping the 7-1 todo line's sibling restores 7-1-add-flag to id 7's
# survivors; a branch found by id prefix resolves even after its todo line's title changed; on
# both collision fixtures (SMTH-855/SMTH-855-api and 7/7-1) the naive <id>-<slug> name
# would be claimed by the longer sibling id, so target_branch widens the separator and the
# minted name round-trips through target_branches_for_id for its own id and no other; a /
# anywhere after <id>- never excludes a candidate (SMTH-855-foo/bar); a branch named exactly a
# longer sibling id (7-1) is that id's own candidate and is excluded from the shorter id's
# survivors by the same longest-id rule; and when longest-id-wins leaves 7 with no survivor at
# all, target_branches_for_id exits 0 with empty stdout rather than rc 1, so an errexit caller
# may assign it plainly.

# T13b — bash 3.2 compat: no ${s,,} lowercasing construct anywhere in kaizero.sh
check "T13 bash 3.2 (no \${s,,})" "$(grep -c '\${[a-z_]*,,}' "$SCRIPT")" "0"
# T13b PASS — the count is 0.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
