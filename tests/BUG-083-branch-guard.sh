#!/usr/bin/env bash
# KAIZERO_TEST_ISOLATED=1
# KAIZERO_WALLCLOCK_BUDGET=120s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# BUG-083-branch-guard — the emitted PreToolUse hook refuses a Bash call that would move a Task
# worktree off its claim branch, and lets every other call through.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/BUG-083-branch-guard
# Wall-clock budget: under a minute
# Race note: none — the hook is run directly, no live fleet is touched, hence isolated only to
# keep its throwaway worktrees away from concurrent scenarios' CPU load.

TR="$TESTROOT/BUG-083-branch-guard"; mkdir -p "$TR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/claude"; chmod +x "$TR/bin/claude"
d="$TR/repo"; mkdir -p "$d/tasks"; cd "$d"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] TASK-1 x\n' > todo.md; printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/TASK-1.md
git add -A; git commit -qm init; git branch other
KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > "$TR/launch.out" 2>&1
G="$d/.git"; HOOK="$G/branch-guard-hook.sh"
TS="$TR/ts-main-task-TASK-1-abc1234"; TT="$TR/tt-main-task-TASK-1-def5678"
git worktree add -q -b main-task-TASK-1 "$TS" main
git worktree add -q -b main-task-TASK-1-tgt "$TT" main
git branch other2

# run_hook <cwd> <command> -> hook stdout (JSON as Claude Code sends it: one line, command escaped)
run_hook() {
  local esc; esc=$(printf '%s' "$2" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  printf '{"session_id":"s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" "$esc" | "$HOOK"
}
denied() { case "$(run_hook "$1" "$2")" in *'"permissionDecision":"deny"'*) echo deny;; *) echo pass;; esac; }

# A — emission and settings
check "A1 hook emitted, executable, parses" "$([ -x "$HOOK" ] && bash -n "$HOOK" && echo yes)" "yes"
check "A2 no temp left in the git dir" "$(ls "$G" | grep -c '\.tmp$')" "0"
check "A3 hook uses atomic_put's whole-file publish" "$(grep -c 'atomic_put "\$BRANCH_GUARD_HOOK"' "$REAL_SCRIPT")" "1"
SETTINGS=$(grep -o "PreToolUse" "$REAL_SCRIPT" | head -1)
check "A4 PreToolUse registered in the --settings JSON" "$SETTINGS" "PreToolUse"

# B — denied
out=$(run_hook "$TS" "git checkout main"); check "B1 checkout in Task worktree denied" "$(case "$out" in *'"permissionDecision":"deny"'*) echo deny;; esac)" "deny"
check "B1 reason names the claim branch" "$(case "$out" in *main-task-TASK-1*) echo yes;; esac)" "yes"
check "B1 reason points to zero.sh release" "$(case "$out" in *'zero.sh release'*) echo yes;; esac)" "yes"
check "B1 branch unchanged" "$(git -C "$TS" branch --show-current)" "main-task-TASK-1"
check "B2 cd into worktree" "$(denied "$d" "cd \"$TS\" && git checkout other")" "deny"
check "B3 git -C worktree" "$(denied "$d" "git -C \"$TS\" checkout other")" "deny"
check "B4 git switch" "$(denied "$TS" "git switch other")" "deny"
check "B5 git checkout -b" "$(denied "$TS" "git checkout -b newbranch")" "deny"
check "B6 checkout with silenced stderr" "$(denied "$TS" "git checkout -q other 2>/dev/null")" "deny"
check "B7 unresolved \$wt variable" "$(denied "$d" 'cd "$wt" && git checkout other')" "deny"
check "B8 target worktree checkout" "$(denied "$TT" "git checkout other")" "deny"
check "B9 target worktree via -C and switch" "$(denied "$d" "git -C $TT switch other")" "deny"
check "B10 after a leading command" "$(denied "$TS" "git status; git checkout other")" "deny"

# C — passes
check "C1 checkout -- path in Task worktree" "$(denied "$TS" "git checkout -- f")" "pass"
check "C2 git status" "$(denied "$TS" "git status")" "pass"
check "C3 git commit" "$(denied "$TS" "git commit -qm x")" "pass"
check "C4 git merge" "$(denied "$TS" "git merge other")" "pass"
check "C5 checkout branch in the main checkout" "$(denied "$d" "git checkout other")" "pass"
check "C6 switch in the main checkout" "$(denied "$d" "git switch other")" "pass"
check "C7 non-git command in Task worktree" "$(denied "$TS" "ls -la && cd sub")" "pass"
check "C8 branch ref restore of a path" "$(denied "$TS" "git checkout other -- f")" "pass"
check "C9 no output on pass" "$(run_hook "$TS" "git status" | wc -c | tr -d ' ')" "0"

cd "$TESTROOT"
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
