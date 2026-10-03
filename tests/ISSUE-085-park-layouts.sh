#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=150s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# ISSUE-085-park-layouts — `zero.sh park` in the two-repository layout, with and without MR mode:
# `[🚧]` lands in the coordination repository, the Task branch stays in the target repository,
# no worktree is left, nothing is pushed and no request is opened.
# Needs real claude: no — a stub `claude` and a stub `gh` stand in for them
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/ISSUE-085-park-layouts

TR="$TESTROOT/ISSUE-085-park-layouts"; mkdir -p "$TR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/claude"; chmod +x "$TR/bin/claude"
cat > "$TR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_LOG"
if [ "$1 ${2:-}" = "pr list" ] && [ "${3:-}" = "--json" ] && [ $# -eq 3 ]; then printf '%s\n' 'number headRefOid baseRefName state url' >&2; exit 1; fi
for a in "$@"; do [ "$a" = --help ] && { printf '%s\n' --repo --head --state --limit --json --base --title --body-file --hostname; exit 0; }; done
if [ "$1 ${2:-}" = "pr list" ]; then if [ -f "$STUB_GH_LIST" ]; then cat "$STUB_GH_LIST"; else echo '[]'; fi; fi
exit 0
STUB
chmod +x "$TR/bin/gh"
export STUB_GH_LOG="$TR/gh.log" STUB_GH_LIST="$TR/gh-list.json"; : > "$STUB_GH_LOG"
export PATH="$TR/bin:$PATH" KAIZERO_FORGE=gh KAIZERO_INSTANCE=tl1
BLK='> Blocked 2026-10-03 12:00+0000 limiter down; evidence: HTTP 429; unblocks when: the limiter is back'

# layout <name> <mode flag or empty>: a target repo cloned from a bare origin plus a separate
# coordination repo holding the todo and the Task file; zero.sh emitted for that pair
layout(){
  local n=$1 flag=$2 code="$TR/$1-code" plan="$TR/$1-plan"
  mkdir -p "$code-seed"; ( cd "$code-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test; echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$code-seed" "$code-origin.git"; git clone -q "$code-origin.git" "$code"
  ( cd "$code"; git config user.email t@t.t; git config user.name test )
  mkdir -p "$plan/tasks"; ( cd "$plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
    printf -- '- [ ] L1 layout task\n' > todo.md; printf '### Acceptance criteria\n\n- [ ] first\n' > tasks/L1.md; git add -A; git commit -qm init )
  # shellcheck disable=SC2086
  ( cd "$code"; KAIZERO_TEST_EMIT=1 bash "$SCRIPT" $flag "$plan/todo.md" -t x > /dev/null 2>&1 )
  ZERO="$plan/.git/zero.sh"
  sed -i.bak "s#^ORIGIN_URL=.*#ORIGIN_URL=$(printf '%q' "$code-origin.git")#" "$ZERO"; rm -f "$ZERO.bak"
}

for mode in mr local; do
  flag=""; [ "$mode" = local ] && flag=--local-merge
  layout "$mode" "$flag"
  code="$TR/$mode-code"; plan="$TR/$mode-plan"
  own_session "$TR/$mode-session"
  twt=$("$ZERO" claim L1); rc=$?
  check "$mode claim exits 0" "$rc" "0"
  echo wip > "$twt/wip.txt"
  tbranch=$(git -C "$twt" symbolic-ref --short HEAD)
  printf '%s\n' "$BLK" >> "$plan/tasks/L1.md"
  out=$("$ZERO" park L1 2>&1); rc=$?
  check "$mode park exits 0" "$rc" "0"
  check "$mode park stdout line" "$out" "park L1: blocked as [🚧]; worktree removed, branch $tbranch kept"
  check "$mode box [🚧] in the coordination repository" "$(git -C "$plan" show main:todo.md | grep -c '^- \[🚧\] L1')" "1"
  check "$mode Blocked line on the coordination base" "$(git -C "$plan" show main:tasks/L1.md | grep -c '^> Blocked')" "1"
  check "$mode target worktree removed" "$([ -d "$twt" ] && echo yes || echo no)" "no"
  check "$mode no worktree left in either repository" "$(( $(git -C "$plan" worktree list | wc -l) + $(git -C "$code" worktree list | wc -l) ))" "2"
  check "$mode branch kept in the target repository" "$(git -C "$code" rev-parse -q --verify "refs/heads/$tbranch" >/dev/null && echo yes)" "yes"
  check "$mode work in progress on the kept branch" "$(git -C "$code" show "$tbranch:wip.txt")" "wip"
  check "$mode nothing pushed" "$(git --git-dir="$code-origin.git" for-each-ref --format='%(refname)' refs/heads/ | tr '\n' ' ')" "refs/heads/main "
  check "$mode no request opened" "$(grep -c 'pr create' "$STUB_GH_LOG")" "0"
  check "$mode no [?] written" "$(git -C "$plan" show main:todo.md | grep -c '^- \[?\]')" "0"
done

# the hand-off writes `[?]` too when the request merged onto another base, with its review note
code="$TR/mr-code"; plan="$TR/mr-plan"; ZERO="$plan/.git/zero.sh"
printf -- '- [ ] L2 handoff task\n' >> "$plan/todo.md"; printf '### Acceptance criteria\n\n- [ ] first\n' > "$plan/tasks/L2.md"
git -C "$plan" add -A; git -C "$plan" commit -qm "add L2"
own_session "$TR/mr-session"
twt=$("$ZERO" claim L2); echo handoff > "$twt/h.txt"; git -C "$twt" add h.txt; git -C "$twt" commit -qm h
printf 'body\n' > "$("$ZERO" mr-body-path L2)"
printf '[{"number":3,"headRefOid":"%s","baseRefName":"release","state":"MERGED","url":"https://x/pull/3"}]' "$(git -C "$twt" rev-parse HEAD)" > "$STUB_GH_LIST"
"$ZERO" mr L2 "$twt" >/dev/null 2>&1; rc=$?
check "H1 hand-off merged onto another base: [?] box with its review note" "$rc $(git -C "$plan" show main:todo.md | grep -c '^- \[?\] L2') $(git -C "$plan" show main:tasks/L2.md | grep -c '^> Branches review needed .* request https://x/pull/3 merged into release, not main$')" "0 1 1"

cd "$TESTROOT"
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
