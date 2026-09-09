#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# R-005-validate-ids-pattern-class — leg 1 — the missing-id and pattern-fail classes a live
# todo can fail, the KAIZERO_TASK_ID_PATTERN override that governs them, and its help text.
# - Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# - Tools beyond the shared prerequisites: none
# - Folder under $TESTROOT: $TESTROOT/R-005-validate-ids-pattern-class
# - Wall-clock budget: seconds — no Run command of this scenario wraps itself in timeout
#
# Task id validation moved out of the prompt's own reading into a deterministic
# .git/zero.sh validate-ids: leg 1 scans the current base version. Each case gets its own
# throwaway repo (history is permanent evidence to the validator, so an earlier case's commits
# must never leak into a later "clean" assertion). Ids below always carry a digit unless the point
# of the case IS the no-digit/no-token failure — the default KAIZERO_TASK_ID_PATTERN requires
# one. Format conversion of tests/R-005-validate-ids-pattern-class.md (ISSUE-058c) — every case
# already existed and already passed.

TR="$TESTROOT/R-005-validate-ids-pattern-class"; mkdir -p "$TR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/claude"; chmod +x "$TR/bin/claude"

# fresh repo under $TR/$1, one seed commit, real zero.sh emitted (no claude launch needed).
# Sets $ZERO for the caller and leaves cwd inside the new repo. The cache filename is a hash of
# (base, todo path, pattern) — not fixed — so callers look it up with cache_of "$d" instead of
# a hardcoded name.
newrepo(){
  local d="$TR/$1"; mkdir -p "$d"; cd "$d"
  git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] Z0 seed\n' > todo.md; git add -A; git commit -qm init
  KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
  ZERO="$d/.git/zero.sh"
}

# R3 — no-token and pattern-failing ids, and the KAIZERO_TASK_ID_PATTERN override
newrepo r3
printf -- '- [ ]\n- [ ] fix the login bug\n' > todo.md; git add -A; git commit -qm "missing+prose"
"$ZERO" validate-ids > "$TR/r3.out" 2>&1; check "R3 exit" "$?" "1"
check "R3 none" "$(grep -c '^missing-id (none): todo.md:1' "$TR/r3.out")" "1"
check "R3 prose" "$(grep -c '^missing-id fix: todo.md:2' "$TR/r3.out")" "1"
check "R3 patfail line" "$(grep -c 'does not match KAIZERO_TASK_ID_PATTERN' "$TR/r3.out")" "1"   # only the prose line gets it
KAIZERO_TASK_ID_PATTERN='.' "$ZERO" validate-ids > "$TR/r3b.out" 2>&1; check "R3 pattern='.'" "$?" "1"   # the no-token line still fails
check "R3 pattern='.' no prose finding" "$(grep -c 'fix' "$TR/r3b.out")" "0"
# R3 PASS — both classes reported distinctly; . disables only the shape check.

# R13 — -h/--help names KAIZERO_TASK_ID_PATTERN and its default
H="$(bash "$SCRIPT" -h)"
check "R13 names the var" "$(printf '%s' "$H" | grep -c 'KAIZERO_TASK_ID_PATTERN=ere')" "1"
check "R13 says default" "$(printf '%s' "$H" | grep -c 'SMTH-855, 7, 7.a, TASK-030')" "1"
check "R13 dot disables" "$(printf '%s' "$H" | grep -c 'disables the shape check')" "1"
# R13 PASS — all three = 1.

# R17 — an operator ERE with a backslash escape reaches the matcher byte-for-byte
newrepo r17
printf -- '- [ ] Z0 seed\n- [ ] 7x9 prose-ish id\n' > todo.md; git add -A; git commit -qm patt
KAIZERO_TASK_ID_PATTERN='^[0-9]+\.[0-9]+$' "$ZERO" validate-ids > "$TR/r17.out" 2>&1
check "R17 exit" "$?" "1"
check "R17 finding" "$(grep -c 'missing-id 7x9' "$TR/r17.out")" "1"   # a loosely-decoded \. would wrongly admit 7x9
# R17 PASS — 7x9 still fails the pattern: the \. reached awk intact via ENVIRON,
# never decoded by a -v assignment.

# R PASS — R3, R13 and R17 all report PASS.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
