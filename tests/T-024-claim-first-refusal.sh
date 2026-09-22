#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=30s
# shellcheck disable=SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-024-claim-first-refusal — `merge`/`mr` called by a session that never ran `claim` for a
# task id in this session exit with their own distinct code and a "claim first" message,
# instead of being folded into the existing "not your task — instance X holds it" refusal
# (TASK-064).
# Needs real claude: no
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: T29

mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }

# T29 — a session that never claimed N3 in this session calls merge for it (single-repository
# `--local-merge` fleet)
T29="$TESTROOT/T29"; mkrepo "$T29/repo"
( cd "$T29/repo"
  printf -- '- [ ] N3 never-claimed task\n' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/N3.md
  git add -A; git commit -qm todo )
( cd "$T29/repo"; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge todo.md >/dev/null 2>&1 || true )
ZERO29="$T29/repo/.git/zero.sh"
own_session "$T29/repo-session"
( cd "$T29/repo"
  before_main=$(git rev-parse main)
  out=$("$ZERO29" merge N3 "$PWD" 2>&1); rc=$?
  check "T29 merge never-claimed exit" "$rc" "9"
  check "T29 merge says claim first" "$(printf '%s' "$out" | grep -c "run 'zero.sh claim N3' first")" "1"
  check "T29 merge omits not-your-task" "$(printf '%s' "$out" | grep -c 'not your task')" "0"
  check "T29 merge box unchanged" "$(grep -c '\[ \] N3' todo.md)" "1"
  check "T29 merge target unchanged" "$(git rev-parse main)" "$before_main"
  [ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
) || FAILED=1
# T29 PASS — no worktree, no `.owner`, nothing this session ever claimed: the new check refuses
# `merge` before the `.owner` comparison, land gate, or any tick/merge runs.
