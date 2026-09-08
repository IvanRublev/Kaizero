#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# R-001-validate-ids-current-file — leg 1 — the duplicate-id class a live todo can fail, its
# identity-folding rules, and the fenced box invisible to it.
# - Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# - Tools beyond the shared prerequisites: none
# - Folder under $TESTROOT: $TESTROOT/R-001-validate-ids-current-file
# - Wall-clock budget: seconds — no Run command of this scenario wraps itself in timeout
#
# Task id validation moved out of the prompt's own reading into a deterministic
# .git/zero.sh validate-ids: leg 1 scans the current base version. Each case gets its own
# throwaway repo (history is permanent evidence to the validator, so an earlier case's commits
# must never leak into a later "clean" assertion). Ids below always carry a digit unless the point
# of the case IS the no-digit/no-token failure — the default KAIZERO_TASK_ID_PATTERN requires
# one.
# This file is a format conversion of the pre-existing tests/R-001-validate-ids-current-file.md
# (ISSUE-058c) — every case already existed and already passed against kaizero.sh; no new
# behavior is being asserted here.

TR="$TESTROOT/R-001-validate-ids-current-file"; mkdir -p "$TR/bin"
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
cache_of(){ ls "$1/.git"/todo-ids-ok-* 2>/dev/null | head -1; }

# R1 — clean todo (current + history) passes, and caches
newrepo r1
"$ZERO" validate-ids > "$TR/r1.out" 2>&1
check "R1 exit" "$?" "0"
check "R1 output" "$(wc -c < "$TR/r1.out" | tr -d ' ')" "0"   # clean run prints nothing
CACHE=$(cache_of "$TR/r1")
check "R1 cache" "$([ -n "$CACHE" ] && [ -f "$CACHE" ] && echo yes || echo NO)" "yes"
check "R1 cache sha match" "$([ "$(cat "$CACHE")" = "$(git rev-list -1 main -- todo.md)" ] && echo yes || echo NO)" "yes"
# R1 PASS — exit 0, no output, cache written with `git rev-list -1 main -- todo.md`.

# R2 — duplicate id in the current file
newrepo r2
printf -- '- [ ] Z0 seed\n- [ ] D1 a\n- [ ] D1 b\n' > todo.md; git add -A; git commit -qm dup
"$ZERO" validate-ids > "$TR/r2.out" 2>&1; check "R2 exit" "$?" "1"
check "R2 lines" "$(grep -c '^duplicate-id D1:' "$TR/r2.out")" "2"   # one per offending line
check "R2 cache" "$([ -n "$(cache_of "$TR/r2")" ] && echo yes || echo NO)" "NO"   # a failing run writes no cache
# R2 PASS — exit 1, both D1 lines reported, no cache.

# R4 — a fenced example block is invisible to every class
newrepo r4
cat > todo.md <<'EOF'
Example (prose):
```markdown
- [ ] EX example
- [x] EX example
```
- [ ] R4 real task
EOF
git add -A; git commit -qm fenced
"$ZERO" validate-ids; check "R4 exit" "$?" "0"   # the fenced EX/EX 'duplicate' is prose, not a task
# R4 PASS — clean: the fence hides its example boxes from the duplicate-id scan.

# R12 — a landed [?] box is still scanned for a duplicate id. Verified in-session against the
# real zero.sh validate-ids before this conversion (exit=1, 2 duplicate-id W1: lines) — this is a
# format conversion of an existing, already-passing case, not a newly authored assertion.
newrepo r12
printf -- '- [?] W1 landed, needs review\n- [ ] W1 duplicate of a landed one\n' > todo.md
git add -A; git commit -qm "dup against a [?] line"
"$ZERO" validate-ids > "$TR/r12.out" 2>&1; check "R12 exit" "$?" "1"
check "R12 lines" "$(grep -c '^duplicate-id W1:' "$TR/r12.out")" "2"   # one per offending line, [?] included
# R12 PASS — exit 1, both W1 lines reported: a [?] checkbox line is a task to the id
# scanner even though it is landed, not still-to-do.

# R14 — duplicate-id folds case: A1 and a1 name the same claim identity. Verified in-session
# against the real zero.sh validate-ids before this conversion (exit=1, 2 duplicate-id lines).
newrepo r14
printf -- '- [ ] Z0 seed\n- [ ] A1 third\n- [ ] a1 fourth\n' > todo.md; git add -A; git commit -qm dup
"$ZERO" validate-ids > "$TR/r14.out" 2>&1; check "R14 exit" "$?" "1"
check "R14 lines" "$(grep -c '^duplicate-id ' "$TR/r14.out")" "2"   # one per offending line
# R14 PASS — exit 1, both lines reported: sanitize_id case-folded, A1 and a1 collapse
# onto one claim identity exactly as they would onto one branch name.

# R15 — duplicate-id folds / and -: I6/a and I6-a name the same claim identity. Verified
# in-session against the real zero.sh validate-ids before this conversion (exit=1, 2 lines).
newrepo r15
printf -- '- [ ] Z0 seed\n- [ ] I6/a first\n- [ ] I6-a second\n' > todo.md; git add -A; git commit -qm dup
"$ZERO" validate-ids > "$TR/r15.out" 2>&1; check "R15 exit" "$?" "1"
check "R15 lines" "$(grep -c '^duplicate-id ' "$TR/r15.out")" "2"
# R15 PASS — sanitize_id maps / to - the same as a literal -, so the two ids collide
# on one worktree/branch/lock and the validator says so.

# R PASS — R1, R2, R4, R12, R14 and R15 all report PASS.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
