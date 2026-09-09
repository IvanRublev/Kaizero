#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=210s
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# L-001-exit-code-and-debug-file — claude's exit code + --debug-file. Restart/stop log lines
# carry claude's real exit code, and KAIZERO_DEBUG opts into a per-invocation --debug-file
# with no argv change when unset.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/L-001-exit-code-and-debug-file
#
# The reason line above each restart / MAX_LOOPS-stop line carries claude's real exit status
# (moved off the report line itself), so a hang and a clean exit are told apart without
# re-deriving them from timing. KAIZERO_DEBUG is the opt-in: set, every claude invocation
# gets its own --debug-file; unset, the argv is byte-identical to before. The stub echoes its
# own argv, which is how the argv claim is checked.

# Setup
TL="$TESTROOT/L-001-exit-code-and-debug-file"; mkdir -p "$TL/repo" "$TL/bin"
cat > "$TL/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
printf 'ARGV: %s\n' "$*"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$TL/bin/claude"
cd "$TL/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] L1 x\n' > todo.md; git add -A; git commit -qm init

# L1 — the code is above both lines, and it is claude's own
cd "$TL/repo"
PATH="$TL/bin:$PATH" STUB_EXIT=7 timeout 60 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge todo.md -t x > "$TL/code.log" 2>&1
# claude's status is reported, not adopted
check "L1 exit" "$?" "0"
check "L1 restart line" "$(grep -c 'Claude exited after 1 runs . restarting in' "$TL/code.log")" "1"
check "L1 stop line" "$(grep -c 'Claude exited after 2 runs . reached KAIZERO_MAX_LOOPS' "$TL/code.log")" "1"
# one above each of the two report lines
check "L1 code lines" "$(grep -c "Code 7 - claude's own exit status 7" "$TL/code.log")" "2"
PATH="$TL/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TL/zero.log" 2>&1
# an exit-0 stub reads 0, not a stale status
check "L1 clean code" "$(grep -c 'Code 0 - claude ended the turn normally' "$TL/zero.log")" "1"
# L1 PASS — exit = 0, restart line = 1, stop line = 1, code lines = 2, clean code = 1.

# L2 — --debug-file is opt-in, one file per invocation
cd "$TL/repo"
# unset is the default and changes nothing
check "L2 argv default" "$(grep -c -- '--debug-file' "$TL/zero.log")" "0"
# the pre-existing argv: flags, then the prompt, nothing added
check "L2 argv shape" "$(grep -c 'ARGV: --settings .* --permission-mode auto --name .* You are ONE of ' "$TL/zero.log")" "1"
PATH="$TL/bin:$PATH" KAIZERO_DEBUG=1 timeout 60 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge todo.md -t x > "$TL/debug.log" 2>&1
check "L2 debug exit" "$?" "0"
# <kind>-<base>-<instance>-<loop>, one per invocation
check "L2 argv debug" "$(grep -c -- '--debug-file .*/\.git/debug-main-[0-9A-F]*-[12]\.log' "$TL/debug.log")" "2"
# the loop number keeps a restart from truncating run 1's trace
check "L2 distinct paths" "$(grep -o -- '--debug-file [^ ]*' "$TL/debug.log" | sort -u | wc -l | tr -d ' ')" "2"
# L2 PASS — argv default = 0 with argv shape = 1, and debug exit = 0, argv debug = 2, distinct paths = 2.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
