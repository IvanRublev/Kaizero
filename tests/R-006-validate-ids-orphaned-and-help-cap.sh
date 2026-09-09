#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# R-006-validate-ids-orphaned-and-help-cap — leg 1 — the orphaned-id class a live todo can
# fail, and what -h/--help does and does not document about it.
# - Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# - Tools beyond the shared prerequisites: none
# - Folder under $TESTROOT: $TESTROOT/R-006-validate-ids-orphaned-and-help-cap
# - Wall-clock budget: seconds — no Run command of this scenario wraps itself in timeout
#
# Task id validation moved out of the prompt's own reading into a deterministic
# .git/zero.sh validate-ids: leg 1 scans the current base version. Each case gets its own
# throwaway repo (history is permanent evidence to the validator, so an earlier case's commits
# must never leak into a later "clean" assertion). Ids below always carry a digit unless the point
# of the case IS the no-digit/no-token failure — the default KAIZERO_TASK_ID_PATTERN requires
# one. Format conversion of tests/R-006-validate-ids-orphaned-and-help-cap.md (ISSUE-058c) —
# every case already existed and already passed.

TR="$TESTROOT/R-006-validate-ids-orphaned-and-help-cap"; mkdir -p "$TR/bin"
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

# R16 — orphaned-id: a live holder whose id no task line carries, and the cache-hit path
newrepo r16
WT="$TR/r16-wt"
git worktree add -q -b main-task-ORPH "$WT" main
( sleep 20 ) > "$TR/r16-livepid.out" 2>&1 & LIVEPID=$!
STARTVAL=$(ps -o lstart= -p "$LIVEPID" | tr -s ' ')
printf '%s\n%s\n' "$LIVEPID" "$STARTVAL" > "$WT/.owner"
GITCOMMON="$(git -C "$TR/r16" rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$GITCOMMON/session"
printf '%s\n%s\n' "$STARTVAL" "ORPH" > "$GITCOMMON/session/$LIVEPID"
"$ZERO" validate-ids > "$TR/r16.out" 2>&1; check "R16 live exit" "$?" "1"
check "R16 finding" "$(grep -c '^orphaned-id ORPH:' "$TR/r16.out")" "1"
# same holder, but the file-reading legs are already cached clean at this SHA — orphaned-id
# is live state, no commit SHA pins it, so a cache hit must not silence it.
"$ZERO" validate-ids > "$TR/r16b.out" 2>&1; check "R16 warm-cache exit" "$?" "1"   # cache hit answers the two file-reading legs only
check "R16 warm-cache finding" "$(grep -c '^orphaned-id ORPH:' "$TR/r16b.out")" "1"
kill "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null
rm -f "$WT/.owner" "$GITCOMMON/session/$LIVEPID"
"$ZERO" validate-ids; check "R16 holder gone" "$?" "0"   # orphaned-id never fires with no live holder
# R16 PASS — a live holder whose id no task line carries refuses every time, cache hit or
# not; the same base version with the holder gone is clean.

# R18 — absence check: -h/--help does not document KAIZERO_ID_HISTORY
check "R18" "$(bash "$SCRIPT" -h | grep -c KAIZERO_ID_HISTORY)" "0"
# R18 PASS — usage()'s inlined environment block stays capped at its four core entries;
# this validate-ids-only variable is not one of them.

# R PASS — R16 and R18 both report PASS.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
