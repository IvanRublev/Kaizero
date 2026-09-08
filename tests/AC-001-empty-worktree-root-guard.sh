#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=185s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# AC-001-empty-worktree-root-guard — a wt_root() whose `git rev-parse --show-cdup` fails must
# refuse by name at all three call sites (target REPO_ROOT, --doctor's DOCTOR_ROOT, the
# coordination repo's COORD_ROOT), never silently misdirect the root to the launch directory or
# hand back an empty path as a cd target.
# Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor tests
# `command -v claude` before any startup guard runs).
# Tools beyond the shared prerequisites: none.
# Folder under $TESTROOT: $TESTROOT/AC-001-empty-worktree-root-guard
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s.
#
# A git stub sits ahead of the real one on a scenario-scoped PATH and makes `rev-parse
# --show-cdup` fail — wt_root()'s own mechanism (kaizero.sh:336-340) — in one of two modes:
# `all` (every `-C <dir> rev-parse --show-cdup` call fails — the shape that hits REPO_ROOT/
# DOCTOR_ROOT, both resolved before COORD_ROOT ever runs) or `coord` (only the call carrying
# `-C <todo dir>` fails — the shape that lets a two-repo launch clear the target guard intact and
# reach COORD_ROOT's own wt_root(TODO_DIR) call). Every other git call, and every --show-cdup call
# for a different directory, is passed straight through to the real binary.

# Setup
TY="$TESTROOT/AC-001-empty-worktree-root-guard"; mkdir -p "$TY/bin"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktodo(){ ( cd "$1"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }

REALGIT="$(type -P git)"
mkstub(){   # $1 = mode (all|coord), $2 = todo dir (only used for coord mode)
  cat > "$TY/bin/git" <<EOF
#!/usr/bin/env bash
REALGIT="$REALGIT"
mode="$1"
todo_dir="$2"
EOF
  cat >> "$TY/bin/git" <<'EOF'
is_cdup(){ [ "$1" = -C ] && [ "$3" = rev-parse ] && [ "$4" = --show-cdup ]; }
if [ "$mode" = all ] && is_cdup "$@"; then
  exit 1
fi
if [ "$mode" = coord ] && is_cdup "$@" && [ "$2" = "$todo_dir" ]; then
  exit 1
fi
exec "$REALGIT" "$@"
EOF
  chmod +x "$TY/bin/git"
}
mkpath(){ printf '%s:/usr/bin:/bin' "$TY/bin"; }

# AC1 — every `-C <dir> rev-parse --show-cdup` fails: a normal (same-repo) launch refuses naming
# the target root, never the launch cwd
mkrepo "$TY/y1"; mktodo "$TY/y1"
mkstub all ""
cd "$TY/y1"
out=$(KAIZERO_TEST_EMIT=1 PATH="$(mkpath):$PATH" timeout 20 bash "$SCRIPT" --local-merge todo.md 2>&1); rc=$?
check "AC1 refuses" "$(echo "$out" | grep -c 'Could not resolve the target repository root')" "1"
check "AC1 no empty cd target" "$(echo "$out" | grep -c "cd to ''")" "0"
check "AC1 rc" "$rc" "1"

# AC2 — every `-C <dir> rev-parse --show-cdup` fails: --doctor refuses naming the doctor root
mkrepo "$TY/y2"
mkstub all ""
cd "$TY/y2"
out=$(PATH="$(mkpath):$PATH" timeout 20 bash "$SCRIPT" --doctor 2>&1); rc=$?
check "AC2 refuses" "$(echo "$out" | grep -c 'Could not resolve the doctor root')" "1"
check "AC2 no empty cd" "$(echo "$out" | grep -c "cd to ''")" "0"
check "AC2 rc" "$rc" "1"

# AC3 — only `-C <todo dir> rev-parse --show-cdup` fails: target guard clears intact, the
# coordination repo's own root refuses by name
mkrepo "$TY/y3code"; mkrepo "$TY/y3plan"; mktodo "$TY/y3plan"
mkstub coord "$TY/y3plan"
cd "$TY/y3code"
out=$(KAIZERO_TEST_EMIT=1 PATH="$(mkpath):$PATH" timeout 20 bash "$SCRIPT" --local-merge "$TY/y3plan/todo.md" 2>&1); rc=$?
check "AC3 refuses" "$(echo "$out" | grep -c 'Could not resolve the coordination repository root')" "1"
check "AC3 no empty cd" "$(echo "$out" | grep -c "cd to ''")" "0"
check "AC3 rc" "$rc" "1"

# AC4 — --doctor --local-merge performs no extraction: unaffected by every-call failing
mkrepo "$TY/y4"
mkstub all ""
cd "$TY/y4"
out=$(PATH="$(mkpath):$PATH" timeout 20 bash "$SCRIPT" --doctor --local-merge 2>&1); rc=$?
check "AC4 all OK" "$(echo "$out" | grep -c 'All prerequisites OK')" "1"
check "AC4 no refusal" "$(echo "$out" | grep -c 'Could not resolve')" "0"
check "AC4 rc" "$rc" "0"

# AC5 — unmodified git: normal launch and --doctor still resolve and refuse exactly as before (regression)
mkrepo "$TY/y5"; mktodo "$TY/y5"
cd "$TY/y5"
out=$(KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge todo.md 2>&1)
check "AC5 launch OK" "$(echo "$out" | grep -c 'Base main')" "1"
mkdir -p "$TY/y5/sub"; cd "$TY/y5/sub"
out=$(timeout 20 bash "$SCRIPT" --doctor 2>&1); rc=$?
check "AC5 off-root doctor refuses" "$(echo "$out" | grep -c "Not at the main repo root — cd to '$TY/y5' first")" "1"
check "AC5 rc" "$rc" "1"

# AC6 — absence check: exactly three wt_root() call sites, each refusing by its own name on failure
check "AC6 call sites" "$(grep -c 'wt_root "' "$REAL_SCRIPT")" "3"
check "AC6 refusals" "$(grep -c 'Could not resolve the .* root"' "$REAL_SCRIPT")" "3"

# AC1 PASS — refuses = 1, no empty cd target = 0, rc = 1.
# AC2 PASS — refuses = 1, no empty cd = 0, rc = 1.
# AC3 PASS — refuses = 1, no empty cd = 0, rc = 1.
# AC4 PASS — all OK = 1, no refusal = 0, rc = 0.
# AC5 PASS — launch OK = 1, off-root doctor refuses = 1, rc = 1.
# AC6 PASS — call sites = 3, refusals = 3.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
