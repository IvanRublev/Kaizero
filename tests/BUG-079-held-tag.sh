#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# BUG-079-held-tag — `zero.sh todo-list` tags Tasks a live peer holds with " ⚒️ held by a live peer"
# right behind the id token; everything else in the output stays as it was.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/BUG-079-held-tag
# Wall-clock budget: seconds — no Run command of this scenario wraps itself in `timeout`

TB="$TESTROOT/BUG-079-held-tag"; mkdir -p "$TB/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TB/bin/claude"; chmod +x "$TB/bin/claude"
TAG=$' \xe2\x9a\x92\xef\xb8\x8f held by a live peer'

cd "$TB"; mkdir repo; cd repo
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] H0 seed\n- [ ] A first\n- [ ] B second\n- [ ] C third\n- [ ] SMTH:855 colon id\n- [ ] [BUG-5348](tasks/BUG-5348.md) link row\n- [ ] SOLO\n- [x] DONE landed\n' > todo.md
mkdir tasks; printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/BUG-5348.md
git add -A; git commit -qm init
KAIZERO_TEST_EMIT=1 PATH="$TB/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
ZERO="$TB/repo/.git/zero.sh"
mkdir -p .git/session

# hold <id> <branch-id>: a LIVE peer holding the Task, exactly what acquire writes
PEERS=()
hold(){
  sleep 600 > /dev/null 2>&1 & local p=$!; PEERS+=("$p")
  local st; st="$(ps -o lstart= -p "$p" | awk '{$1=$1;print}')"
  git worktree add -q -b "main-task-$2" "$TB/wt-$2" main
  printf '%s\n%s\n%s\n%s\n' "$p" "$st" "$(date +%s)" PEERINST > "$TB/wt-$2/.owner"
  printf '%s\n%s\n' "$st" "$2" > ".git/session/$p"
}

"$ZERO" todo-list > "$TB/before.out" 2>&1
check "H0 untagged baseline" "$(grep -c 'held by a live peer' "$TB/before.out")" "0"

hold A A; hold SMTH:855 SMTH-855; hold BUG-5348 BUG-5348; hold SOLO SOLO
"$ZERO" todo-list > "$TB/after.out" 2> "$TB/after.err"; rc=$?
check "H1 exit" "$rc" "0"
check "H1 stderr empty" "$(wc -c < "$TB/after.err" | tr -d ' ')" "0"
check "H1 A tagged" "$(grep -cF -- "- [ ] A${TAG} first" "$TB/after.out")" "1"
check "H1 B C untagged" "$(grep -cF -e "- [ ] B second" -e "- [ ] C third" "$TB/after.out")" "2"
check "H2 colon id tagged" "$(grep -cF -- "- [ ] SMTH:855${TAG} colon id" "$TB/after.out")" "1"
check "H2 link row tagged after whole link" "$(grep -cF -- "- [ ] [BUG-5348](tasks/BUG-5348.md)${TAG} link row" "$TB/after.out")" "1"
check "H2 id alone tagged" "$(grep -cF -- "- [ ] SOLO${TAG}" "$TB/after.out")" "1"
check "H3 stripping the tag restores the baseline" "$(diff <(sed "s/${TAG}//" "$TB/after.out") "$TB/before.out" >/dev/null && echo yes || echo NO)" "yes"
check "H3 same line count" "$(wc -l < "$TB/after.out" | tr -d ' ')" "$(wc -l < "$TB/before.out" | tr -d ' ')"
check "H3 landed untagged" "$(grep -c 'DONE.*held' "$TB/after.out")" "0"
check "H4 C-locale bytes" "$(LC_ALL=C "$ZERO" todo-list 2>&1 | cmp -s - "$TB/after.out" && echo same || echo DIFF)" "same"

# dead owner: untagged
kill "${PEERS[0]}"; wait "${PEERS[0]}" 2>/dev/null || true
"$ZERO" todo-list > "$TB/dead.out" 2>&1
check "H5 dead owner untagged" "$(grep -cF -- "- [ ] A first" "$TB/dead.out")" "1"
# session marker naming another Task: untagged
printf '%s\n%s\n' "$(ps -o lstart= -p "${PEERS[3]}" | awk '{$1=$1;print}')" "OTHER" > ".git/session/${PEERS[3]}"
"$ZERO" todo-list > "$TB/moved.out" 2>&1
check "H5 moved-on untagged" "$(grep -cF -- "- [ ] SOLO" "$TB/moved.out")" "1"

# scan failure: untagged list, one warning on stderr, exit 0
REALGIT=$(type -P git)
printf '#!/usr/bin/env bash\ncase " $* " in *" worktree list "*) exit 3;; esac\nexec "%s" "$@"\n' "$REALGIT" > "$TB/bin/git"; chmod +x "$TB/bin/git"
PATH="$TB/bin:$PATH" "$ZERO" todo-list > "$TB/fail.out" 2> "$TB/fail.err"; rc=$?
check "H6 exit" "$rc" "0"
check "H6 stdout untagged" "$(grep -c 'held by a live peer' "$TB/fail.out")" "0"
check "H6 one warning" "$(wc -l < "$TB/fail.err" | tr -d ' ')" "1"
rm "$TB/bin/git"

# prompts
check "H7 both prompts carry the held rules" "$(grep -c 'is held by a live peer:' "$REAL_SCRIPT")" "2"
check "H7 README" "$(grep -c 'held by a live peer' "$REPO/README.md")" "1"
# H PASS — tagged after the id (link whole, colon id, id alone), baseline restored by removing the tag,
# dead/moved-on peers untagged, failed scan degrades to a warning, prompts and README carry the rule.

kill "${PEERS[@]}" 2>/dev/null || true
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
