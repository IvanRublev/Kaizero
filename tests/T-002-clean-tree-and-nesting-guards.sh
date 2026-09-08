#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=85s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-002-clean-tree-and-nesting-guards — a dirty tree on either root, and nesting in both
# directions.
# Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor tests
# `command -v claude` before any startup guard runs)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T-002-clean-tree-and-nesting-guards
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# The same two fixture repositories, code (the launch/target repo) and plan (holds the todo),
# under KAIZERO_TEST_EMIT=1: a pure launch-time decision either way. Here the two roots are
# checked against each other — a dirty working tree on either one, and one repository nested
# inside the other in both directions, with and without the .gitignore line.

# Setup
TT="$TESTROOT/T-002-clean-tree-and-nesting-guards"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktodo(){ ( cd "$1"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }
# --local-merge: none of these fixture repos carry an origin, so a two-repo case
# (SAME_REPO=0) would otherwise hit the new default-to-mr detection's "no origin" refusal before
# ever reaching the role-detection guards this scenario exists to test; the flag opts every case
# back into today's local-merge path, same-repo cases included (a harmless no-op there).
emit(){ ( cd "$1"; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1 ); }   # $1=launch dir $2=todo arg
refuse(){ ( cd "$1"; rc=0; out=$(KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }

# T6 — a dirty target tree refuses, naming its own root
mkrepo "$TT/code6"; mkrepo "$TT/plan6"; mktodo "$TT/plan6"
( cd "$TT/code6"; echo change >> f )
out=$(refuse "$TT/code6" "$TT/plan6/todo.md")
check "T6 target dirty" "$(echo "$out" | grep -c "Working tree on 'main' is dirty")" "1"
check "T6 rc" "$(echo "$out" | grep RC=)" "RC=1"
# T6 PASS — the target clean-tree guard fires, names its own root and exits 1.

# T7 — a dirty coordination tree refuses, naming its own root
mkrepo "$TT/code7"; mkrepo "$TT/plan7"; mktodo "$TT/plan7"
( cd "$TT/plan7"; echo change >> f )
out=$(refuse "$TT/code7" "$TT/plan7/todo.md")
check "T7 coord dirty" "$(echo "$out" | grep -c "Working tree on '$TT/plan7@main' is dirty")" "1"
check "T7 rc" "$(echo "$out" | grep RC=)" "RC=1"
# T7 PASS — the coordination clean-tree guard fires, names its own root and exits 1.

# T8 — nesting, coordination inside target: refuses unignored
mkrepo "$TT/code8"; mkdir -p "$TT/code8/plan"
( cd "$TT/code8/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo )
out=$(refuse "$TT/code8" "$TT/code8/plan/todo.md")
check "T8 refuses unignored" "$(echo "$out" | grep -c "neither ignored nor a submodule")" "1"
check "T8 names the fix" "$(echo "$out" | grep -c "add 'plan/' to $TT/code8/.gitignore")" "1"
check "T8 rc" "$(echo "$out" | grep RC=)" "RC=1"
# T8 PASS — nesting without an ignore/submodule is refused, naming the fix, and exits 1.

# T9 — nesting, coordination inside target: proceeds ignored
( cd "$TT/code8"; echo 'plan/' >> .gitignore; git add .gitignore; git commit -qm ignore-plan )
out=$(emit "$TT/code8" "$TT/code8/plan/todo.md")
check "T9 proceeds ignored" "$(echo "$out" | grep -c 'Todo .*plan@main . Target .*code8@main')" "1"
# T9 PASS — the same nesting with plan/ gitignored proceeds.

# T10 — nesting, target inside coordination: refuses unignored
mkrepo "$TT/plan10"; mkdir -p "$TT/plan10/code"
( cd "$TT/plan10/code"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init )
( cd "$TT/plan10"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo )
out=$(refuse "$TT/plan10/code" "$TT/plan10/todo.md")
check "T10 refuses unignored" "$(echo "$out" | grep -c "neither ignored nor a submodule")" "1"
check "T10 rc" "$(echo "$out" | grep RC=)" "RC=1"
# T10 PASS — nesting the other direction without an ignore/submodule is refused and exits 1.

# T11 — nesting, target inside coordination: proceeds ignored, WT_PARENT beside the outer
( cd "$TT/plan10"; echo 'code/' >> .gitignore; git add .gitignore; git commit -qm ignore-code )
out=$(emit "$TT/plan10/code" "$TT/plan10/todo.md")
check "T11 proceeds ignored" "$(echo "$out" | grep -c 'Todo .*plan10@main . Target .*plan10/code@main')" "1"
check "T11 WT_PARENT is the outer's dirname (nested)" "$(awk -F= '/^WT_PARENT=/{print $2}' "$TT/plan10/.git/zero.sh")" "$(dirname "$TT/plan10")"
# T11 PASS — the same nesting with code/ gitignored proceeds, and WT_PARENT lands beside
# the outer repository when nested rather than beside the target.

# T12 — BUG-058h: a dead peer's own dirty coordination tree (a session marker naming a Task
# still current, whose pid is no longer alive) is discarded automatically and the launch proceeds
mkrepo "$TT/code12"; mkrepo "$TT/plan12"; mktodo "$TT/plan12"
( cd "$TT/plan12"; echo change >> f )
( sleep 100 ) & DEADPID12=$!
DEADST12=$(ps -o lstart= -p "$DEADPID12" 2>/dev/null | awk '{$1=$1;print}')
kill "$DEADPID12" 2>/dev/null; wait "$DEADPID12" 2>/dev/null
GC12="$(git -C "$TT/plan12" rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$GC12/session"
printf '%s\n%s\n' "$DEADST12" "SOMEID" > "$GC12/session/$DEADPID12"
out=$(emit "$TT/code12" "$TT/plan12/todo.md")
check "T12 proceeds despite dead peer's dirt" "$(echo "$out" | grep -c 'Todo .*plan12@main . Target .*code12@main')" "1"
check "T12 discarded the dirty file" "$(git -C "$TT/plan12" status --porcelain | wc -l | tr -d ' ')" "0"
# T12 PASS — a dead session's own leftover dirt is discarded per path, launch proceeds.

# T13 — a live peer's own dirty coordination tree still hard-refuses, naming it as live and
# mid-commit rather than "commit or stash first"
mkrepo "$TT/code13"; mkrepo "$TT/plan13"; mktodo "$TT/plan13"
( cd "$TT/plan13"; echo change >> f )
( sleep 100 ) & LIVEPID13=$!
LIVEST13=$(ps -o lstart= -p "$LIVEPID13" 2>/dev/null | awk '{$1=$1;print}')
GC13="$(git -C "$TT/plan13" rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$GC13/session"
printf '%s\n%s\n' "$LIVEST13" "SOMEID" > "$GC13/session/$LIVEPID13"
out=$(refuse "$TT/code13" "$TT/plan13/todo.md")
check "T13 live peer refuses, names it" "$(echo "$out" | grep -c "session $LIVEPID13 is still live and mid-commit")" "1"
check "T13 never says commit or stash" "$(echo "$out" | grep -c 'commit or stash first')" "0"
check "T13 rc" "$(echo "$out" | grep RC=)" "RC=1"
kill "$LIVEPID13" 2>/dev/null; wait "$LIVEPID13" 2>/dev/null
# T13 PASS — a live peer's own in-progress edit hard-refuses with the live/mid-commit wording.

# T14 — a marker whose session already released cleanly (current=none) names no resolvable
# owner — today's "commit or stash first" refusal stands, never auto-discarded on a guess
mkrepo "$TT/code14"; mkrepo "$TT/plan14"; mktodo "$TT/plan14"
( cd "$TT/plan14"; echo change >> f )
( sleep 100 ) & LIVEPID14=$!
LIVEST14=$(ps -o lstart= -p "$LIVEPID14" 2>/dev/null | awk '{$1=$1;print}')
GC14="$(git -C "$TT/plan14" rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$GC14/session"
printf '%s\n%s\n' "$LIVEST14" "none" > "$GC14/session/$LIVEPID14"
out=$(refuse "$TT/code14" "$TT/plan14/todo.md")
check "T14 no resolvable owner keeps old refusal" "$(echo "$out" | grep -c "Working tree on '$TT/plan14@main' is dirty")" "1"
check "T14 rc" "$(echo "$out" | grep RC=)" "RC=1"
kill "$LIVEPID14" 2>/dev/null; wait "$LIVEPID14" 2>/dev/null
# T14 PASS — a released session's stale marker names no resolvable owner; refusal is unchanged.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
