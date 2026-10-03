#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=120s
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# ISSUE-084-feedback-invitation — after the third Task a machine has landed, the exit report shows
# a feedback invitation right before the TOTAL panel; `--no-interviews` hides it for good; the
# per-machine state lives under $XDG_STATE_HOME/kaizero and survives everything but deletion.
# Needs real claude: no — a stub claude stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/ISSUE-084-feedback-invitation

# Setup
T="$TESTROOT/ISSUE-084-feedback-invitation"; mkdir -p "$T/repo" "$T/bin" "$T/nogit"
ST="$XDG_STATE_HOME/kaizero"
cat > "$T/bin/claude" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
printf '10\n' > "$GC/todos-seconds-main-PEER1"; printf '1\n' > "$GC/todos-done-main-PEER1"
exit 0
STUB
chmod +x "$T/bin/claude"
cd "$T/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] J1 x\n' > todo.md; git add -A; git commit -qm init
run() { PATH="$T/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$T/run.log" 2>&1; }
setcount() { mkdir -p "$ST"; printf '%s\n' "$1" > "$ST/landed-count"; }
resetstate() { [ -d "$ST" ] && find "$ST" -mindepth 1 -delete; return 0; }

# A1 — below three: no invitation; at three: invitation, immediately before the TOTAL panel
cd "$T/repo"; resetstate; setcount 2; run
check "A1 count 2 no invitation" "$(grep -c 'Claude Code loop slower' "$T/run.log")" "0"
setcount 3; run
check "A1 count 3 invitation" "$(grep -c 'Claude Code loop slower' "$T/run.log")" "1"
# plain mode (NO_COLOR): boxed, no escapes
check "A1 plain no escapes" "$(grep -c $'\033' "$T/run.log")" "0"
check "A1 hide command" "$(grep -c 'Not for you? Hide this message: kaizero.sh --no-interviews' "$T/run.log")" "1"
# box bottom, three blank lines (the message's two plus the panel's own), then the TOTAL top border
check "A1 blank lines before TOTAL" "$(awk '/Not for you/{f=1; next} f&&!b&&/^\+-+\+$/{b=NR} f&&/\| TOTAL/{print NR-b-2; exit}' "$T/run.log")" "3"

# A2 — --no-interviews: ok., exit 0, from a non-repo directory; the invitation then stays hidden
cd "$T/nogit"
out="$(bash "$SCRIPT" --no-interviews 2>&1)"; check "A2 reply" "$out" "ok."
bash "$SCRIPT" --no-interviews >/dev/null 2>&1; check "A2 exit" "$?" "0"
check "A2 hidden file" "$([ -e "$ST/interviews-hidden" ] && echo y)" "y"
cd "$T/repo"; run
check "A2 hidden invitation gone" "$(grep -c 'Claude Code loop slower' "$T/run.log")" "0"

# A3 — unwritable state: one-line error on stderr, no ok., non-zero
err="$(XDG_STATE_HOME=/dev/null/x bash "$SCRIPT" --no-interviews 2>&1 >/dev/null)"
check "A3 error lines" "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" "1"
XDG_STATE_HOME=/dev/null/x bash "$SCRIPT" --no-interviews >/dev/null 2>&1; rc=$?
check "A3 exit" "$([ "$rc" -ne 0 ] && echo nonzero)" "nonzero"

# A4 — sixteen concurrent landings leave the count at exactly 16 (the emitted zero.sh's own helpers)
resetstate; cd "$T/repo"; run
Z="$T/repo/.git/zero.sh"
{ printf 'FLOCK_BIN=flock\n'; sed -n '/^add_counter() {/,/^}/p;/^add_machine_landed() {/,/^}/p;/^kz_state_dir () /,/^}/p' "$Z"; } > "$T/fns.sh"
for _ in $(seq 16); do bash -c '. "$1"; add_machine_landed' _ "$T/fns.sh" & done; wait
check "A4 concurrent count" "$(cat "$ST/landed-count")" "16"
check "A4 state files" "$(find "$ST" -type f ! -name '*.lock' | wc -l | tr -d ' ')" "1"
# XDG unset: the default path is under $HOME
H="$T/home"; mkdir -p "$H"; env -u XDG_STATE_HOME HOME="$H" bash -c '. "$1"; add_machine_landed' _ "$T/fns.sh"
check "A4 default path" "$(cat "$H/.local/state/kaizero/landed-count")" "1"
# unwritable state costs the count, never the call
check "A4 fail-open" "$(XDG_STATE_HOME=/dev/null/x bash -c '. "$1"; add_machine_landed; echo $?' _ "$T/fns.sh")" "0"

# A5 — styled mode (pty, UTF-8, 256 colors): text aligned at column 5 once escapes are stripped
resetstate; setcount 3
cd "$T/repo"
PATH="$T/bin:$PATH" python3 - "$SCRIPT" > "$T/styled.raw" <<'PY'
import os, pty, sys
os.environ.pop("NO_COLOR", None)
os.environ.update(TERM="xterm-256color", LANG="en_US.UTF-8", KAIZERO_MAX_LOOPS="1")
pty.spawn(["bash", sys.argv[1], "--local-merge", "todo.md", "-t", "x"])
PY
sed -e $'s/\033\\[[0-9;?]*[A-Za-z]//g' -e $'s/\033(B//g' -e 's/\r$//' "$T/styled.raw" > "$T/styled.txt"
check "A5 question col 5" "$(grep -c '^  ❄ Is your Claude Code loop slower' "$T/styled.txt")" "1"
check "A5 aligned lines" "$(grep -cE "^    (I'm the Kaizero|in a free|We'll find|Let's talk|Or share|Not for you)" "$T/styled.txt")" "6"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1
