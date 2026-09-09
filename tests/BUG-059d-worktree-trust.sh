#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=85s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# BUG-059d-worktree-trust — the --settings payload's autoMode.environment and
# permissions.additionalDirectories name $WT_PARENT (alongside $COORD_ROOT and the literal
# "$defaults") in every launch layout, so a claimed worktree's edits don't hit the auto-mode
# classifier or the permissions layer as untrusted.
# Needs real claude: no — a stub claude on a scenario-scoped PATH echoes its own argv instead.
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/BUG-059d-worktree-trust

TT="$TESTROOT/BUG-059d-worktree-trust"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktodo(){ ( cd "$1"; echo '- [ ] G1 noop' > todo.md; mkdir -p tasks
  printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/G1.md; git add -A; git commit -qm todo ); }

mkdir -p "$TT/bin"
cat > "$TT/bin/claude" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
printf '%s\n' "\$@" > "$TT/\$KAIZERO_TEST_ARGS_TAG.args"
exit 0
EOF
chmod +x "$TT/bin/claude"

settings_json(){ grep -A1 '^--settings$' "$1" | tail -1; }
check_layout(){
  local label; label="$1"
  local launch_dir; launch_dir="$2"
  local todo_arg; todo_arg="$3"
  local wt_parent; wt_parent="$4"
  local coord_root; coord_root="$5"
  local log; log="$TT/$label.log"
  ( cd "$launch_dir"; PATH="$TT/bin:$PATH" KAIZERO_TEST_ARGS_TAG="$label" timeout 20 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge "$todo_arg" -t x < /dev/null > "$log" 2>&1 )
  local j; j="$(settings_json "$TT/$label.args")"
  check "$label has hooks.Stop" "$(printf '%s' "$j" | grep -c '"hooks":{"Stop"')" "1"
  check "$label has \$defaults" "$(printf '%s' "$j" | grep -c '"environment":\["\$defaults"')" "1"
  check "$label environment has WT_PARENT" "$(printf '%s' "$j" | grep -Fc "\"$wt_parent\"")" "1"
  check "$label environment has COORD_ROOT" "$(printf '%s' "$j" | grep -Fc "\"$coord_root\"")" "1"
  check "$label additionalDirectories has WT_PARENT" "$(printf '%s' "$j" | grep -Fc "\"additionalDirectories\":[\"$wt_parent\"]")" "1"
}

# same-repository layout — WT_PARENT is the coordination/target repo's own dirname
mkrepo "$TT/same"; mktodo "$TT/same"
check_layout same "$TT/same" todo.md "$(dirname "$TT/same")" "$TT/same"

# non-nested MR layout — two unrelated checkouts, WT_PARENT beside the target
mkrepo "$TT/code"; mkrepo "$TT/plan"; mktodo "$TT/plan"
check_layout nonnested "$TT/code" "$TT/plan/todo.md" "$(dirname "$TT/code")" "$TT/plan"

# nested MR layout — target inside coordination, WT_PARENT beside the outer
mkrepo "$TT/plan10"; mkdir -p "$TT/plan10/code"
( cd "$TT/plan10/code"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init )
( cd "$TT/plan10"; echo 'code/' >> .gitignore; git add .gitignore; git commit -qm ignore-code )
mktodo "$TT/plan10"
check_layout nested "$TT/plan10/code" "$TT/plan10/todo.md" "$(dirname "$TT/plan10")" "$TT/plan10"

# BUG-059d PASS — every layout's --settings JSON carries hooks.Stop, the literal "$defaults"
# entry, $WT_PARENT and $COORD_ROOT in autoMode.environment, and $WT_PARENT in
# permissions.additionalDirectories.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
