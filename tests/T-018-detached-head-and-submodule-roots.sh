#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-018-detached-head-and-submodule-roots — a detached HEAD in the target repository, and a
# `git submodule add` submodule as either the target or the coordination root.
# Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor tests
#   `command -v claude` before any startup guard runs)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T-018-detached-head-and-submodule-roots
#
# Two fixture repositories: code (the launch/target repo, where the run is invoked from) and plan
# (holds the todo). KAIZERO_TEST_EMIT=1 prints the banner and writes .git/zero.sh (into the
# coordination repo's git dir), then exits before any claude would start — every case here is a
# pure launch-time decision over unusual root layouts: a detached target HEAD, and a submodule
# taking either role.

TT="$TESTROOT/T-018-detached-head-and-submodule-roots"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktodo(){ ( cd "$1"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }
# --local-merge: none of these fixture repos carry an origin, so a two-repo case (SAME_REPO=0)
# would otherwise hit the new default-to-mr detection's "no origin" refusal before ever reaching
# the role-detection guards this scenario exists to test; the flag opts every case back into
# today's local-merge path, same-repo cases included (a harmless no-op there).
emit(){ ( cd "$1"; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1 ); }   # $1=launch dir $2=todo arg
refuse(){ ( cd "$1"; rc=0; out=$(KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }

# T13 — detached HEAD in the target repository
mkrepo "$TT/code13"; mktodo "$TT/code13"
( cd "$TT/code13"; git checkout -q --detach )
out=$(refuse "$TT/code13" todo.md)
check "T13" "$(echo "$out" | grep -c "Detached HEAD in the target repository '$TT/code13'")" "1"
# T13 PASS — the target-side detached-HEAD message names the target root.

# T14 — a `git submodule add` submodule as target
mkrepo "$TT/subouter"; mkrepo "$TT/subinner"
( cd "$TT/subouter"; git -c protocol.file.allow=always submodule add -q "$TT/subinner" sub )
# the submodule as target — its absorbed gitdir is under subouter/.git/modules/sub, its working
# tree is subouter/sub; a launch from subouter/sub must resolve THAT as TARGET_ROOT.
mkrepo "$TT/plan14"; mktodo "$TT/plan14"
out=$(emit "$TT/subouter/sub" "$TT/plan14/todo.md")
check "T14 submodule as target" "$(echo "$out" | grep -c "Target $TT/subouter/sub@main")" "1"
# T14 PASS — a submodule launches correctly as target: the root resolved is the working tree, not
# the absorbed git directory.

# T15 — a `git submodule add` submodule as coordination root
mkrepo "$TT/code15"
( cd "$TT/subouter/sub"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo )
out=$(emit "$TT/code15" "$TT/subouter/sub/todo.md")
check "T15 submodule as coordination" "$(echo "$out" | grep -c "Todo $TT/subouter/sub@main")" "1"
check "T15 zero.sh in submodule's own gitdir" "$([ -f "$TT/subouter/.git/modules/sub/zero.sh" ] && echo yes || echo no)" "yes"
# T15 PASS — a submodule launches correctly as coordination root, and zero.sh lands in its own
# (absorbed) git directory.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
