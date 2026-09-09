#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# R-010-link-shaped-task-id — a Release Todo List row's first token written as a markdown
# link `[ID](path)` resolves to ID everywhere a raw first token is read as the task id:
# validate-ids, todo-list/validate-tasks, claim, duplicate-id, leg3_orphaned, and the
# non-link/malformed-label fall-through. TASK-058e.

TR="$TESTROOT/R-010-link-shaped-task-id"; mkdir -p "$TR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/claude"; chmod +x "$TR/bin/claude"

# fresh repo under $TR/$1, one seed commit, real zero.sh emitted (no claude launch needed).
newrepo(){
  local d="$TR/$1"; mkdir -p "$d"; cd "$d"
  git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] Z0 seed\n' > todo.md; git add -A; git commit -qm init
  KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
  ZERO="$d/.git/zero.sh"
}

# L1 — a link row with an existing Task file passes validate-ids clean
newrepo l1
mkdir -p tasks
printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/BUG-5348-quick-entry-same-start-time-overlap.md
printf -- '- [ ] [BUG-5348](tasks/BUG-5348-quick-entry-same-start-time-overlap.md) overlap fix\n' > todo.md
git add -A; git commit -qm l1
"$ZERO" validate-ids > "$TR/l1.out" 2>&1
check "L1 exit" "$?" "0"
check "L1 output" "$(wc -c < "$TR/l1.out" | tr -d ' ')" "0"
# L1 PASS — no missing-id/PATFAIL finding on a link-shaped row whose bracketed id is well-formed.

# L2 — unchecked_tail_ids (validate-tasks' own resolution path) resolves the link row's unwrapped
# id to its Task file
newrepo l2
mkdir -p tasks
printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/BUG-5348.md
printf -- '- [ ] [BUG-5348](tasks/BUG-5348.md) overlap fix\n' > todo.md
git add -A; git commit -qm l2
"$ZERO" validate-tasks > "$TR/l2.out" 2>&1
check "L2 validate-tasks exit" "$?" "0"
check "L2 validate-tasks output" "$(wc -c < "$TR/l2.out" | tr -d ' ')" "0"
# L2 PASS — validate-tasks resolves the link row's unwrapped id to tasks/BUG-5348.md with no
# missing-task-file finding.

# L3 — claim resolves and brands the same link row exactly as an equivalent plain row would
own_session "$TR/l2-session"
wt=$("$ZERO" claim BUG-5348 2>"$TR/l2-claim.err"); rc=$?
check "L3 claim exit" "$rc" "0"
check "L3 claim branch" "$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)" "main-task-BUG-5348"
# L3 PASS — claim BUG-5348 claims tasks/BUG-5348.md, branding a main-task-BUG-5348 worktree
# exactly as an equivalent plain row would.

# L4 — leg3_orphaned matches a link row's unwrapped id against a live holder exactly as a plain id
newrepo l4
mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/H3LD.md
printf -- '- [ ] [H3LD](tasks/H3LD.md) x\n' > todo.md; git add -A; git commit -qm l4
git worktree add -q -b main-task-H3LD "$TR/l4-wt" main
( sleep 20 ) > "$TR/l4-livepid.out" 2>&1 & LIVEPID=$!
STARTVAL=$(ps -o lstart= -p "$LIVEPID" | tr -s ' ')
printf '%s\n%s\n' "$LIVEPID" "$STARTVAL" > "$TR/l4-wt/.owner"
GITCOMMON="$(git -C "$TR/l4" rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$GITCOMMON/session"
printf '%s\n%s\n' "$STARTVAL" "H3LD" > "$GITCOMMON/session/$LIVEPID"
"$ZERO" validate-ids; check "L4 no orphan" "$?" "0"
kill "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null
rm -f "$TR/l4-wt/.owner" "$GITCOMMON/session/$LIVEPID"
# L4 PASS — a live holder of `H3LD` is matched against the link row's unwrapped id, so no
# orphaned-id finding fires; a plain `- [ ] H3LD x` row would behave identically.

# L5 — two link rows differing only in link text, same bracketed id, are duplicate-id
newrepo l5
printf -- '- [ ] Z0 seed\n- [ ] [D1](a.md) first\n- [ ] [D1](b.md) second\n' > todo.md
git add -A; git commit -qm l5
"$ZERO" validate-ids > "$TR/l5.out" 2>&1; check "L5 exit" "$?" "1"
check "L5 lines" "$(grep -c '^duplicate-id D1:' "$TR/l5.out")" "2"
# L5 PASS — same as two plain `D1` rows would report.

# L6 — a first token not link-shaped (no brackets, internal space, or nested brackets) validates
# byte for byte the same as before this change
newrepo l6
printf -- '- [ ] Z0 seed\n- [ ] plain not a link\n- [ ] [x] (y.md) space between\n- [ ] [a[b]](c.md) nested\n' > todo.md
git add -A; git commit -qm l6
"$ZERO" validate-ids > "$TR/l6.out" 2>&1
check "L6 exit" "$?" "1"
check "L6 plain fails on shape" "$(grep -c 'missing-id plain' "$TR/l6.out")" "1"
check "L6 space-between fails on shape" "$(grep -c 'missing-id \[x\]' "$TR/l6.out")" "1"
check "L6 nested fails on shape" "$(grep -c 'missing-id \[a\[b\]\](c.md)' "$TR/l6.out")" "1"
# L6 PASS — none of the three non-link-shaped tokens are treated as a link; each fails
# KAIZERO_TASK_ID_PATTERN on its own raw literal text, exactly as before this change.

# L7 — a link whose bracketed label itself fails the id pattern still reports missing-id/PATFAIL
# on the extracted label, not a false pass
newrepo l7
printf -- '- [ ] Z0 seed\n- [ ] [fixthebug](tasks/x.md) desc\n' > todo.md
git add -A; git commit -qm l7
"$ZERO" validate-ids > "$TR/l7.out" 2>&1; check "L7 exit" "$?" "1"
check "L7 missing-id" "$(grep -c '^missing-id fixthebug:' "$TR/l7.out")" "1"
check "L7 patfail" "$(grep -c 'first token \`fixthebug\` does not match KAIZERO_TASK_ID_PATTERN' "$TR/l7.out")" "1"
# L7 PASS — the label, not the whole bracketed token, is what KAIZERO_TASK_ID_PATTERN
# rejects, so no false pass.

# L8 — the parenthesized path is never used as, or compared against, the resolved id: a
# label/path mismatch resolves to the label alone, no new mismatch class
newrepo l8
mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/BUG-5348.md
printf -- '- [ ] [BUG-5348](tasks/BUG-9999-other.md) x\n' > todo.md; git add -A; git commit -qm l8
"$ZERO" validate-ids > "$TR/l8.out" 2>&1
check "L8 exit" "$?" "0"
check "L8 no mismatch finding" "$(wc -c < "$TR/l8.out" | tr -d ' ')" "0"
"$ZERO" validate-tasks > "$TR/l8b.out" 2>&1
check "L8 validate-tasks exit" "$?" "0"
# L8 PASS — resolves to BUG-5348 (the label), not BUG-9999 (the path), and is not reported as
# any new mismatch class.

# L9 — fmt_finding's printed raw line for a link row's finding still shows the full original
# `[ID](path)` text, not the unwrapped id
newrepo l9
printf -- '- [ ] Z0 seed\n- [ ] [D2](a.md) first\n- [ ] [D2](b.md) second\n' > todo.md
git add -A; git commit -qm l9
"$ZERO" validate-ids > "$TR/l9.out" 2>&1
check "L9 raw a" "$(grep -c '\[D2\](a.md) first$' "$TR/l9.out")" "1"
check "L9 raw b" "$(grep -c '\[D2\](b.md) second$' "$TR/l9.out")" "1"
# L9 PASS — the diagnostic text keeps the operator's original whole line; only the id used
# for the id checks was unwrapped.

# L10 — doc spots name the link form as a supported example
check "L10 usage text" "$(grep -c 'bracketed text is unwrapped before the pattern check runs' "$REAL_SCRIPT")" "1"
check "L10 prompt blocks" "$(grep -c '\[BUG-5348\](tasks/\.\.\.)' "$REAL_SCRIPT")" "2"
# L10 PASS — the KAIZERO_TASK_ID_PATTERN usage text and both "first token is the task_id"
# prompt blocks each name the link form.

# L11 — the actual `zero.sh todo-list` CLI subcommand (todo_list, not unchecked_tail_ids) lists a
# link row's id unwrapped
newrepo l11
mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/BUG-5348.md
printf -- '- [ ] [BUG-5348](tasks/BUG-5348.md) overlap fix\n' > todo.md
git add -A; git commit -qm l11
"$ZERO" todo-list > "$TR/l11.out" 2>&1
check "L11 todo-list keeps original link text" "$(grep -c '^\- \[ \] \[BUG-5348\](tasks/BUG-5348\.md) overlap fix' "$TR/l11.out")" "1"
check "L11 todo-list resolved the link row's path" "$(grep -c 'tasks/BUG-5348\.md$' "$TR/l11.out")" "1"
# L11 PASS — todo_list's own id-extraction awk unwraps the link before resolve_task_ids, so the
# row's Task file is found and its path appended, exactly as an equivalent plain-token row's would
# be; the printed line text itself stays the operator's original link, unchanged.

# L12 — `zero.sh merge` ticks a link row's box on base: tick_box's own comparisons no longer
# report `missing` for a link-shaped row
newrepo l12
mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/BUG-5779.md
printf -- '- [ ] [BUG-5779](tasks/BUG-5779.md) x\n' > todo.md; git add -A; git commit -qm l12
own_session "$TR/l12-session"
wt=$("$ZERO" claim BUG-5779 2>"$TR/l12-claim.err")
( cd "$wt" && echo work > f.txt && git add f.txt && git commit -qm work )
merge_out=$("$ZERO" merge BUG-5779 "$wt" 2>"$TR/l12-merge.err"); merge_rc=$?
check "L12 merge exit" "$merge_rc" "0"
check "L12 box ticked on base" "$(git -C "$TR/l12" show main:todo.md | grep -c '^\- \[x\] \[BUG-5779\](tasks/BUG-5779\.md) x')" "1"
# L12 PASS — tick_box's state-check and rewrite comparisons unwrap the link row's id, so the merge
# actually finds and ticks the row instead of reporting `missing`.

# L13 — `zero.sh done` (is_done/box_checked_on_base) reports a landed link row's raw id Landed,
# so a second claim/merge attempt on it takes the already-Landed path
done_rc=0; "$ZERO" "done" BUG-5779 >/dev/null 2>&1 || done_rc=$?
check "L13 done reports Landed" "$done_rc" "0"
# L13 PASS — box_checked_on_base unwraps the link row's id, same as an equivalent plain-token row.

# L14 — `zero.sh box-symbol-on-base` (sync_mrs' own reader) resolves a link row's symbol
newrepo l14
printf -- '- [ ] Z0 seed\n- [x] [DONE1](a.md) x\n' > todo.md; git add -A; git commit -qm l14
check "L14 box-symbol-on-base" "$("$ZERO" box-symbol-on-base DONE1)" "x"
# L14 PASS — box_symbol_on_base unwraps the link row's id, same as a plain-token row.

# zero_funcs <zero.sh path>: sources everything up to (not including) the trailing `case
# "${1:-}" in` dispatch, so functions with no CLI subcommand (ids_with_box, claimable_ids) become
# callable directly — same helper U-011-sync-mrs-resolves-boxes.sh uses.
zero_funcs(){
  local f="$1" tmp ln
  ln=$(grep -nF 'case "${1:-}" in' "$f" | head -1 | cut -d: -f1)
  tmp="$(mktemp)"; head -n "$((ln - 1))" "$f" > "$tmp"
  # shellcheck disable=SC1090
  . "$tmp"; rm -f "$tmp"
}

# L15 — ids_with_box (sync_mrs' own [↑]-row enumeration) yields the unwrapped id for a link row
newrepo l15
printf -- '- [ ] Z0 seed\n- [\xe2\x86\x91] [UP1](a.md) x\n' > todo.md; git add -A; git commit -qm l15
( zero_funcs "$ZERO"
  out=$(ids_with_box '↑')
  check "L15 ids_with_box unwrapped" "$out" "UP1"
)
# L15 PASS — ids_with_box's own scan unwraps the link row's id, same as a plain-token row.

# main_funcs: claimable_ids lives in kaizero.sh's own launcher (never emitted into zero.sh),
# so it needs the launcher's own functions sourced instead — same idiom as zero_funcs, up to the
# trailing `main "$@"` invocation instead of zero.sh's dispatch `case`.
main_funcs(){
  local f="$1" tmp total
  total=$(wc -l < "$f" | tr -d ' ')
  tmp="$(mktemp)"; head -n "$((total - 1))" "$f" > "$tmp"
  # shellcheck disable=SC1090
  . "$tmp"; rm -f "$tmp"
}

# L16 — claimable_ids (the fleet wake-up message's own source) names a link row by its unwrapped id
newrepo l16
printf -- '- [ ] Z0 seed\n- [ ] [WAKE1](a.md) x\n' > todo.md; git add -A; git commit -qm l16
( COORD_BASE=main; TODO_PATH=todo.md
  main_funcs "$REAL_SCRIPT"
  out=$(claimable_ids | grep -c '^WAKE1$')
  check "L16 claimable_ids unwrapped" "$out" "1"
)
# L16 PASS — claimable_ids' own unclaimed-id scan unwraps the link row's id.

# L17 — `zero.sh sync-mrs` resolves a link-shaped `[↑]` row's merged forge outcome onto its own
# box, same as it would for a plain-token row
newrepo l17
mkdir -p "$TR/l17-bin"
cat > "$TR/l17-bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth status") exit 0 ;;
  "pr list") cat "$L17_GH_LIST" ;;
esac
STUB
chmod +x "$TR/l17-bin/gh"
( cd "$TR/l17"
  git checkout -qb l17a-fix
  echo y > g; git add g; git commit -qm work
  git checkout -q main
  printf -- '- [\xe2\x86\x91] [l17a](tasks/l17a.md) fix\n' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/l17a.md
  git add -A; git commit -qm "mark l17a inflight"
)
Z17="$TR/l17/.git/zero.sh"
# --local-merge bakes MR_MODE=0/FORGE=''/ORIGIN_URL='' unconditionally (039h) — rewrite to
# defaults so this case's own env exports below win, same fix U-011's mrsetup() applies.
sed -i.bak \
  -e 's/^MR_MODE=.*/: "${MR_MODE:=0}"/' \
  -e 's/^FORGE=.*/: "${FORGE:=}"/' \
  -e 's/^ORIGIN_URL=.*/: "${ORIGIN_URL:=}"/' \
  "$Z17"
rm -f "$Z17.bak"
sha17=$(git -C "$TR/l17" rev-parse l17a-fix)
cat > "$TR/l17-gh-list.json" <<JSON
[{"number":1,"headRefOid":"$sha17","baseRefName":"main","state":"MERGED","url":"https://github.com/acme/x/pull/1"}]
JSON
( cd "$TR/l17"
  export PATH="$TR/l17-bin:$PATH" KAIZERO_FORGE=gh FORGE=gh ORIGIN_URL="https://github.com/acme/x.git" MR_MODE=1 L17_GH_LIST="$TR/l17-gh-list.json"
  git remote add origin "$ORIGIN_URL"
  out=$(bash "$Z17" sync-mrs 2>"$TR/l17.err")
  cat "$TR/l17.err" >&2
  check "L17 sync-mrs box now x" "$(bash "$Z17" box-symbol-on-base l17a)" "x"
  check "L17 sync-mrs stdout" "$(printf '%s\n' "$out" | grep -c 'sync l17a: merged')" "1"
)
# L17 PASS — ids_with_box's own [↑]-row scan (feeding sync_mrs' per-id lookup) unwraps the link
# row's id, same as a plain-token row would resolve.

# R PASS — L1 through L17 report PASS.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
