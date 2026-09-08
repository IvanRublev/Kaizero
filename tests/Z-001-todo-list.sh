#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# Z-001-todo-list — `zero.sh todo-list`'s output shape: the tail cut, edge-case lists, and a
# Landed non-`x` symbol never anchoring the cut.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/Z-001-todo-list
# Wall-clock budget: seconds — no Run command of this scenario wraps itself in `timeout`
#
# Task discovery moved out of the prompt's own file read into `.git/zero.sh todo-list`,
# the same `git show "$COORD_BASE:$TODO_PATH"` channel `claim`/`merge`/`validate-ids` already
# decide from. Output is the tail of the checkbox list — the two lines before the first unchecked
# `[ ]` box through the end, never any other Landed symbol — so a long todo of landed work costs the
# session nothing to read. Each case gets its own throwaway repo; no real claude is needed.

# --- Setup (shared stub + helper) ---
TZR="$TESTROOT/Z-001-todo-list"; mkdir -p "$TZR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TZR/bin/claude"; chmod +x "$TZR/bin/claude"

# fresh repo under $TZR/$1, one seed commit, real zero.sh emitted (no claude launch needed).
# Sets $ZERO for the caller and leaves cwd inside the new repo.
newrepoz(){
  local d="$TZR/$1"; mkdir -p "$d"; cd "$d"
  git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] Z0 seed\n' > todo.md; git add -A; git commit -qm init
  KAIZERO_TEST_EMIT=1 PATH="$TZR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
  ZERO="$d/.git/zero.sh"
}

# Z1 — checkbox lines only, verbatim, fenced examples invisible
newrepoz z1
cat > todo.md <<'EOF'
# Todo

Prose that is not a checkbox.

- [ ] Z1 alpha task
- [ ] Z2 beta task

```
- [ ] FENCED never a task
```
EOF
git add -A; git commit -qm z1
"$ZERO" todo-list > "$TZR/z1.out" 2>&1
check "Z1 lines" "$(wc -l < "$TZR/z1.out" | tr -d ' ')" "2"
check "Z1 verbatim" "$(diff <(printf -- '- [ ] Z1 alpha task\n- [ ] Z2 beta task\n') "$TZR/z1.out" >/dev/null && echo yes || echo NO)" "yes"
check "Z1 no prose" "$(grep -c 'Prose\|^#' "$TZR/z1.out")" "0"
check "Z1 no fence" "$(grep -c FENCED "$TZR/z1.out")" "0"
check "Z1 usage" "$("$ZERO" 2>&1 | grep -c 'todo-list')" "1"
# Z1 PASS — two lines, byte-identical to the committed ones, heading/prose/fenced example all
# absent, and `todo-list` is named in the subcommand usage string.

# Z2 — the tail cut: two lines of context before the first `[ ]` box, everything after it
newrepoz z2
printf -- '- [x] Z1 done\n- [x] Z2 done\n- [x] Z3 done\n- [x] Z4 done\n- [ ] Z5 todo\n- [ ] Z6 todo\n- [x] Z7 done later\n' > todo.md
git add -A; git commit -qm z2
"$ZERO" todo-list > "$TZR/z2.out" 2>&1
check "Z2 lines" "$(wc -l < "$TZR/z2.out" | tr -d ' ')" "5"
check "Z2 first" "$(head -1 "$TZR/z2.out")" "- [x] Z3 done"
check "Z2 last" "$(tail -1 "$TZR/z2.out")" "- [x] Z7 done later"
check "Z2 dropped" "$(grep -c 'Z1 done\|Z2 done' "$TZR/z2.out")" "0"
# Z2 PASS — the two `[x]` tasks before the kept pair are gone; the window starts at `Z3`, two
# lines above the first `[ ]`, and runs to the end of the list, `[x] Z7` included.

# Z3 — a short list starts at the top; an all-`[x]` list prints nothing
newrepoz z3
printf -- '- [x] Z1 done\n- [ ] Z2 todo\n- [ ] Z3 todo\n' > todo.md; git add -A; git commit -qm z3a
"$ZERO" todo-list > "$TZR/z3a.out" 2>&1
# nothing skipped
check "Z3a lines" "$(wc -l < "$TZR/z3a.out" | tr -d ' ')" "3"
printf -- '- [x] Z1 done\n- [x] Z2 done\n- [x] Z3 done\n' > todo.md; git commit -qam z3b
"$ZERO" todo-list > "$TZR/z3b.out" 2>&1; rc=$?
check "Z3b exit" "$rc" "0"
check "Z3b bytes" "$(wc -c < "$TZR/z3b.out" | tr -d ' ')" "0"
# Z3 PASS — one line precedes the first `[ ]`, fewer than two, so the output starts at the top
# and skips nothing; with every box `[x]` the command exits 0 and prints nothing at all.

# Z4 — a Landed non-`x` symbol well before the first `[ ]` never anchors the cut
newrepoz z4
SYMS=('!' '?' '↑' '⛔' '🚧'); SYM="${SYMS[$((RANDOM % 5))]}"
printf -- '- [%s] Z1 landed other\n- [x] Z2 done\n- [x] Z3 done\n- [x] Z4 done\n- [x] Z5 done\n- [ ] Z6 todo\n- [x] Z7 done later\n' "$SYM" > todo.md
git add -A; git commit -qm z4
LC_ALL=en_US.UTF-8 "$ZERO" todo-list > "$TZR/z4.out" 2>&1
echo "drawn Z4 symbol: $SYM (quote it when reporting a failure)"
check "Z4 lines" "$(wc -l < "$TZR/z4.out" | tr -d ' ')" "4"
check "Z4 first" "$(head -1 "$TZR/z4.out")" "- [x] Z4 done"
# the symbol never anchors the cut
check "Z4 no cut" "$(grep -c 'Z1 landed other' "$TZR/z4.out")" "0"
# Z4 PASS — whichever symbol was drawn, the Landed `Z1` line sits three lines before the first
# `[ ]` (`Z6`) and never appears in the output; only the literal `- [ ]` on `Z6` anchors the cut, so
# the window starts two lines above it, at `Z4`. A UTF-8 locale is pinned because the shared box
# grammar (`- \[(.|↑|⛔)\]`) names `↑` and `⛔` byte-wise but matches any other multi-byte
# symbol only where `.` is a character rather than a byte — a property of that grammar, which
# `todo-list` reuses unchanged, not of this subcommand.

# Z5 — every box Landed, mixing `[x]` with another symbol, prints nothing
newrepoz z5
SYMS=('!' '?' '↑' '⛔' '🚧'); SYM="${SYMS[$((RANDOM % 5))]}"
printf -- '- [x] Z1 done\n- [%s] Z2 landed other\n- [x] Z3 done\n' "$SYM" > todo.md
git add -A; git commit -qm z5
LC_ALL=en_US.UTF-8 "$ZERO" todo-list > "$TZR/z5.out" 2>&1; rc=$?
echo "drawn Z5 symbol: $SYM"
check "Z5 exit" "$rc" "0"
check "Z5 bytes" "$(wc -c < "$TZR/z5.out" | tr -d ' ')" "0"
# Z5 PASS — a Landed run mixing `[x]` and `$SYM`, with no `[ ]` anywhere, is exactly the
# all-Landed verdict `all_todos_done` also reaches on this blob: `todo-list` exits 0 and prints
# zero bytes, so the launcher's closing report and the session's own "ALL TASKS LANDED" check can
# never disagree.

# Z6 — an uncommitted todo edit is invisible until it is committed
newrepoz z6
printf -- '- [ ] Z1 committed task\n' > todo.md; git add -A; git commit -qm z6
printf -- '- [ ] Z9 uncommitted task\n' >> todo.md
"$ZERO" todo-list > "$TZR/z6a.out" 2>&1
check "Z6 hidden" "$(grep -c 'Z9' "$TZR/z6a.out")" "0"
# the working tree really does carry it
check "Z6 on disk" "$(grep -c 'Z9' todo.md)" "1"
git commit -qam 'commit Z9'
"$ZERO" todo-list > "$TZR/z6b.out" 2>&1
check "Z6 visible" "$(grep -c 'Z9' "$TZR/z6b.out")" "1"
mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/Z9.md; git add -A; git commit -qm 'add Z9 task file'
( cd "$TZR/z6" && own_session "$TZR/z6-session" && wt=$("$ZERO" claim Z9 2>/dev/null)
  check "Z6 claim" "$?" "0"
  check "Z6 branch" "$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)" "main-task-Z9"
) || FAILED=1
# Z6 PASS — a session offered only `todo-list`'s output never sees the uncommitted `Z9`, so it
# never claims it; the same line becomes claimable the moment it is committed on the base. `claim`
# itself is untouched by this issue — the gate that closes here is discovery, and `merge`'s land
# gate ("no checkbox line for `$raw` … on `$COORD_BASE`") remains the backstop behind it.

# Z7 — a blob read that fails surfaces git's own error, never an empty list
newrepoz z7
rm -f todo.md; git add -A; git commit -qm 'drop todo.md'
"$ZERO" todo-list > "$TZR/z7.out" 2> "$TZR/z7.err"; rc=$?
check "Z7 exit non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo NO)" "yes"
check "Z7 stdout" "$(wc -c < "$TZR/z7.out" | tr -d ' ')" "0"
check "Z7 stderr" "$([ -s "$TZR/z7.err" ] && echo present || echo EMPTY)" "present"
# Z7 PASS — with `todo.md` gone from `$COORD_BASE`, `git show` itself fails; that failure
# reaches stderr and its non-zero exit propagates out of `todo-list` (the script's own
# `set -o pipefail`), so an unreadable Release Todo List can never be mistaken for a finished one —
# a session following the prompt's step 1 stops and reports the error instead of announcing ALL
# TASKS LANDED.

# Z8 — absence check: neither prompt reads the todo file for discovery any more
check "Z8 old read" "$(grep -c 'FIND candidate tasks yourself in @@TODO_ABS@@' "$REAL_SCRIPT")" "0"
# both prompt builders, worded identically
check "Z8 new call" "$(grep -c 'FIND candidate Tasks: run \`@@ZERO_SH@@ todo-list\`' "$REAL_SCRIPT")" "2"
# worded identically to each other
check "Z8 non-zero" "$(grep -c 'non-zero exit → STOP IMMEDIATELY: print \`@@ZERO_SH@@ todo-list\`' "$REAL_SCRIPT")" "2"
check "Z8 step 3" "$(grep -c 'If \`@@ZERO_SH@@ todo-list\` now prints nothing' "$REAL_SCRIPT")" "2"
check "Z8 dispatch" "$(grep -c '^  todo-list)' "$REAL_SCRIPT")" "1"
# the kata names the mechanism
check "Z8 readme" "$(grep -c 'zero.sh todo-list' "$REPO/README.md")" "1"
# Z8 PASS — the old raw-file wording is gone; both `build_zero_prompt` and `build_mr_prompt`
# carry the identical `todo-list` call and non-zero-exit handling in step 1 and the identical
# all-landed test in step 3; the subcommand is dispatched, and the README kata's step 1 names it.
# Z PASS — Z1 through Z8 all report PASS.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
