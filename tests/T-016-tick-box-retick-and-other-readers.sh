#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=35s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-016-tick-box-retick-and-other-readers — tick_box's retick argument, todo-rewrite mode
# preservation, target_branches_for_id's empty-answer success, and fenced-block immunity for both
# new readers.
# Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor tests
#   `command -v claude` before any startup guard runs)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T-016-tick-box-retick-and-other-readers
#
# Driven directly against fixture todos: whether a landed box is rewritten by tick_box's retick
# argument, whether a todo rewrite preserves the file's mode, whether an empty scan answer still
# succeeds, and whether both new readers ignore boxes inside a fenced block. Several fixture todos
# carry an open [↑] box, so they are emitted in MR mode (emit_mr) — 039j's guard refuses that todo
# under --local-merge, and a local-merge emit would write no zero.sh at all.

TT="$TESTROOT/T-016-tick-box-retick-and-other-readers"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }

# emit_mr(): the same emit in MR mode, for the cases whose fixture todo carries an open [↑] box —
# 039j's guard refuses that todo under --local-merge, so a local-merge emit would write no zero.sh
# at all and every box read below would come back empty. Needs an origin the forge resolves from;
# KAIZERO_FORGE supplies it without touching the fixture's remotes.
emit_mr(){ ( cd "$1"; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$2" 2>&1 ); }

# T24 — tick_box's retick argument rewrites a landed box; without it a landed box is left untouched
mkrepo "$TT/code24"; mkrepo "$TT/plan24"
git -C "$TT/code24" remote add origin https://github.com/acme/code24.git   # MR mode needs one (039z)
( cd "$TT/plan24"; printf -- '- [\xe2\x86\x91] D requested\n' > todo.md; git add todo.md; git commit -qm todo )
emit_mr "$TT/code24" "$TT/plan24/todo.md" >/dev/null   # [↑] todo: refused under --local-merge (039j)
ZERO24="$TT/plan24/.git/zero.sh"
eval "$(sed -n '/^tick_box() {/,/^}/p' "$ZERO24")"
(
  cd "$TT/plan24"
  COORD_ROOT="$TT/plan24" TODO_PATH=todo.md TODO_ABS="$TT/plan24/todo.md"
  before="$(git rev-parse HEAD)"
  tick_box D y >/dev/null   # merge-retry shape: no retick, box already landed
  # want 1 — unchanged
  check "T24 no-retick untouched" "$(grep -c '^- \[↑\] D requested$' todo.md)" "1"
  check "T24 no-retick no commit" "$([ "$(git rev-parse HEAD)" = "$before" ] && echo yes || echo NO)" "yes"
  tick_box D x retick >/dev/null
  check "T24 retick rewrites" "$(grep -c '^- \[x\] D requested$' todo.md)" "1"
  check "T24 retick commit msg" "$(git log -1 --format=%s)" "zero sync D"
) || FAILED=1
# T24 PASS — a merge retry over an already-↑ box (tick_box called without retick) leaves the box
# and HEAD untouched; the same box, retried with retick, rewrites its multi-byte ↑ down to the
# one-byte x and commits "zero sync D" — proving the rewrite arithmetic reads the box's own length
# rather than assuming one byte.

# T25 — a todo rewrite preserves the file's mode, for the tick pass and the retick pass
mkrepo "$TT/code25"; mkrepo "$TT/plan25"
git -C "$TT/code25" remote add origin https://github.com/acme/code25.git   # MR mode needs one (039z)
( cd "$TT/plan25"; printf -- '- [ ] Q1 noop\n- [\xe2\x86\x91] Q2 noop\n' > todo.md; git add todo.md; git commit -qm todo )
emit_mr "$TT/code25" "$TT/plan25/todo.md" >/dev/null   # [↑] todo: refused under --local-merge (039j)
ZERO25="$TT/plan25/.git/zero.sh"
eval "$(sed -n '/^tick_box() {/,/^}/p' "$ZERO25")"
(
  cd "$TT/plan25"
  chmod 664 todo.md
  before="$(stat -c %a todo.md 2>/dev/null || stat -f %Lp todo.md)"
  check "T25 fixture mode is 664" "$before" "664"
  COORD_ROOT="$TT/plan25" TODO_PATH=todo.md TODO_ABS="$TT/plan25/todo.md"
  ( umask 077; tick_box Q1 x >/dev/null )
  check "T25 tick preserves mode" "$(stat -c %a todo.md 2>/dev/null || stat -f %Lp todo.md)" "664"
  chmod 664 todo.md
  ( umask 077; tick_box Q2 x retick >/dev/null )
  check "T25 retick preserves mode" "$(stat -c %a todo.md 2>/dev/null || stat -f %Lp todo.md)" "664"
) || FAILED=1
# T25 PASS — todo.md stays at mode 664 across both the tick and the retick rewrite, even when the
# session doing the rewrite runs under umask 077 — the temp-file-and-mv idiom no longer leaves the
# writing session's own umask on the file.

# T26 — a scan that finds nothing has succeeded: target_branches_for_id gives rc 0 on an empty answer
tbfr="$TT/tbfr"; mkdir -p "$tbfr/target"
git -C "$tbfr/target" init -q -b main; git -C "$tbfr/target" config user.email t@t.t; git -C "$tbfr/target" config user.name test
git -C "$tbfr/target" commit -q --allow-empty -m init
git -C "$tbfr/target" branch 7-1-foo
eval "$(sed -n '/^sanitize_id() {/,/^}/p' "$REAL_SCRIPT")"
eval "$(sed -n '/^todo_lines() {/,/^}/p' "$REAL_SCRIPT")"
eval "$(sed -n '/^todo_ids() {/,/^}/p' "$REAL_SCRIPT")"
eval "$(sed -n '/^claimed_by_longer_id() {/,/^}/p' "$REAL_SCRIPT")"
eval "$(sed -n '/^target_branches_for_id() {/,/^}/p' "$REAL_SCRIPT")"
mkdir -p "$tbfr/plan"
( cd "$tbfr/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] 7 first\n- [ ] 7-1 second\n' > todo.md; git add todo.md; git commit -qm todo )
(
  set -e
  COORD_ROOT="$tbfr/plan" TARGET_ROOT="$tbfr/target" COORD_BASE=main TODO_PATH=todo.md
  out=$(target_branches_for_id 7); rc=$?
  # want 0 — longest-id-wins left no survivor
  check "T26 target_branches_for_id 7, rc" "$rc" "0"
  check "T26 target_branches_for_id 7, out" "[$out]" "[]"
) || FAILED=1
# T26 PASS — with 7-1-foo the only branch and 7's prefix match dropped by longest-id-wins in favor
# of 7-1, target_branches_for_id 7 exits 0 with empty stdout, so a caller may assign it plainly
# under errexit without an empty answer aborting the caller.

# T27 — both new readers ignore boxes inside a fenced block, under either locale
mkrepo "$TT/code27"; mkrepo "$TT/plan27"
git -C "$TT/code27" remote add origin https://github.com/acme/code27.git   # MR mode needs one (039z)
( cd "$TT/plan27"
  printf -- '- [ ] G1 noop\n\n```\n- [\xe2\x86\x91] F6 example\n- [x] F7 example\n```\n' > todo.md
  git add todo.md; git commit -qm todo )
emit_mr "$TT/code27" "$TT/plan27/todo.md" >/dev/null
ZS27="$TT/plan27/.git/zero.sh"
eval "$(sed -n '/^open_requests() {/,/^}/p' "$REAL_SCRIPT")"
for loc in C en_US.UTF-8; do
  # want [] — fenced, not a real box
  check "T27 $loc box-symbol-on-base F6" "[$(LC_ALL="$loc" bash "$ZS27" box-symbol-on-base F6)]" "[]"
  out=$( ( COORD_ROOT="$TT/plan27" COORD_BASE=main TODO_PATH=todo.md; LC_ALL="$loc" open_requests ) )
  # want 0 — the fenced ↑ is never counted
  check "T27 $loc open_requests count" "$out" "0"
done
# T27 PASS — box_symbol_on_base and open_requests() both skip a [↑]/[x] box sitting inside a
# fenced block, identically under LC_ALL=C and a UTF-8 locale. Verified red (with each reader's
# fence guard stripped, box-symbol-on-base F6 returns ↑ and open_requests counts 1)

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
