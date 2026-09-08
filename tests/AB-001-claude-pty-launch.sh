#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=97s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# AB-001-claude-pty-launch — claude's launch line (kaizero.sh:531) wraps claude in its own pty
# (script), independent of whatever stdio kaizero.sh itself inherited, so an unattended fleet
# launch (non-tty stdin) doesn't make claude exit early on end_turn and orphan a subagent it
# dispatched (a second SIGTERM trigger).
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it in every case
# this file defines.
# Tools beyond the shared prerequisites: script (macOS/BSD `script -q`, or util-linux `script -qc`).
# Folder under $TESTROOT: $TESTROOT/AB-001-claude-pty-launch
# Wall-clock budget: its longest Run command is `timeout 30` — allow that command at least 30s.

# Setup
TN="$TESTROOT/AB-001-claude-pty-launch"; mkdir -p "$TN/repo" "$TN/bin"
cd "$TN/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] AB1 x\n' > todo.md; git add -A; git commit -qm init

# AB1 — claude sees a real tty on stdin even when kaizero.sh's own stdin is not one
cd "$TN/repo"
cat > "$TN/bin/claude" <<STUB
#!/usr/bin/env bash
printf "%s" "\$([ -t 0 ] && echo yes || echo no)" > "$TN/ab1.tty_result"
echo "stub ran"
exit 0
STUB
chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" timeout 20 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x < /dev/null > "$TN/ab1.log" 2>&1
check "AB1 exit" "$?" "0"
# claude gets its own pty regardless of kaizero.sh's own non-tty stdin
check "AB1 tty result" "$(cat "$TN/ab1.tty_result" 2>/dev/null)" "yes"
# AB1 PASS — exit = 0, tty result = yes.

# AB3 — the util-linux `script -qc` branch quotes claude's whole argv into one string and back correctly
cd "$TN/repo"
# fake uname reporting Linux forces the util-linux branch deterministically, without real Linux
cat > "$TN/bin/uname" <<'FAKEUNAME'
#!/usr/bin/env bash
echo "Linux"
FAKEUNAME
chmod +x "$TN/bin/uname"
# fake `script` mimicking util-linux semantics: `-qc CMD FILE` runs CMD via a shell — real
# util-linux execs $SHELL or falls back to /bin/sh, which on a real Linux host is often dash, not
# bash, so the stub interprets via dash too rather than bash: a quoting scheme that only round-
# trips through bash's own extensions (e.g. `printf %q`'s `$'...'` ANSI-C quoting) must fail here
# the same way it would on a real host, not pass by accident. Errors loudly on any other invocation
# shape (e.g. the macOS `-q FILE cmd args...` form), so picking the wrong branch under a Linux
# uname shows up as a failure here, not a silent pass.
cat > "$TN/bin/script" <<'FAKESCRIPT'
#!/usr/bin/env bash
if [ "$1" = -qc ]; then
  exec dash -c "$2"
fi
echo "FAKE SCRIPT: unexpected invocation: $*" >&2
exit 99
FAKESCRIPT
chmod +x "$TN/bin/script"
cat > "$TN/bin/claude" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TN/ab3.args"
echo "stub ran"
exit 0
STUB
chmod +x "$TN/bin/claude"
PATH="$TN/bin:$PATH" timeout 20 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x < /dev/null > "$TN/ab3.log" 2>&1
# code 99 means the wrong branch fired
check "AB3 exit" "$?" "0"
# the JSON blob survived the round trip
check "AB3 got --settings" "$(sed -n '2p' "$TN/ab3.args" | grep -c '"hooks":{"Stop"')" "1"
check "AB3 got --session-id" "$(grep -A1 '^--session-id$' "$TN/ab3.args" | tail -1 | grep -cE '^[0-9a-f-]{36}$')" "1"
# the multi-line, quote- and backtick-laden prompt survived
check "AB3 prompt intact" "$(grep -c 'ALGORITHM (one Task, then end your turn)' "$TN/ab3.args")" "1"
# no stray backslashes from the quoting round trip
check "AB3 no escape leaks" "$(grep -cE '\\\\ |\\\\"' "$TN/ab3.args")" "0"
# AB3 PASS — exit = 0, got --settings = 1, got --session-id = 1, prompt intact = 1,
# no escape leaks = 0.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
