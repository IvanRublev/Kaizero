#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# R-002-validate-ids-history — leg 2 — a collision in an old commit, a reused id, and the three
# rewrites that are not one.
# - Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# - Tools beyond the shared prerequisites: none
# - Folder under $TESTROOT: $TESTROOT/R-002-validate-ids-history
# - Wall-clock budget: seconds — no Run command of this scenario wraps itself in timeout
#
# The other leg of .git/zero.sh validate-ids: leg 2 walks every historical version
# of the todo, so a collision that exists only in an old commit, an id deleted and reused later,
# and an id repurposed in place all refuse — while a byte-identical revert, a reworded line
# sharing a word, and a bare box flip do not. Each case gets its own throwaway repo (history is
# permanent evidence to the validator, so an earlier case's commits must never leak into a later
# "clean" assertion). Format conversion of tests/R-002-validate-ids-history.md (ISSUE-058c) —
# every case already existed and already passed.

TR="$TESTROOT/R-002-validate-ids-history"; mkdir -p "$TR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/claude"; chmod +x "$TR/bin/claude"

# fresh repo under $TR/$1, one seed commit, real zero.sh emitted (no claude launch needed).
# Sets $ZERO for the caller and leaves cwd inside the new repo. The cache filename is a hash of
# (base, todo path, pattern) — not fixed — so a caller that needs it globs "$d/.git"/todo-ids-ok-*.
newrepo(){
  local d="$TR/$1"; mkdir -p "$d"; cd "$d"
  git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] Z0 seed\n' > todo.md; git add -A; git commit -qm init
  KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
  ZERO="$d/.git/zero.sh"
}

# R5 — history: a collision in one old commit only, current file clean
newrepo r5
printf -- '- [ ] H1 a\n- [ ] H1 b\n' > todo.md; git add -A; git commit -qm "history collision"
printf -- '- [ ] H1 only one now\n' > todo.md; git add -A; git commit -qm "fixed"
"$ZERO" validate-ids > "$TR/r5.out" 2>&1; check "R5 exit" "$?" "1"
check "R5 class" "$([ "$(grep -c '^duplicate-id-history H1:' "$TR/r5.out")" -ge 1 ] && echo yes || echo NO)" "yes"
KAIZERO_ID_HISTORY=0 "$ZERO" validate-ids; check "R5 history=0" "$?" "0"   # leg 2 skipped
# R5 PASS — history-only collision caught by default, invisible with KAIZERO_ID_HISTORY=0.

# R6 — reused-id-gap vs a byte-identical revert
newrepo r6
printf -- '- [ ] G1 was original text\n' > todo.md; git add -A; git commit -qm "g-add"
printf -- '- [ ] N1 noop\n' > todo.md; git add -A; git commit -qm "g-delete"
printf -- '- [ ] G1 was original text\n- [ ] N1 noop\n' > todo.md; git add -A; git commit -qm "g-restore-identical"
"$ZERO" validate-ids; check "R6a revert" "$?" "0"
printf -- '- [ ] N1 noop\n' > todo.md; git add -A; git commit -qm "g-delete-2"
printf -- '- [ ] G1 totally different text\n- [ ] N1 noop\n' > todo.md; git add -A; git commit -qm "g-reuse-different"
"$ZERO" validate-ids > "$TR/r6.out" 2>&1; check "R6b reuse exit" "$?" "1"
check "R6b class" "$(grep -c '^reused-id-gap G1:' "$TR/r6.out")" "1"
# R6 PASS — identical-text restore is silent; different-text reuse is reused-id-gap.

# R7 — reused-id-inplace vs a reworded line and a bare box flip
newrepo r7
printf -- '- [ ] N1 noop\n- [ ] P1 alpha beta gamma\n' > todo.md; git add -A; git commit -qm "p-add"
printf -- '- [ ] N1 noop\n- [x] P1 alpha beta gamma\n' > todo.md; git add -A; git commit -qm "p-flip-box"
"$ZERO" validate-ids; check "R7a box flip" "$?" "0"
printf -- '- [ ] N1 noop\n- [x] P1 alpha beta DELTA\n' > todo.md; git add -A; git commit -qm "p-reword"
"$ZERO" validate-ids; check "R7b reword shares a word" "$?" "0"
printf -- '- [ ] N1 noop\n- [x] P1 zzz qqq wwww\n' > todo.md; git add -A; git commit -qm "p-repurpose"
"$ZERO" validate-ids > "$TR/r7.out" 2>&1; check "R7c repurpose exit" "$?" "1"
check "R7c class" "$(grep -c '^reused-id-inplace P1:' "$TR/r7.out")" "1"
# R7 PASS — a box flip and a reworded line sharing one word are silent; a no-shared-word
# repurpose is reused-id-inplace.

# R19 — a shallow clone cannot answer for its history; unshallowing restores the walk. Verified
# in-session against the real zero.sh validate-ids before this conversion (shallow exit=1, class=1,
# history=0 exit=0, unshallowed=1) — a format conversion of an existing, already-passing case.
newrepo r19src
printf -- '- [ ] H1 a\n- [ ] H1 b\n' > todo.md; git add -A; git commit -qm "history collision"
printf -- '- [ ] H1 only one now\n' > todo.md; git add -A; git commit -qm fixed
SHALLOW="$TR/r19-shallow"
git clone -q --depth 1 --branch main "file://$TR/r19src" "$SHALLOW"
cd "$SHALLOW"
KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
ZS="$SHALLOW/.git/zero.sh"
"$ZS" validate-ids > "$TR/r19.out" 2>&1; check "R19 shallow exit" "$?" "1"
check "R19 class" "$(grep -c '^history-incomplete (none):' "$TR/r19.out")" "1"
KAIZERO_ID_HISTORY=0 "$ZS" validate-ids; check "R19 history=0" "$?" "0"   # leg 2 skipped entirely
git -C "$SHALLOW" fetch -q --unshallow
"$ZS" validate-ids > "$TR/r19b.out" 2>&1
check "R19 unshallowed" "$(grep -c '^duplicate-id-history H1:' "$TR/r19b.out")" "1"   # the real finding, not history-incomplete
# R19 PASS — a shallow clone refuses with history-incomplete rather than a false-clean
# answer; KAIZERO_ID_HISTORY=0 accepts leg 1 alone; unshallowing surfaces the real finding.

# R20 — a duplicate still live today is reported once, never also as duplicate-id-history.
# Verified in-session before conversion (exit=1, no-dup-history=0, dup-id=2).
newrepo r20
printf -- '- [ ] Z0 seed\n- [ ] D9 x\n- [ ] D9 y\n' > todo.md; git add -A; git commit -qm dup
"$ZERO" validate-ids > "$TR/r20.out" 2>&1; check "R20 exit" "$?" "1"
check "R20 no dup-history" "$(grep -c '^duplicate-id-history D9:' "$TR/r20.out")" "0"
check "R20 dup-id lines" "$(grep -c '^duplicate-id D9:' "$TR/r20.out")" "2"   # leg 1's finding, not leg 2's
# R20 PASS — the newest version walked is the current file; its own collision is leg 1's
# duplicate-id to report, not leg 2's duplicate-id-history.

# R21 — a historical collision survives a git mv of the todo file. Verified in-session before
# conversion (exit=1, class>=1).
newrepo r21
printf -- '- [ ] M1 a\n- [ ] M1 b\n' > todo.md; git add -A; git commit -qm "collision before rename"
git mv todo.md renamed.md; git commit -qm "renamed"
printf -- '- [ ] M1 only one now\n' > renamed.md; git add -A; git commit -qm fixed
KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge renamed.md -t x > /dev/null 2>&1
ZR="$TR/r21/.git/zero.sh"
"$ZR" validate-ids > "$TR/r21.out" 2>&1; check "R21 exit" "$?" "1"
check "R21 class" "$([ "$(grep -c '^duplicate-id-history M1:' "$TR/r21.out")" -ge 1 ] && echo yes || echo NO)" "yes"   # --follow crosses the rename
# R21 PASS — git log --follow reaches the pre-rename commit, so a collision that predates
# the git mv is still caught under the file's new path.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
