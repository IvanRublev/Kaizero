#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=30s
# shellcheck disable=SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-025-claim-first-refusal-mr — `mr` called by a session that never ran `claim` for a task id
# in this session exits with its own distinct code and a "claim first" message, instead of
# being folded into the existing "not your task — instance X holds it" refusal (TASK-064).
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: T31

mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktask(){ mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/$1.md"; }
mktodo(){ ( cd "$1"; printf -- '- [ ] %s task\n' "$2" > todo.md; mktask "$2"; git add -A; git commit -qm todo ); }
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1"; git config user.email t@t.t; git config user.name test )
}

# T31 — a session that never claimed N5 in this session calls mr for it (two-repository MR-mode
# fleet, same shape as X-001's own mkorigin/mkrepo/mktodo/boot, no forge stub needed — the new
# check refuses before any forge call).
T31="$TESTROOT/T31"; mkdir -p "$T31/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T31/bin/claude"; chmod +x "$T31/bin/claude"
mkorigin "$T31/code"; mkrepo "$T31/plan"; mktodo "$T31/plan" N5
( cd "$T31/code"; PATH="$T31/bin:$PATH" KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$T31/plan/todo.md" >/dev/null 2>&1 )
ZERO31="$T31/plan/.git/zero.sh"
own_session "$T31/plan-session"
( cd "$T31/plan"
  out=$("$ZERO31" mr N5 "$T31/code" 2>&1); rc=$?
  check "T31 mr never-claimed exit" "$rc" "9"
  check "T31 mr says claim first" "$(printf '%s' "$out" | grep -c "run 'zero.sh claim N5' first")" "1"
  check "T31 mr omits not-your-task" "$(printf '%s' "$out" | grep -c 'not your task')" "0"
  check "T31 mr box unchanged" "$(grep -c '\[ \] N5' todo.md)" "1"
  [ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
) || FAILED=1
# T31 PASS — nothing this session ever claimed: `mr`'s new check refuses before its own `.owner`
# comparison, land gate, or any push/forge call runs.
