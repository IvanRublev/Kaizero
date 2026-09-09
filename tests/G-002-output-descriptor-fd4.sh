#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=85s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCENARIO_DIR/test-setup.sh"

# G-002-output-descriptor-fd4 — claude's output descriptor (fd 4). Deterministic. claude writes
# to fd 4 so a captured run still gets the ❄ reports without the TUI; proves the no-tty fallback
# to stdout and, via a pty, that the TUI/report split actually holds both ways.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: script(1) (it supplies the pty for G2.2)
# Folder under $TESTROOT: $TESTROOT/G-002-output-descriptor-fd4, $TESTROOT/G-002-output-descriptor-fd4-2
# Wall-clock budget: its longest Run command is `timeout 30` — allow that command at least 30s
#
# claude writes to fd 4 so `kaizero.sh … | tee run.log` logs the ❄ reports without the TUI.
# Only the fallback is deterministic here: with stdin off the terminal there is no tty to split
# to, so fd 4 must fall back to plain stdout and the stub's bytes must still appear in the
# captured stream. The split itself needs a pty — G2.2 supplies one via script(1).

# G2.1 — fd 4 fallback (no tty)
TG="$TESTROOT/G-002-output-descriptor-fd4"; mkdir -p "$TG/repo" "$TG/bin"
cat > "$TG/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo "STUB-CLAUDE-MARKER"
exit 0
EOF
chmod +x "$TG/bin/claude"
cd "$TG/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] G1 x\n' > todo.md; git add -A; git commit -qm init
# stdin off the terminal: fd 4 has no tty to split to and must fall back to stdout
env PATH="$TG/bin:$PATH" KAIZERO_MAX_LOOPS=1 \
  timeout 30 bash "$SCRIPT" --local-merge todo.md -t x > "$TG/run.log" 2>&1 < /dev/null || true
# fd 4 fell back to stdout
check "G2.1 stub output kept" "$(grep -c 'STUB-CLAUDE-MARKER' "$TG/run.log")" "1"
_v="$(grep -c 'Kaizero' "$TG/run.log")"; check "G2.1 own output kept" "$([ "$_v" -ge 1 ] && echo yes || echo no)" "yes"
# G2.1 PASS — both counts as stated: with stdin not a terminal the [ -t 0 ] probe fails, fd 4 is
# a dup of stdout, and no scenario that captures output loses stub-claude bytes. Redirecting
# stdin explicitly matters — run from a terminal without < /dev/null, the probe succeeds and the
# stub's bytes go to the terminal by design, which is the whole point of the split.

# G2.2 — the split itself (automated, script(1) supplies the pty)
# The operator's situation is stdin on a terminal, stdout on a pipe. script(1) allocates a pty
# and logs everything crossing it, so running the documented pipe form under it captures both
# sides at once: fd 4 lands in the typescript, Kaizero's own stdout in the pipe capture. The
# two script argument orders (BSD positional, util-linux -c) are picked by a helper, so no one
# has to choose.
TG="$TESTROOT/G-002-output-descriptor-fd4-2"; mkdir -p "$TG/repo" "$TG/bin"
cat > "$TG/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
if [ -t 0 ]; then a=yes; else a=no; fi
if [ -t 1 ]; then b=yes; else b=no; fi
echo "STUB TTY0=$a TTY1=$b"
printf 'TUI-FRAME \033[1mbold\033[0m\n'
exit 0
EOF
chmod +x "$TG/bin/claude"
cd "$TG/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] G2 x\n' > todo.md; git add -A; git commit -qm init
# BSD `script -q FILE CMD...` vs util-linux `script -q -c CMD FILE` — detect, don't choose.
pty() { if script --version 2>&1 | grep -qi util-linux
        then script -qec "$1" "$2"; else script -q "$2" bash -c "$1"; fi; }
export PATH="$TG/bin:$PATH"     # inherited by the pty child — keeps the command string quote-free
pty "KAIZERO_MAX_LOOPS=1 bash '$SCRIPT' --local-merge todo.md -t x 2>&1 | { trap '' INT; tee '$TG/pipe.log'; }" \
    "$TG/typescript" >/dev/null 2>&1
tr -d '\r' < "$TG/typescript" > "$TG/tty.log"       # pty writes CRLF; strip before matching
check "G2.2 stub sees ttys" "$(grep -o 'STUB TTY0=[a-z]* TTY1=[a-z]*' "$TG/tty.log" | head -1)" "STUB TTY0=yes TTY1=yes"
_v="$(grep -c 'TUI-FRAME' "$TG/tty.log")"; check "G2.2 TUI on tty" "$([ "$_v" -ge 1 ] && echo yes || echo no)" "yes"
check "G2.2 TUI not in pipe" "$(grep -c 'TUI-FRAME' "$TG/pipe.log")" "0"
_v="$(grep -c 'Execution stats' "$TG/pipe.log")"; check "G2.2 report in pipe" "$([ "$_v" -ge 1 ] && echo yes || echo no)" "yes"
check "G2.2 no escapes" "$(grep -c $'\033' "$TG/pipe.log")" "0"

# The other direction. Under tee the report reaches BOTH the file and the terminal — that is
# what tee is for — so "own output stays off the tty" can only be asserted on the redirect form,
# where stdout is the file alone. fd 4 still splits the TUI to the terminal.
pty "KAIZERO_MAX_LOOPS=1 bash '$SCRIPT' --local-merge todo.md -t x > '$TG/redir.log' 2>&1" \
    "$TG/typescript2" >/dev/null 2>&1
tr -d '\r' < "$TG/typescript2" > "$TG/tty2.log"
_v="$(grep -c 'Execution stats' "$TG/redir.log")"; check "G2.2 report in file" "$([ "$_v" -ge 1 ] && echo yes || echo no)" "yes"
check "G2.2 report off tty" "$(grep -c 'Execution stats' "$TG/tty2.log")" "0"
_v="$(grep -c 'TUI-FRAME' "$TG/tty2.log")"; check "G2.2 TUI still tty" "$([ "$_v" -ge 1 ] && echo yes || echo no)" "yes"
# G2.2 PASS — all eight as stated. stub sees ttys = yes yes proves fd 4 is a real terminal
# descriptor (a dup of stdin), not a pipe. The split is asserted in both directions: claude's
# TUI-FRAME reaches the terminal and never the capture file, and Kaizero's own ❄ report
# reaches the capture file and — on the redirect form, where tee is not echoing it back — never
# the terminal. No escape byte reaches the file.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
