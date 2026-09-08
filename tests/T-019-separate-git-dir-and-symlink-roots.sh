#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-019-separate-git-dir-and-symlink-roots — a `git init --separate-git-dir=` repository and a
# repository whose .git is a symlink, each taking either the target or the coordination role, and
# a genuine linked worktree off a --separate-git-dir= main.
# Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor tests
#   `command -v claude` before any startup guard runs)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T-019-separate-git-dir-and-symlink-roots
#
# Two fixture repositories: code (the launch/target repo, where the run is invoked from) and plan
# (holds the todo). KAIZERO_TEST_EMIT=1 prints the banner and writes .git/zero.sh (into the
# coordination repo's git dir), then exits before any claude would start — every case here is a
# pure launch-time decision over unusual root layouts: a --separate-git-dir= repository or a
# .git-symlink repository taking either role, and a genuine linked worktree off a relocated
# --separate-git-dir= main.

TT="$TESTROOT/T-019-separate-git-dir-and-symlink-roots"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktodo(){ ( cd "$1"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }
# --local-merge: none of these fixture repos carry an origin, so a two-repo case (SAME_REPO=0)
# would otherwise hit the new default-to-mr detection's "no origin" refusal before ever reaching
# the role-detection guards this scenario exists to test; the flag opts every case back into
# today's local-merge path, same-repo cases included (a harmless no-op there).
emit(){ ( cd "$1"; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1 ); }   # $1=launch dir $2=todo arg
refuse(){ ( cd "$1"; rc=0; out=$(KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }

# T16 — a `git init --separate-git-dir=` repository as target
mkdir -p "$TT/sgd16-root"
git init -q -b main --separate-git-dir="$TT/sgd16-gitdir" "$TT/sgd16-root"
( cd "$TT/sgd16-root"; git config user.email t@t.t; git config user.name test; echo x > f; git add f; git commit -qm init; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo )
mkrepo "$TT/plan16"; mktodo "$TT/plan16"
out=$(emit "$TT/sgd16-root" "$TT/plan16/todo.md")
check "T16 separate-git-dir as target" "$(echo "$out" | grep -c "Target $TT/sgd16-root@main")" "1"
# T16 PASS — a --separate-git-dir= repository launches correctly as target: the root resolved is
# the working tree, never the relocated git directory.

# T17 — a `git init --separate-git-dir=` repository as coordination root
mkrepo "$TT/code17"
out=$(emit "$TT/code17" "$TT/sgd16-root/todo.md")
check "T17 separate-git-dir as coordination" "$(echo "$out" | grep -c "Todo $TT/sgd16-root@main")" "1"
check "T17 zero.sh in the relocated gitdir" "$([ -f "$TT/sgd16-gitdir/zero.sh" ] && echo yes || echo no)" "yes"
# T17 PASS — a --separate-git-dir= repository launches correctly as coordination root, and
# zero.sh lands in the relocated git directory.

# T18 — a repository whose .git is a symlink, as target
mkrepo "$TT/sym18-src"
mv "$TT/sym18-src/.git" "$TT/sym18-gitdir"
ln -s "$TT/sym18-gitdir" "$TT/sym18-src/.git"
( cd "$TT/sym18-src"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo )
mkrepo "$TT/plan18"; mktodo "$TT/plan18"
out=$(emit "$TT/sym18-src" "$TT/plan18/todo.md")
check "T18 symlinked .git as target" "$(echo "$out" | grep -c "Target $TT/sym18-src@main")" "1"
# T18 PASS — a .git-symlink repository launches correctly as target: the root resolved is the
# working tree, never the git directory the symlink points at.

# T19 — a repository whose .git is a symlink, as coordination root
mkrepo "$TT/code19"
out=$(emit "$TT/code19" "$TT/sym18-src/todo.md")
check "T19 symlinked .git as coordination" "$(echo "$out" | grep -c "Todo $TT/sym18-src@main")" "1"
# T19 PASS — a .git-symlink repository launches correctly as coordination root.

# T20 — a genuine linked worktree off a --separate-git-dir= main: refused, no wrong path named
mkdir -p "$TT/sgd20-root"
git init -q -b main --separate-git-dir="$TT/sgd20-gitdir" "$TT/sgd20-root"
( cd "$TT/sgd20-root"; git config user.email t@t.t; git config user.name test; echo x > f; git add f; git commit -qm init )
( cd "$TT/sgd20-root"; git worktree add -q -b sgd20-linked "$TT/sgd20-linked" main )
( cd "$TT/sgd20-linked"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo )
mkrepo "$TT/code20"
out=$(refuse "$TT/code20" "$TT/sgd20-linked/todo.md")
check "T20 refuses, main undeterminable" "$(echo "$out" | grep -c 'could not be determined here')" "1"
check "T20 never names the git directory as a path" "$(echo "$out" | grep -c "$TT/sgd20-gitdir")" "0"
# T20 PASS — a relocated --separate-git-dir= main has no core.worktree and worktree list cannot
# resolve its own path either (a known git limitation), so a linked worktree off it is still
# refused, but the refusal names no path at all rather than the wrong one (the git directory,
# which has no working tree) — satisfying "every path a refusal prints is a directory that has a
# working tree" by naming none when none can be proven.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
