#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=35s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-015-the-widened-box-grammar-core — box_symbol_on_base and the `- [ ]`/any-box invariants over
# one box of every symbol.
# Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor tests
#   `command -v claude` before any startup guard runs)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T-015-the-widened-box-grammar-core
#
# The widened grammar, driven directly against a fixture todo carrying one box of every symbol:
# which symbol a box holds, and how many are still at ↑. The fixture todo carries an open [↑] box,
# so it is emitted in MR mode (emit_mr) — 039j's guard refuses that todo under --local-merge, and a
# local-merge emit would write no zero.sh at all.

TT="$TESTROOT/T-015-the-widened-box-grammar-core"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }

# emit_mr(): the same emit in MR mode, for the one case (T22) whose fixture todo carries an open
# [↑] box — 039j's guard refuses that todo under --local-merge, so a local-merge emit would write
# no zero.sh at all and every box read below would come back empty. Needs an origin the forge
# resolves from; KAIZERO_FORGE supplies it without touching the fixture's remotes.
emit_mr(){ ( cd "$1"; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$2" 2>&1 ); }

# T22 — the widened box grammar: box_symbol_on_base, and the `- [ ]`/any-box invariants hold over
# one box of every symbol
mkrepo "$TT/code22"; mkrepo "$TT/plan22"
git -C "$TT/code22" remote add origin https://github.com/acme/code22.git   # MR mode needs one (039z)
( cd "$TT/plan22"
  printf -- '- [ ] A unchecked\n- [x] B checked\n- [?] C reviewed\n- [\xe2\x86\x91] D requested\n- [\xe2\x9b\x94] E declined\n- [\xe2\x9c\x93] F checkmark landed\n' > todo.md
  git add todo.md; git commit -qm todo )
emit_mr "$TT/code22" "$TT/plan22/todo.md" >/dev/null
ZS22="$TT/plan22/.git/zero.sh"
zs22() { ( cd "$TT/plan22" && LC_ALL="$1" bash "$ZS22" "${@:2}" ); }

for loc in C en_US.UTF-8; do
  check "T22 $loc box A (space)" "[$(zs22 "$loc" box-symbol-on-base A)]" "[ ]"
  check "T22 $loc box B (x)" "$(zs22 "$loc" box-symbol-on-base B)" "x"
  check "T22 $loc box C (?)" "$(zs22 "$loc" box-symbol-on-base C)" "?"
  check "T22 $loc box D (↑)" "$(zs22 "$loc" box-symbol-on-base D)" "↑"
  check "T22 $loc box E (⛔)" "$(zs22 "$loc" box-symbol-on-base E)" "⛔"
  check "T22 $loc box F (✓)" "$(zs22 "$loc" box-symbol-on-base F)" "✓"
  # want [] — no todo line
  check "T22 $loc box missing" "[$(zs22 "$loc" box-symbol-on-base ZZZ)]" "[]"
  # want 0 — a ✓ box is Landed
  check "T22 $loc done F" "$(zs22 "$loc" "done" F >/dev/null 2>&1; echo $?)" "0"
  # want 1 — not dropped
  check "T22 $loc todo-list has F" "$(zs22 "$loc" todo-list | grep -c 'F checkmark landed')" "1"
  # want 0 — todo_lines/leg1_ids parse every box's id past a multi-byte symbol
  check "T22 $loc validate-ids" "$( (export LC_ALL="$loc"; cd "$TT/plan22" && KAIZERO_TASK_ID_PATTERN='.' bash "$ZS22" validate-ids) >/dev/null 2>&1; echo $?)" "0"
done

# unchecked_todos/all_todos_done: literal-space invariant untouched by the widened grammar
eval "$(sed -n '/^unchecked_todos() {/,/^}/p' "$REAL_SCRIPT")"
eval "$(sed -n '/^all_todos_done() {/,/^}/p' "$REAL_SCRIPT")"
( cd "$TT/plan22"
  COORD_ROOT="$TT/plan22" COORD_BASE=main TODO_PATH=todo.md MODE=zero
  # want 1 — B/C/D/E/F are landed, not unchecked
  check "T22 unchecked count (A only)" "$(unchecked_todos)" "1"
  all_todos_done
  # want 1 — not done
  check "T22 all_todos_done, A unchecked" "$?" "1"
  printf -- '- [x] A now landed too\n- [x] B checked\n- [?] C reviewed\n- [\xe2\x86\x91] D requested\n- [\xe2\x9b\x94] E declined\n- [\xe2\x9c\x93] F checkmark landed\n' > todo.md
  git commit -qam land-A
  check "T22 unchecked count (none left)" "$(unchecked_todos)" "0"
  all_todos_done
  # want 0 — done, ↑/⛔/✓ count as landed
  check "T22 all_todos_done, all landed" "$?" "0"
) || FAILED=1

check "T22 absence, enumerated pattern" "$(grep -cF -- '(.|↑|⛔)' "$REAL_SCRIPT" | tr -d ' ')" "0"
check "T22 absence, box match/strip" "$(grep -c -- '- \\\[\.\\\]' "$REAL_SCRIPT" | tr -d ' ')" "0"
check "T22 absence, one-byte reads" "$(grep -c 'substr(line, 1, 1)\|\^\.\\\]' "$REAL_SCRIPT" | tr -d ' ')" "0"

# merge symbol test: assert the GATE'S VERDICT (extracted from source), not a grep over its text —
# a hand-copied replica of the check would pass while the real gate drifts.
eval "$(sed -n '/^glyph_count() {/,/^}/p' "$REAL_SCRIPT")"
eval "$(sed -n '/^symbol_ok() {/,/^}/p' "$REAL_SCRIPT")"
for loc in C en_US.UTF-8; do
  check "T22 $loc symbol_ok x" "$( (export LC_ALL="$loc"; symbol_ok x)  >/dev/null 2>&1; echo $?)" "0"
  # want 0 — same verdict as under C
  check "T22 $loc symbol_ok ✓" "$( (export LC_ALL="$loc"; symbol_ok '✓') >/dev/null 2>&1; echo $?)" "0"
  check "T22 $loc symbol_ok ab" "$( (export LC_ALL="$loc"; symbol_ok 'ab') >/dev/null 2>&1; echo $?)" "1"
  check "T22 $loc symbol_ok ' '" "$( (export LC_ALL="$loc"; symbol_ok ' ')  >/dev/null 2>&1; echo $?)" "1"
  check "T22 $loc symbol_ok ]" "$( (export LC_ALL="$loc"; symbol_ok ']')  >/dev/null 2>&1; echo $?)" "1"
done
# built at runtime, not written literally here, so this very check does not itself become the hit
# the absence check is looking for.
pat='${#sym}'; pat="$pat"'" -ne 1'
srcdir="$(dirname "$REAL_SCRIPT")"
check "T22 absence, gate pinned by text" "$(grep -rnF -- "$pat" "$srcdir/.github/smoke.sh" "$srcdir/tests" 2>/dev/null | wc -l | tr -d ' ')" "0"
# T22 PASS — box_symbol_on_base prints the box's own symbol (space included) for every id and
# nothing for a missing line, identically under LC_ALL=C and a UTF-8 locale; done and todo-list
# treat a ✓ box as Landed under both locales too; unchecked_todos never counts a ↑/⛔/x/?/✓ box, and
# all_todos_done still needs a literal `- [ ]` to call a todo not-done, and treats ↑/⛔/✓ boxes as
# landed once the last space is gone; the enumerated pattern, the nine `\[.\]` sites and the four
# one-byte box reads are gone from kaizero.sh, and merge_task's one-glyph symbol guard
# (symbol_ok/glyph_count, extracted from source) gives the same verdict for x, ✓, ab, a space and ]
# under both locales; validate-ids (todo_lines/leg1_ids) parses every id past its box regardless of
# the box's symbol.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
