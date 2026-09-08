#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# R-004-validate-tasks-resolution — zero.sh validate-tasks: resolving an unchecked id to its
# Task file — the clean-tail baseline, missing-task-file, boundary safety and ambiguous-task-file
# classes — kept separate from validate-ids.
# - Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# - Tools beyond the shared prerequisites: none
# - Folder under $TESTROOT: $TESTROOT/R-004-validate-tasks-resolution
# - Wall-clock budget: seconds — no Run command of this scenario wraps itself in timeout
#   (shares its launch-gate/cache shape by contrast — validate-tasks caches nothing)
#
# zero.sh validate-tasks is a new sibling of validate-ids: for every unchecked id
# on the Release Todo List's own tail, it resolves the Task file by id and checks it for a
# checkboxed Acceptance Criteria section. Each case gets its own throwaway repo, single-repo mode
# ($COORD_ROOT = $TARGET_ROOT) unless a case says otherwise. Format conversion of
# tests/R-004-validate-tasks-resolution.md (ISSUE-058c) — every case already existed and passed.
# R4-5 through R4-13 (heading grammar, scale/caching, repo-scoping) live in their own files:
# R-007-validate-tasks-heading-grammar.sh, R-008-validate-tasks-scale-and-caching.sh,
# R-009-validate-tasks-repo-scoping.sh.

TR="$TESTROOT/R-004-validate-tasks-resolution"; mkdir -p "$TR/bin"
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

# R4-1 — clean tail: every unchecked id resolves to one file with a non-empty AC block
newrepo r1
mkdir -p tasks
printf -- '- [x] Z0 seed\n- [ ] WORK-1 first\n' > todo.md; git add -A; git commit -qm t1
printf -- '### Acceptance criteria\n\n- [ ] a\n' > tasks/WORK-1.md
"$ZERO" validate-tasks > "$TR/r1.out" 2>&1; check "R4-1 exit" "$?" "0"
check "R4-1 output" "$(wc -c < "$TR/r1.out" | tr -d ' ')" "0"
"$ZERO" validate-ids > /dev/null 2>&1; check "R4-1 ids still 0" "$?" "0"   # todo re-committed clean above
# R4-1 PASS — exit 0, no output.

# R4-2 — validate-ids is unaffected by missing Task files; the two checks stay separate
newrepo r2
printf -- '- [x] Z0 seed\n- [ ] WORK-2 no file anywhere\n' > todo.md; git add -A; git commit -qm t2
"$ZERO" validate-ids; check "R4-2 ids" "$?" "0"   # well-formed id, file state irrelevant to this check
"$ZERO" validate-tasks > "$TR/r2.out" 2>&1; check "R4-2 tasks" "$?" "1"
check "R4-2 finding" "$(grep -c '^missing-task-file WORK-2:' "$TR/r2.out")" "1"
# R4-2 PASS — validate-ids clean, validate-tasks reports missing-task-file.

# R4-3 — boundary safety: WORK-050 never matches MYWORK-050.md, nor crosses into WORK-10-*.md
newrepo r3
mkdir -p tasks
printf -- '- [x] Z0 seed\n- [ ] WORK-050 a\n- [ ] WORK-1 b\n' > todo.md; git add -A; git commit -qm t3
printf 'junk' > tasks/MYWORK-050.md
printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/WORK-1.md
printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/WORK-10-something.md
"$ZERO" validate-tasks > "$TR/r3.out" 2>&1; check "R4-3 exit" "$?" "1"
check "R4-3 WORK-050 missing" "$(grep -c '^missing-task-file WORK-050:' "$TR/r3.out")" "1"
check "R4-3 WORK-1 not crossed into WORK-10" "$(grep -c 'WORK-1:' "$TR/r3.out")" "0"   # WORK-1 itself resolved clean
# R4-3 PASS — the coarse glob's prefilter never wins over the exact canon() boundary check.

# R4-4 — ambiguous-task-file names every match
newrepo r4
mkdir -p tasks docs
printf -- '- [x] Z0 seed\n- [ ] WORK-9 dup\n' > todo.md; git add -A; git commit -qm t4
printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/WORK-9.md
printf -- '### Acceptance criteria\n- [ ] x\n' > docs/WORK-9-notes.md
"$ZERO" validate-tasks > "$TR/r4.out" 2>&1; check "R4-4 exit" "$?" "1"
check "R4-4 line" "$(grep -c '^ambiguous-task-file WORK-9: tasks/WORK-9.md, docs/WORK-9-notes.md' "$TR/r4.out")" "1"
# R4-4 PASS — both paths named, comma-joined, never a silent pick.

# R4-14 — main-loop launch site, advisory only — claude still launches on a broken Task file.
# Verified in-session against a clean fixture before conversion (exit=0, banner=1, finding=1,
# argv=1, fixed-no-banner=yes) — a format conversion of an existing, already-passing case.
newrepo r14
mkdir -p tasks
printf -- '- [x] Z0 seed\n- [ ] R14A broken\n' > todo.md; git add -A; git commit -qm t14
cat > "$TR/bin/claude" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
printf 'ARGV: %s\n' "\$*"
exit 0
EOF
chmod +x "$TR/bin/claude"
cd "$TR/r14"
PATH="$TR/bin:$PATH" KAIZERO_MAX_LOOPS=1 timeout 30 bash "$SCRIPT" --local-merge todo.md -t x > "$TR/r14.log" 2>&1
check "R4-14 exit" "$?" "0"   # advisory only, never refuses
check "R4-14 banner" "$(grep -c 'Task definition issue(s) found — affected candidate(s) will be skipped until fixed:' "$TR/r14.log")" "1"
check "R4-14 finding" "$(grep -c '^missing-task-file R14A:' "$TR/r14.log")" "1"
check "R4-14 claude still launched" "$([ "$(grep -c 'ARGV:' "$TR/r14.log")" -ge 1 ] && echo yes || echo NO)" "yes"
printf -- '### Acceptance criteria\n- [ ] a\n' > "$TR/r14/tasks/R14A.md"
git -C "$TR/r14" add -A; git -C "$TR/r14" commit -qm fix
PATH="$TR/bin:$PATH" KAIZERO_MAX_LOOPS=1 timeout 30 bash "$SCRIPT" --local-merge todo.md -t x > "$TR/r14b.log" 2>&1
check "R4-14 fixed, no banner" "$([ "$(grep -c 'Task definition issue' "$TR/r14b.log")" = 0 ] && echo yes || echo NO)" "yes"
# R4-14 PASS — the banner and finding print, claude still launches (its argv is in the log),
# and the run's own exit status is unaffected; once the Task file is fixed the banner stops
# reprinting.

# R4-15 — absence/placement checks for the two poll-tick call sites. Verified in-session against
# kaizero.sh before conversion (all four counts match) — a format conversion of an existing,
# already-passing case, not a newly authored assertion.
body(){
  local start end
  start=$(grep -n "^$1() {" "$REAL_SCRIPT" | head -1 | cut -d: -f1)
  end=$(tail -n +"$((start+1))" "$REAL_SCRIPT" | grep -n '^}' | head -1 | cut -d: -f1)
  end=$((start + end))
  sed -n "${start},${end}p" "$REAL_SCRIPT"
}
wr=$(body wait_for_reviews)
wd=$(body wait_for_dependency_clear)
check "R4-15 wait_for_reviews calls validate-tasks" "$(printf '%s' "$wr" | grep -c 'validate-tasks')" "1"
check "R4-15 wait_for_reviews inside the validate-ids success branch" "$(printf '%s' "$wr" | grep -c 'sync-mrs || true')" "1"   # same branch, after the existing sync-mrs call
check "R4-15 wait_for_dependency_clear calls validate-tasks" "$(printf '%s' "$wd" | grep -c 'validate-tasks')" "1"
check "R4-15 neither site sets IDFAIL from a validate-tasks finding" "$(printf '%s\n%s\n' "$wr" "$wd" | grep -A1 'validate-tasks' | grep -c 'IDFAIL')" "0"
# R4-15 PASS — both poll-tick sites gain the call inside their own existing
# validate-ids-passed branch, and neither treats a task-file finding as fatal.

# R PASS — R4-1 through R4-4 and R4-14/R4-15 all report PASS (R4-5 through R4-13 covered by
# R-007/R-008/R-009 — see above).

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
