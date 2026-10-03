#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=180s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# BUG-078-resolved-list — `zero.sh resolve-tasks` (the launcher loop's resolved-list step) and
# `zero.sh todo-list` reading its result: the cache's home and invalidation, the step's silence and
# progress display, and that a warm `todo-list` resolves nothing itself.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none — python3 (already required) supplies the pseudo-terminal
# Folder under $TESTROOT: $TESTROOT/BUG-078-resolved-list
# Wall-clock budget: seconds to a minute — one case rebuilds a 30-id list on a pseudo-terminal
# Cross-references: ISSUE-077-task-cache-and-progress.sh covers validate-tasks' own cache and bar,
# whose display this step reuses; Z-001-todo-list.sh pins todo-list's output shape.

TR="$TESTROOT/BUG-078-resolved-list"; mkdir -p "$TR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/claude"; chmod +x "$TR/bin/claude"

# fresh repo under $TR/$1 with $2 unchecked ids (TASK-1..N) with one Task file each, plus a checked
# line, an id with no file (NOFILE-1) and an id with two files (DUP-1). Sets $ZERO and $D.
newrepo(){
  local d="$TR/$1" n="$2" i; mkdir -p "$d/tasks"; cd "$d"
  git init -q -b main; git config user.email t@t.t; git config user.name test
  { printf -- '- [x] Z0 seed\n- [x] Z1 seed\n'
    for (( i = 1; i <= n; i++ )); do printf -- '- [ ] TASK-%s x\n' "$i"; done
    printf -- '- [ ] NOFILE-1 none\n- [ ] DUP-1 two\n- [?] Z2 other\n'; } > todo.md
  for (( i = 1; i <= n; i++ )); do printf -- '### Acceptance criteria\n- [ ] a\n' > "tasks/TASK-$i.md"; done
  printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/DUP-1.md
  printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/DUP-1-copy.md
  git add -A; git commit -qm init
  KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
  ZERO="$d/.git/zero.sh"; D="$d"
}
# rt <tag> — one resolve-tasks run; captured stdout+stderr in $TR/<tag>.out, display (fd 4) in
# $TR/<tag>.fd4 (a plain file: the plain-line mode), status in $RC
rt(){ "$B3" "$ZERO" resolve-tasks > "$TR/$1.out" 2>&1 4>"$TR/$1.fd4"; RC=$?; }
walked(){ [ -s "$TR/$1.fd4" ] && echo yes || echo no; }
cachef(){ ls "$D/.git/" | grep '^task-resolved-' | head -1; }
tl(){ "$B3" "$ZERO" todo-list > "$TR/$1.out" 2> "$TR/$1.err"; }

# B78-1 — the step builds the list in the git dir: silent, exit 0, untracked, not in the working tree
newrepo c1 12
rt a
check "B78-1 exit 0" "$RC" "0"
check "B78-1 silent" "$(wc -c < "$TR/a.out" | tr -d ' ')" "0"
check "B78-1 list in the coordination git dir" "$(ls "$D/.git/" | grep -c '^task-resolved-')" "1"
check "B78-1 absent from the working tree" "$(find "$D" -type f -not -path '*/.git/*' -name 'task-resolved-*' | wc -l | tr -d ' ')" "0"
check "B78-1 git status shows nothing" "$(git status --porcelain | wc -l | tr -d ' ')" "0"
check "B78-1 no temp file left" "$(ls "$D/.git/" | grep -c '^task-resolved-.*\.tmp')" "0"
rt b
check "B78-1 hit draws nothing" "$(walked b)" "no"
check "B78-1 hit silent" "$(wc -c < "$TR/b.out" | tr -d ' ')" "0"

# B78-2 — a warm todo-list is byte-identical to the live one (ok, missing, ambiguous, checked,
# other-symbol lines) and resolves nothing itself
tl warm
rm -f "$D/.git/"task-resolved-*
tl live
check "B78-2 warm equals live" "$(cmp -s "$TR/warm.out" "$TR/live.out" && echo same || echo DIFFERS)" "same"
check "B78-2 live prints paths" "$(grep -c 'TASK-1 x  /' "$TR/live.out")" "1"
"$B3" "$ZERO" todo-list TASK-12 > "$TR/live-last.out" 2>&1   # the last page holds the two unusable lines
check "B78-2 live prints the no-file line bare" "$(grep -c '^- \[ \] NOFILE-1 none$' "$TR/live-last.out")" "1"
check "B78-2 live prints the ambiguous line bare" "$(grep -c '^- \[ \] DUP-1 two$' "$TR/live-last.out")" "1"
check "B78-2 live writes no cache" "$(ls "$D/.git/" | grep -c '^task-resolved-')" "0"
rt c
PS4='+@${FUNCNAME[0]:-main}@ ' "$B3" -x "$ZERO" todo-list 2> "$TR/trace.txt" > "$TR/trace.out" 4>/dev/null
check "B78-2 warm trace output equals live" "$(cmp -s "$TR/trace.out" "$TR/live.out" && echo same || echo DIFFERS)" "same"
check "B78-2 warm trace has no resolve_task_ids" "$(grep -c '@resolve_task_ids@' "$TR/trace.txt")" "0"
check "B78-2 warm trace has no canon" "$(grep -c '@canon@' "$TR/trace.txt")" "0"

# B78-3 — independence from validate-tasks, both ways, whatever it finds
check "B78-3 resolve-tasks wrote no task-defs cache" "$(ls "$D/.git/" | grep -c '^task-defs-ok-')" "0"
"$B3" "$ZERO" validate-tasks > "$TR/v.out" 2>&1; VRC=$?
check "B78-3 validate-tasks still reports its findings" "$VRC" "1"
check "B78-3 validate-tasks keeps missing-task-file" "$(grep -c '^missing-task-file NOFILE-1' "$TR/v.out")" "1"
check "B78-3 validate-tasks wrote no resolved list" "$(ls "$D/.git/" | grep -c '^task-resolved-')" "1"
check "B78-3 step exit 0 and silent with findings present" "$(rt f; echo "$RC:$(wc -c < "$TR/f.out" | tr -d ' ')")" "0:0"

# B78-4 — invalidation: file-name changes and committed list changes rebuild; content edits and
# uncommitted list edits do not
sleep 1
rt g0; check "B78-4 baseline hit" "$(walked g0)" "no"
printf -- '### Acceptance criteria\n- [x] a\n' > tasks/TASK-2.md
rt g1; check "B78-4 content edit does not rebuild" "$(walked g1)" "no"
printf -- '- [ ] TASK-1 edited uncommitted\n' >> todo.md
rt g2; check "B78-4 uncommitted list edit does not rebuild" "$(walked g2)" "no"
git checkout -q todo.md
mv tasks/TASK-3.md tasks/TASK-3-renamed.md
tl stale
check "B78-4 stale cache: todo-list shows the renamed path" "$(grep -c 'TASK-3-renamed.md$' "$TR/stale.out")" "1"
CB=$(cat "$D/.git/$(cachef)")
tl stale2
check "B78-4 stale cache: todo-list wrote no cache" "$([ "$(cat "$D/.git/$(cachef)")" = "$CB" ] && echo same || echo CHANGED)" "same"
rt g3; check "B78-4 rename rebuilds" "$(walked g3)" "yes"
tl fresh; check "B78-4 after rebuild todo-list shows the rename" "$(grep -c 'TASK-3-renamed.md$' "$TR/fresh.out")" "1"
printf 'notes\n' > tasks/notes.md
rt g4; check "B78-4 unrelated new file does not rebuild" "$(walked g4)" "no"
rm tasks/notes.md
git mv tasks/TASK-4.md tasks/TASK-4-x.md 2>/dev/null; git commit -qm rn
rt g5; check "B78-4 deleted/renamed file rebuilds" "$(walked g5)" "yes"
sed -i.bak 's/TASK-5 x/TASK-5 x/; /TASK-6 x/d' todo.md; rm -f todo.md.bak; git commit -qam drop6
rt g6; check "B78-4 committed list change rebuilds" "$(walked g6)" "yes"
check "B78-4 git status clean of the cache" "$(git status --porcelain | grep -c 'task-resolved')" "0"

# B78-5 — damaged cache: todo-list prints the correct output without writing; the step repairs it
newrepo c5 6
rt h0; tl live5
for dmg in truncate garbage empty; do
  C="$D/.git/$(cachef)"
  case "$dmg" in
    truncate) head -3 "$C" > "$C.t"; mv "$C.t" "$C" ;;
    garbage)  printf 'junk\n' > "$C" ;;
    empty)    : > "$C" ;;
  esac
  tl dm
  check "B78-5 $dmg: correct todo-list" "$(cmp -s "$TR/dm.out" "$TR/live5.out" && echo same || echo DIFFERS)" "same"
  rt h1; check "B78-5 $dmg: next step repairs" "$(walked h1)" "yes"
  tl dm; check "B78-5 $dmg: repaired list serves the same output" "$(cmp -s "$TR/dm.out" "$TR/live5.out" && echo same || echo DIFFERS)" "same"
done
# a list that matches the signature but lacks an id still gives every line its path
C="$D/.git/$(cachef)"; { head -1 "$C"; sed -n '2,$p' "$C" | sed '3d'; } > "$C.t"; mv "$C.t" "$C"
tl lack; check "B78-5 an id the list lacks resolves live" "$(cmp -s "$TR/lack.out" "$TR/live5.out" && echo same || echo DIFFERS)" "same"

# B78-6 — display: plain lines under their own label, nothing without a descriptor, no todo-list bar
newrepo c6 40
rt p1
check "B78-6 five plain lines" "$(wc -l < "$TR/p1.fd4" | tr -d ' ')" "5"
check "B78-6 own label" "$(grep -c 'Resolving task files ' "$TR/p1.fd4")" "5"
check "B78-6 not validate-tasks' label" "$(grep -c 'Validating' "$TR/p1.fd4")" "0"
check "B78-6 last line names the true total" "$(tail -1 "$TR/p1.fd4" | grep -c ' 42/42$')" "1"
rm -f "$D/.git/"task-resolved-*
"$B3" "$ZERO" resolve-tasks > "$TR/nod.out" 2>&1 4>&-; check "B78-6 no descriptor: nothing" "$(wc -c < "$TR/nod.out" | tr -d ' ')" "0"
rm -f "$D/.git/"task-resolved-*
"$B3" "$ZERO" todo-list > /dev/null 2> "$TR/tlbar.err" 4>"$TR/tlbar.fd4"
check "B78-6 todo-list draws nothing" "$(wc -c < "$TR/tlbar.fd4" | tr -d ' ')" "0"
bar(){   # $1 tag, $2 KAIZERO_PROGRESS_DELAY
  rm -f "$D/.git/"task-resolved-*
  KAIZERO_PROGRESS_DELAY="$2" KAIZERO_COLOR=1 python3 -c 'import pty,sys; raise SystemExit(pty.spawn(["bash","-c",sys.argv[1]]))' \
    "cd '$D' && '$B3' '$ZERO' resolve-tasks 4>&1 >'$TR/$1.out' 2>&1" < /dev/null > "$TR/$1.raw" 2>/dev/null
}
bar b0 0
check "B78-6 delay 0 draws a bar from the first id" "$(grep -c 'Resolving task files' "$TR/b0.raw")" "1"
check "B78-6 bar erased at the end" "$(tail -c 20 "$TR/b0.raw" | grep -c "$(printf '\033')\[K")" "1"
check "B78-6 bar stayed off the captured streams" "$(wc -c < "$TR/b0.out" | tr -d ' ')" "0"
bar bq 60
check "B78-6 inside the threshold draws nothing" "$(wc -c < "$TR/bq.raw" | tr -d ' ')" "0"
bar bh 0
rm -f "$TR/bh.raw"
KAIZERO_PROGRESS_DELAY=0 python3 -c 'import pty,sys; raise SystemExit(pty.spawn(["bash","-c",sys.argv[1]]))' \
  "cd '$D' && '$B3' '$ZERO' resolve-tasks 4>&1 >/dev/null 2>&1" < /dev/null > "$TR/bh.raw" 2>/dev/null
check "B78-6 cache hit draws nothing" "$(wc -c < "$TR/bh.raw" | tr -d ' ')" "0"

# B78-7 — unwritable git dir: the step costs the cache, never the output
newrepo c7 6
tl live7
chmod a-w "$D/.git"
rt u; URC=$RC
tl un
chmod u+w "$D/.git"
check "B78-7 step exits 0" "$URC" "0"
check "B78-7 step silent" "$(wc -c < "$TR/u.out" | tr -d ' ')" "0"
check "B78-7 todo-list output unchanged" "$(cmp -s "$TR/un.out" "$TR/live7.out" && echo same || echo DIFFERS)" "same"
check "B78-7 no cache written" "$(ls "$D/.git/" | grep -c '^task-resolved-')" "0"

# B78-8 — sixteen launchers at once: no partial read, identical output
newrepo c8 30
for k in $(seq 1 16); do ( "$B3" "$ZERO" resolve-tasks > "$TR/par$k.out" 2>&1 4>/dev/null; "$B3" "$ZERO" todo-list > "$TR/parl$k.out" 2>&1 ) & done
wait
check "B78-8 one cache file, no temp left" "$(ls "$D/.git/" | grep -c '^task-resolved-')" "1"
check "B78-8 every step silent" "$(cat "$TR"/par[0-9]*.out | wc -c | tr -d ' ')" "0"
rm -f "$D/.git/"task-resolved-*; tl live8
DIFFS=0; for k in $(seq 1 16); do cmp -s "$TR/parl$k.out" "$TR/live8.out" || DIFFS=$((DIFFS+1)); done
check "B78-8 all todo-list outputs identical" "$DIFFS" "0"

# B78-9 — claim untouched, usage and help name the step
check "B78-9 usage names resolve-tasks" "$("$ZERO" 2>&1 | grep -c 'resolve-tasks')" "1"
check "B78-9 --help names the step in the delay text" "$(bash "$SCRIPT" --help 2>&1 | grep -c 'resolve-tasks')" "1"
check "B78-9 loop runs the step on every pass (three sites)" "$(grep -c '"\$ZERO_SH" resolve-tasks' "$REPO/kaizero.sh")" "3"

cd "$TESTROOT"
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
