#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=160s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCENARIO_DIR/test-setup.sh"

# B-001-startup-guard-refusals — a dirty tree, a detached HEAD, a subdir, a leftover claim
# worktree, an untracked todo.
# Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor
# tests `command -v claude` before any startup guard runs)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/B-001-startup-guard-refusals
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# Five pristine repos: one with a dirty working tree, one on a detached HEAD, one clean launched
# from a subdir, one clean launched from inside a leftover ../ts-* task worktree, and one clean
# whose todo is gitignored (so untracked on the base branch). Each must make kaizero refuse to
# start with the matching message and a non-zero exit.

TB="$TESTROOT/B-001-startup-guard-refusals"
for name in dirty detached nested worktree untracked; do
  mkdir -p "$TB/$name"
  ( cd "$TB/$name"; git init -q; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init
    echo "- [ ] G1 noop" > todo.md; git add todo.md; git commit -qm todo )
done
( cd "$TB/dirty";    echo change >> f )       # dirty working tree
( cd "$TB/detached"; git checkout -q --detach )
mkdir -p "$TB/nested/sub"                      # clean repo; we launch from this subdir
# leftover claim worktree, exactly what a crashed peer abandons: branch <base>-task-1 + ../ts-*
( cd "$TB/worktree"; base="$(git rev-parse --abbrev-ref HEAD)"
  git worktree add -q "$TB/ts-$base-task-1-dead" -b "$base-task-1" "$base" )
# todo present on disk but gitignored → untracked on the base, yet the tree still reads clean
( cd "$TB/untracked"; git rm -q --cached todo.md
  echo todo.md > .gitignore; git add .gitignore; git commit -qm ignore-todo )

# B1 — a dirty working tree refuses before any claude launch
cd "$TB/dirty"
if out=$(timeout 20 bash "$SCRIPT" --local-merge todo.md -t x 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" != 0 ] && echo "$out" | grep -qi dirty; then r1=refused; else r1="rc=$rc: $out"; fi
check "B1 dirty-guard" "$r1" "refused"

# B2 — a detached HEAD refuses before any claude launch
cd "$TB/detached"
if out=$(timeout 20 bash "$SCRIPT" --local-merge todo.md -t x 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" != 0 ] && echo "$out" | grep -qi 'detached HEAD'; then r2=refused; else r2="rc=$rc: $out"; fi
check "B2 detached-guard" "$r2" "refused"

# B3 — a launch from a subdir refuses instead of misfiring ../ts-* paths
cd "$TB/nested/sub"                            # clean repo, but not at the repo root
if out=$(timeout 20 bash "$SCRIPT" --local-merge ../todo.md -t x 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" != 0 ] && echo "$out" | grep -qi 'not at.*repo root'; then r3=refused; else r3="rc=$rc: $out"; fi
check "B3 subdir-guard" "$r3" "refused"

# B4 — a launch inside a leftover claim worktree refuses, and takes no second claim
cd "$TB/ts-$(git -C "$TB/worktree" rev-parse --abbrev-ref HEAD)-task-1-dead"   # a peer's claim worktree
if out=$(timeout 20 bash "$SCRIPT" --local-merge todo.md -t x 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" != 0 ] && echo "$out" | grep -qi 'not at.*repo root'; then r4=refused; else r4="rc=$rc: $out"; fi
check "B4 worktree-guard" "$r4" "refused"
if git -C "$TB/worktree" branch --list '*-task-*-task-*' | grep -q .; then r4b=created; else r4b=none; fi
check "B4 no second-claim branch" "$r4b" "none"

# B5 — a gitignored (untracked-on-base) todo refuses up front
cd "$TB/untracked"                             # clean repo, but the todo is not in the base tree
if out=$(timeout 20 bash "$SCRIPT" --local-merge todo.md -t x 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" != 0 ] && echo "$out" | grep -qi 'not tracked'; then r5=refused; else r5="rc=$rc: $out"; fi
check "B5 untracked-guard" "$r5" "refused"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
