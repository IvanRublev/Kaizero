#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=85s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-017-coordination-side-banner-and-refusals — the banner each layout prints, the
# coordination-side refusals, and the main-worktree discriminator's renames.
# Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor tests
#   `command -v claude` before any startup guard runs)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T-017-coordination-side-banner-and-refusals
#
# Two fixture repositories: code (the launch/target repo, where the run is invoked from) and plan
# (holds the todo). KAIZERO_TEST_EMIT=1 prints the banner and writes .git/zero.sh (into the
# coordination repo's git dir), then exits before any claude would start — every case here is a
# pure launch-time decision: which repository takes which role, and the coordination-side
# refusals that stop a launch outright.

TT="$TESTROOT/T-017-coordination-side-banner-and-refusals"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktodo(){ ( cd "$1"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }
# --local-merge: none of these fixture repos carry an origin, so a two-repo case (SAME_REPO=0)
# would otherwise hit the new default-to-mr detection's "no origin" refusal before ever reaching
# the role-detection guards this scenario exists to test; the flag opts every case back into
# today's local-merge path, same-repo cases included (a harmless no-op there).
emit(){ ( cd "$1"; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1 ); }   # $1=launch dir $2=todo arg
refuse(){ ( cd "$1"; rc=0; out=$(KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }

# T1 — same repo: today's banner, unchanged (SAME_REPO=1)
mkrepo "$TT/same"; mktodo "$TT/same"
out=$(emit "$TT/same" todo.md)
check "T1 banner" "$(echo "$out" | grep -c 'Base main \. Fork')" "1"
check "T1 no todo/target line" "$(echo "$out" | grep -c 'Todo .*\. Target ')" "0"

# T2 — disjoint repos: two-root banner, zero.sh lands in the coordination repo (SAME_REPO=0)
mkrepo "$TT/code"; mkrepo "$TT/plan"; mktodo "$TT/plan"
out=$(emit "$TT/code" "$TT/plan/todo.md")
check "T2 banner" "$(echo "$out" | grep -c "Todo $TT/plan@main . Target $TT/code@main")" "1"
check "T2 zero.sh" "$([ -f "$TT/plan/.git/zero.sh" ] && echo yes || echo no)" "yes"
# want yes — never in target
check "T2 no leak" "$([ -f "$TT/code/.git/zero.sh" ] && echo NO || echo yes)" "yes"
check "T2 COORD_BASE" "$(grep -c '^COORD_BASE=main' "$TT/plan/.git/zero.sh")" "1"
check "T2 TARGET_BASE" "$(grep -c '^TARGET_BASE=main' "$TT/plan/.git/zero.sh")" "1"
check "T2 TODO_PATH" "$(grep -c '^TODO_PATH=todo.md' "$TT/plan/.git/zero.sh")" "1"
check "T2 WT_PARENT absolute" "$(awk -F= '/^WT_PARENT=/{print ($2 ~ /^\//) ? "yes" : "no"}' "$TT/plan/.git/zero.sh")" "yes"

# T3 — todo outside any git repository
mkrepo "$TT/code3"; mkdir -p "$TT/nogit3"; echo '- [ ] G1 noop' > "$TT/nogit3/todo.md"
out=$(refuse "$TT/code3" "$TT/nogit3/todo.md")
check "T3" "$(echo "$out" | grep -c 'is not inside a git repository')" "1"
check "T3 rc" "$(echo "$out" | grep RC=)" "RC=1"

# T4 — todo inside a linked (not main) worktree of the coordination repo
mkrepo "$TT/code4"; mkrepo "$TT/plan4"; mktodo "$TT/plan4"
( cd "$TT/plan4"; git worktree add -q -b wt4 "$TT/plan4-linked" main )
out=$(refuse "$TT/code4" "$TT/plan4-linked/todo.md")
check "T4" "$(echo "$out" | grep -c 'use the main checkout')" "1"

# T5 — detached HEAD in the coordination repository
mkrepo "$TT/code5"; mkrepo "$TT/plan5"; mktodo "$TT/plan5"
( cd "$TT/plan5"; git checkout -q --detach )
out=$(refuse "$TT/code5" "$TT/plan5/todo.md")
check "T5" "$(echo "$out" | grep -c 'Detached HEAD in the coordination repository')" "1"
# T1 PASS — SAME_REPO=1 changes nothing observable.
# T2 PASS — the two-repo banner, that zero.sh is written only into the coordination repo, and that
# COORD_BASE/TARGET_BASE/TODO_PATH/WT_PARENT are baked correctly.
# T3 PASS — a todo outside any git repository is refused.
# T4 PASS — a todo inside a linked (not main) worktree of the coordination repo is refused.
# T5 PASS — a detached HEAD in the coordination repository is refused.

# T12 — absence checks (the renames and constraints)
check "T12 BASE_BRANCH gone" "$(grep -c 'BASE_BRANCH' "$REAL_SCRIPT")" "0"
check "T12 bare GITDIR gone" "$(grep -cw 'GITDIR' "$REAL_SCRIPT")" "0"
check "T12 abbrev-ref count" "$(grep -c 'rev-parse --abbrev-ref HEAD' "$REAL_SCRIPT")" "1"
check "T12 no ../ts-" "$(grep -c '\.\./ts-' "$REAL_SCRIPT" "$REPO/README.md" | awk -F: '{s+=$2} END{print s}')" "0"
check "T12 no KAIZERO_TARGET" "$(grep -c 'KAIZERO_TARGET' "$REAL_SCRIPT" "$REPO/README.md" | awk -F: '{s+=$2} END{print s}')" "0"
# T12 PASS — every count is 0, and the --abbrev-ref HEAD count is exactly 1. The static "no
# network words in the source" check this scenario used to carry here is gone — the source now
# carries legitimate fetch/gh/origin/push words, gated behind MR mode. Its job is now
# U-001-mr-mode-launch-refusals's own absence check (U15): stubs that fail the run if called prove
# git fetch, gh and glab are never invoked under --local-merge. show-toplevel check dropped —
# BUG-014 removed the pattern from kaizero.sh entirely, so the count was vacuously 0 no matter
# what the code did.

# T21 — `-h`'s layout/branch paragraph, and the two-repository default-mode banner
cd "$TT"
HELP="$(bash "$SCRIPT" -h)"
check "T21 -h names the layout" "$(printf '%s' "$HELP" | grep -ci 'stand in the code repository')" "1"
check "T21 -h states reopen = uncheck" "$(printf '%s' "$HELP" | grep -ci 'reopen a Landed Task by unchecking its box')" "1"
check "T21 -h states id prefix rule" "$(printf '%s' "$HELP" | grep -ci 'prefix-extends an adopted branch')" "1"
check "T21 -h offers no same-repo MR" "$(printf '%s' "$HELP" | grep -ci 'pull request (gh)\|merge request (glab)')" "0"

mkrepo "$TT/code21"; mkrepo "$TT/plan21"; mktodo "$TT/plan21"
( cd "$TT/code21"; git remote add origin https://github.com/acme/code21.git )
out=$( ( cd "$TT/code21"; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" "$TT/plan21/todo.md" 2>&1 ) )
check "T21 default banner, no mode word" "$(echo "$out" | grep -c "Todo $TT/plan21@main \. Target $TT/code21@main \. Fork -> implement -> commit -> pull request (gh)")" "1"
# T21 PASS — -h states, next to todo-file-path, the layout paragraph, the <id>-… prefix rule, and
# the reopen-by-unchecking path, and offers no request-landing wording for a same-repository
# launch (the layout it refuses); a two-repository launch with a github origin and no flag prints
# one banner line, "todo <coord>@<base> · target <target>@<base> · fork → implement → commit →
# pull request (gh)", with no mode word before todo.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
