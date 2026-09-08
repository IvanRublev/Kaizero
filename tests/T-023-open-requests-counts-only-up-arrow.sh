#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=35s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-023-open-requests-counts-only-up-arrow — open_requests() counting only ↑, from any cwd,
# under either locale.
# Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor
#   tests `command -v claude` before any startup guard runs)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T-023-open-requests-counts-only-up-arrow
#
# The widened grammar, driven directly against a fixture todo carrying one box of every symbol:
# how many are still at ↑, counted from either the coordination root or the target root. The
# fixture todo carries an open [↑] box, so it is emitted in MR mode (emit_mr) — 039j's guard
# refuses that todo under --local-merge, and a local-merge emit would write no zero.sh at all.

TT="$TESTROOT/T-023-open-requests-counts-only-up-arrow"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }

# emit_mr(): the same emit in MR mode, for the one case (T23) whose fixture todo carries an open
# [↑] box — 039j's guard refuses that todo under --local-merge, so a local-merge emit would
# write no zero.sh at all and open_requests would have no todo blob to read. Needs an origin the
# forge resolves from; KAIZERO_FORGE supplies it without touching the fixture's remotes.
emit_mr(){ ( cd "$1"; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$2" 2>&1 ); }

mkrepo "$TT/code23"; mkrepo "$TT/plan23"
git -C "$TT/code23" remote add origin https://github.com/acme/code23.git   # MR mode needs one (039z)
( cd "$TT/plan23"
  printf -- '- [ ] A unchecked\n- [x] B checked\n- [?] C reviewed\n- [\xe2\x86\x91] D requested\n- [\xe2\x9b\x94] E declined\n- [\xe2\x9c\x93] F checkmark landed\n' > todo.md
  git add todo.md; git commit -qm todo )
emit_mr "$TT/code23" "$TT/plan23/todo.md" >/dev/null

# T23 — open_requests() counts only ↑, from any cwd, under either locale
eval "$(sed -n '/^open_requests() {/,/^}/p' "$REAL_SCRIPT")"
COORD_ROOT="$TT/plan23"; COORD_BASE=main; TODO_PATH=todo.md
for loc in C en_US.UTF-8; do
  # only D holds ↑, among ⛔/✓/?/x/space too
  check "T23 $loc count, from coord root" "$( (export LC_ALL="$loc"; cd "$TT/plan23" && open_requests) )" "1"
  # names COORD_ROOT explicitly; a bare 'git show' here would find no todo blob
  check "T23 $loc count, from target root" "$( (export LC_ALL="$loc"; cd "$TT/code23" && open_requests) )" "1"
done
# every call returns 1, identically under LC_ALL=C and a UTF-8 locale, proving open_requests
# names $COORD_ROOT explicitly rather than trusting the caller's cwd, and counts only ↑ among
# the fixture's ⛔/✓/?/x/space boxes.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
