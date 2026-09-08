#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# R-007-validate-tasks-heading-grammar — `zero.sh validate-tasks`: the Acceptance Criteria
# heading grammar it recognizes and excludes, the block boundary between two heading styles, and
# the two shapes of an empty section.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/R-007-validate-tasks-heading-grammar
# Wall-clock budget: seconds — no Run command of this scenario wraps itself in timeout
#
# `zero.sh validate-tasks` is a new sibling of `validate-ids` (ISSUE 051): for every unchecked id
# on the Release Todo List's own tail, it resolves the Task file by id and checks it for a
# checkboxed Acceptance Criteria section. Each case gets its own throwaway repo, single-repo mode
# ($COORD_ROOT = $TARGET_ROOT) unless a case says otherwise.

# Setup
TR="$TESTROOT/R-007-validate-tasks-heading-grammar"; mkdir -p "$TR/bin"
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

# R4-5 — heading grammar: ATX/Setext/bold, each with a trailing `:`, and the excluded forms
newrepo r5
mkdir -p tasks
{
  printf -- '- [x] Z0 seed\n'
  for id in AT1 AT2 SE1 SE2 BD1 BD2 IT1 HT1; do printf -- '- [ ] %s x\n' "$id"; done
} > todo.md; git add -A; git commit -qm t5
printf -- '### Acceptance criteria\n- [ ] a\n'      > tasks/AT1.md
printf -- '# Acceptance Criteria:\n- [ ] a\n'       > tasks/AT2.md
printf -- 'Acceptance criteria\n---\n- [ ] a\n'     > tasks/SE1.md
printf -- 'Acceptance Criteria:\n===\n- [ ] a\n'    > tasks/SE2.md
printf -- '**Acceptance criteria**\n- [ ] a\n'      > tasks/BD1.md
printf -- '__Acceptance Criteria:__\n- [ ] a\n'     > tasks/BD2.md
printf -- '*Acceptance criteria*\n- [ ] a\n'        > tasks/IT1.md
printf -- '<h3>Acceptance Criteria</h3>\n- [ ] a\n' > tasks/HT1.md
"$ZERO" validate-tasks > "$TR/r5.out" 2>&1
# only IT1/HT1 fail
check "R4-5 exit" "$?" "1"
for id in AT1 AT2 SE1 SE2 BD1 BD2; do
  check "R4-5 $id recognized" "$([ "$(grep -c "$id" "$TR/r5.out")" = 0 ] && echo yes || echo NO)" "yes"
done
for id in IT1 HT1; do
  check "R4-5 $id excluded" "$(grep -c "^empty-acceptance-criteria $id:" "$TR/r5.out")" "1"
done
# R4-5 PASS — every supported form (with or without a trailing `:`) is recognized; italic-only
# and raw HTML are not.

# R4-6 — a checkbox block bounded by two different heading styles; a fenced example is ignored
newrepo r6
mkdir -p tasks
printf -- '- [x] Z0 seed\n- [ ] MX1 mixed\n- [ ] FN1 fenced\n' > todo.md; git add -A; git commit -qm t6
printf -- '## Acceptance criteria\n- [ ] a\n- [ ] b\nNext text\n---\nafter\n' > tasks/MX1.md
cat > tasks/FN1.md <<'EOF'
Example:
```markdown
### Acceptance criteria
- [ ] fake
```
### Acceptance criteria
- [ ] real
EOF
"$ZERO" validate-tasks > "$TR/r6.out" 2>&1
check "R4-6 exit" "$?" "0"
check "R4-6 output" "$(wc -c < "$TR/r6.out" | tr -d ' ')" "0"
# R4-6 PASS — a Setext-underlined next section ends an ## -started block; a fenced example
# heading is never the real one.

# R4-7 — empty-acceptance-criteria: no heading at all, and a heading with zero checkboxes
newrepo r7
mkdir -p tasks
printf -- '- [x] Z0 seed\n- [ ] EM1 none\n- [ ] EM2 empty\n' > todo.md; git add -A; git commit -qm t7
printf -- 'just prose, no heading\n' > tasks/EM1.md
printf -- '### Acceptance criteria\nno boxes here\n' > tasks/EM2.md
"$ZERO" validate-tasks > "$TR/r7.out" 2>&1
check "R4-7 exit" "$?" "1"
check "R4-7 EM1" "$(grep -c '^empty-acceptance-criteria EM1: tasks/EM1.md' "$TR/r7.out")" "1"
check "R4-7 EM2" "$(grep -c '^empty-acceptance-criteria EM2: tasks/EM2.md' "$TR/r7.out")" "1"
# R4-7 PASS — both classes of empty section reported, path named.

# R4-8 — a bold body note between the AC heading and its checkboxes must not be mistaken for the
# next heading and close the section early
newrepo r8
mkdir -p tasks
printf -- '- [x] Z0 seed\n- [ ] BN1 boldnote\n' > todo.md; git add -A; git commit -qm t8
printf -- '### Acceptance criteria\n\n**Rule: every removal gets an absence check.**\n\n- [x] a\n' > tasks/BN1.md
"$ZERO" validate-tasks > "$TR/r8.out" 2>&1
check "R4-8 exit" "$?" "0"
check "R4-8 output" "$(wc -c < "$TR/r8.out" | tr -d ' ')" "0"
# R4-8 PASS — bold body text inside the section is not a heading, checkbox still counts.

# R PASS — R4-5, R4-6, R4-7 and R4-8 all report PASS.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
