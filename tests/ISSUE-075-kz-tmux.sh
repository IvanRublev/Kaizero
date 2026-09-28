#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=90s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCENARIO_DIR/test-setup.sh"

# ISSUE-075-kz-tmux — kz-tmux.sh: argument validation, pane fan-out, verbose logging,
# mouse/remain-on-exit/status-bar options, the Ctrl-b Ctrl-c broadcast, and the
# client-detached teardown hook (local vs SSH_CONNECTION).
# Needs real claude: no
# Tools beyond the shared prerequisites: tmux
# Folder under $TESTROOT: $TESTROOT/ISSUE-075-kz-tmux
# Wall-clock budget: a couple of short `sleep`s inside tmux panes — well under 90s
#
# Hard rule: every tmux server this scenario touches is isolated via TMUX_TMPDIR, never the
# operator's default server.

command -v tmux >/dev/null || { echo "FATAL: tmux not on PATH — a prerequisite of this suite" >&2; exit 1; }

KZ="$REPO/kz-tmux.sh"
[ -x "$KZ" ] || { echo "FATAL: $KZ not found or not executable" >&2; exit 1; }

TK="$TESTROOT/ISSUE-075-kz-tmux"; mkdir -p "$TK"
# hard rule: isolate every tmux call this scenario makes (and every one kz-tmux.sh itself makes)
# to a scratch server — unset TMUX first, since tmux prefers the socket embedded in $TMUX over
# TMUX_TMPDIR whenever $TMUX is set (the case when this test's own shell runs nested in tmux).
# A short, dedicated dir: tmux's unix socket path (TMUX_TMPDIR/tmux-<uid>/default) must stay
# under the platform's sun_path limit (~104 bytes on macOS) — $TK, nested under $TESTROOT's own
# mktemp path, is already too long for that on its own.
unset TMUX
TMUX_SOCK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kzt.XXXXXX")"
export TMUX_TMPDIR="$TMUX_SOCK_DIR"
export XDG_STATE_HOME="$TK/xdg-state"

# waits until tmux reports SESSION as up, or gives up after ~5s
wait_session(){ local s="$1" i=0; while ! tmux has-session -t "$s" 2>/dev/null; do
  i=$((i+1)); [ "$i" -ge 50 ] && return 1; sleep 0.1; done; return 0; }

# T0 — the script lives at the repo root, next to kaizero.sh
check "T0 exists" "$([ -x "$KZ" ] && echo yes || echo NO)" "yes"

# T1 — no arguments at all: usage on stderr, non-zero exit, no session created
d="$TK/no-args"; mkdir -p "$d"
( cd "$d" && bash "$KZ" >out.log 2>err.log ); rc=$?
check "T1 no-args exit non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo NO)" "yes"
check "T1 no-args usage on stderr" "$(grep -qi usage "$d/err.log" && echo yes || echo NO)" "yes"

# T2 — one argument (count, no command): usage on stderr, non-zero exit
d="$TK/one-arg"; mkdir -p "$d"
( cd "$d" && bash "$KZ" 3 >out.log 2>err.log ); rc=$?
check "T2 one-arg exit non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo NO)" "yes"
check "T2 one-arg usage on stderr" "$(grep -qi usage "$d/err.log" && echo yes || echo NO)" "yes"

# T3 — non-numeric pane count: usage on stderr, non-zero exit
d="$TK/nonnumeric-count"; mkdir -p "$d"
( cd "$d" && bash "$KZ" abc "echo hi" >out.log 2>err.log ); rc=$?
check "T3 non-numeric count exit non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo NO)" "yes"
check "T3 non-numeric count usage on stderr" "$(grep -qi usage "$d/err.log" && echo yes || echo NO)" "yes"

# T4 — zero pane count: usage on stderr, non-zero exit
d="$TK/zero-count"; mkdir -p "$d"
( cd "$d" && bash "$KZ" 0 "echo hi" >out.log 2>err.log ); rc=$?
check "T4 zero count exit non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo NO)" "yes"
check "T4 zero count usage on stderr" "$(grep -qi usage "$d/err.log" && echo yes || echo NO)" "yes"

check "T5 no stray sessions from arg-error runs" "$(tmux list-sessions 2>/dev/null | wc -l | tr -d ' ')" "0"

# waits until SESSION has at least N panes, or gives up after ~5s
wait_panes(){ local s="$1" n="$2" i=0
  while [ "$(tmux list-panes -t "$s" 2>/dev/null | wc -l | tr -d ' ')" -lt "$n" ]; do
    i=$((i+1)); [ "$i" -ge 50 ] && return 1; sleep 0.1; done; return 0; }

# runs kz-tmux.sh detached from a real terminal, in its own dir under $TK. kz-tmux.sh names its
# session kz-<basename of cwd>-<its own pid>, so SESSION is computed the same way the caller's
# `wait` loop must: launch in the background, capture the backgrounded subshell's own $! (which
# is the pid bash itself assigns the `bash "$KZ" ...` process since no intermediate wrapper runs).
run_kz(){
  local dir="$1"; shift
  mkdir -p "$dir"
  ( cd "$dir" && exec bash "$KZ" "$@" >out.log 2>err.log </dev/null ) &
  echo $!
}

# T6 — N=1 opens exactly one pane
d="$TK/one-pane"; mkdir -p "$d"
pid="$(run_kz "$d" 1 "sh -c 'sleep 5'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
check "T6 N=1 opens exactly 1 pane" "$(tmux list-panes -t "$SESSION" 2>/dev/null | wc -l | tr -d ' ')" "1"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T7 — N=3 (between 2 and 12) opens exactly 3 tiled panes
d="$TK/three-panes"; mkdir -p "$d"
pid="$(run_kz "$d" 3 "sh -c 'sleep 5'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
wait_panes "$SESSION" 3 || true
check "T7 N=3 opens exactly 3 panes" "$(tmux list-panes -t "$SESSION" 2>/dev/null | wc -l | tr -d ' ')" "3"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T8 — mouse is enabled for the session (mouse click pane-switching depends on this option)
d="$TK/mouse"; mkdir -p "$d"
pid="$(run_kz "$d" 2 "sh -c 'sleep 5'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
wait_panes "$SESSION" 2 || true
check "T8 mouse option on" "$(tmux show-options -t "$SESSION" mouse | awk '{print $2}')" "on"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T9 — a verbose flag (-v/-vv/-vvv) writes tmux debug log files under XDG_STATE_HOME/kz-tmux
d="$TK/verbose"; mkdir -p "$d"
pid="$(run_kz "$d" -vv 1 "sh -c 'sleep 3'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
sleep 0.3
check "T9 -vv writes log files" "$([ -d "$XDG_STATE_HOME/kz-tmux" ] && [ -n "$(find "$XDG_STATE_HOME/kz-tmux" -type f 2>/dev/null)" ] && echo yes || echo NO)" "yes"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T10 — without a verbose flag, no log files are written anywhere
rm -rf "${XDG_STATE_HOME:?}/kz-tmux"
d="$TK/no-verbose"; mkdir -p "$d"
pid="$(run_kz "$d" 1 "sh -c 'sleep 3'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
sleep 0.3
check "T10 no verbose flag writes no log files" "$([ -d "$XDG_STATE_HOME/kz-tmux" ] && echo NO || echo yes)" "yes"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T11 — a pane's command exiting non-zero prints its exit code and the pane stays visible
d="$TK/nonzero-exit"; mkdir -p "$d"
pid="$(run_kz "$d" 1 "sh -c 'exit 7'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
sleep 0.5
check "T11 pane prints exit code" "$(tmux capture-pane -t "$SESSION" -p | grep -qc '\[exit 7\]' && echo yes || echo NO)" "yes"
check "T11 pane stays visible (remain-on-exit)" "$(tmux list-panes -t "$SESSION" 2>/dev/null | wc -l | tr -d ' ')" "1"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T12 — status bar shows the green Ctrl-b Ctrl-c help line, naming the 5s repeat window
d="$TK/statusbar"; mkdir -p "$d"
pid="$(run_kz "$d" 1 "sh -c 'sleep 3'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
SR="$(tmux show-options -t "$SESSION" status-right)"
check "T12 status-right names Ctrl-b Ctrl-c" "$(printf '%s' "$SR" | grep -qc 'Ctrl-b Ctrl-c' && echo yes || echo NO)" "yes"
check "T12 status-right names 5s repeat window" "$(printf '%s' "$SR" | grep -qc '5s' && echo yes || echo NO)" "yes"
check "T12 status-right is green" "$(printf '%s' "$SR" | grep -qc 'fg=green' && echo yes || echo NO)" "yes"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T13 — Ctrl-b Ctrl-c broadcasts Ctrl-c to every pane; a second Ctrl-c within 5s (no Ctrl-b)
# broadcasts again, since the binding is repeatable within the session's repeat-time.
# `tmux send-keys` writes bytes straight into a pane's pty, bypassing tmux's own key-table
# lookup entirely — it never triggers a prefix binding. Only an attached client's keystrokes
# go through key-table processing, so this drives the prefix from a real attached client: a
# pty-backed `tmux attach`, fed raw bytes via Python's pty module (python3 is a suite prerequisite).
d="$TK/broadcast"; mkdir -p "$d"
cat >"$d/catch.sh" <<'EOF'
#!/bin/sh
f="$1"; i=0
trap 'i=$((i+1)); echo $i >>"$f"' INT
while :; do sleep 0.1; done
EOF
chmod +x "$d/catch.sh"
pid="$(run_kz "$d" 2 "$d/catch.sh $d/got")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
wait_panes "$SESSION" 2 || true
sleep 0.3

# tmux's repeat-after-prefix state (what lets a bare Ctrl-c repeat the binding within the 5s
# window) is tracked per client, so both key presses below must come from the SAME attached
# client — a fresh reattach would reset it. Keeps one pty-backed client attached, driven by
# key-literal commands written to a fifo (one Python bytes-literal per line, "quit" to detach
# and exit), so the test can check state between presses.
FIFO="$d/keys.fifo"; mkfifo "$FIFO"
cat <<'PY' >"$d/client.py"
import pty, os, sys, time
session = sys.argv[1]
cpid, fd = pty.fork()
if cpid == 0:
    os.execvp("tmux", ["tmux", "attach", "-t", session])
else:
    time.sleep(0.5)
    for line in sys.stdin:
        line = line.rstrip("\n")
        if line == "quit":
            break
        os.write(fd, eval(line))
        time.sleep(0.2)
    os.write(fd, b'\x02d')  # Ctrl-b d: detach so the attach process exits cleanly
    time.sleep(0.3)
    try:
        os.kill(cpid, 15)
    except ProcessLookupError:
        pass
PY
python3 "$d/client.py" "$SESSION" <"$FIFO" &
CLIENT_PY=$!
exec 3>"$FIFO"

# waits until $d/got has at least N lines, or gives up after ~3s. Missing file counts as 0 lines
# rather than erroring `-lt`'s comparison (which `while` would read as "condition false" and
# return immediately, mistaking "not created yet" for "already satisfied").
wait_got(){ local n="$1" i=0 cur
  while :; do
    cur=0; [ -f "$d/got" ] && cur="$(wc -l <"$d/got" | tr -d ' ')"
    [ "$cur" -ge "$n" ] && return 0
    i=$((i+1)); [ "$i" -ge 30 ] && return 1; sleep 0.1
  done; }

printf "%s\n" "b'\x02\x03'" >&3  # Ctrl-b Ctrl-c
wait_got 2 || true
check "T13 first Ctrl-b Ctrl-c reaches both panes" "$(wc -l <"$d/got" 2>/dev/null | tr -d ' ')" "2"
printf "%s\n" "b'\x03'" >&3     # bare Ctrl-c, within the 5s repeat window
wait_got 4 || true
check "T13 second bare Ctrl-c (within 5s) reaches both panes again" "$(wc -l <"$d/got" 2>/dev/null | tr -d ' ')" "4"
printf "quit\n" >&3
exec 3>&-
wait "$CLIENT_PY" 2>/dev/null || true

# attaches a pty-backed client to SESSION, waits, then closes the pty out from under it — the
# same disconnection a closed terminal window causes — and gives the client-detached hook time
# to fire before returning.
attach_then_drop(){
  local session="$1"
  python3 - "$session" <<'PY'
import pty, os, sys, time
session = sys.argv[1]
cpid, fd = pty.fork()
if cpid == 0:
    os.execvp("tmux", ["tmux", "attach", "-t", session])
else:
    time.sleep(0.5)
    os.close(fd)
    try:
        os.kill(cpid, 9)
    except ProcessLookupError:
        pass
    os.waitpid(cpid, 0)
    time.sleep(0.5)
PY
}

# T14 — local (no SSH_CONNECTION): closing the attached client's terminal kills the session
d="$TK/local-detach"; mkdir -p "$d"
( unset SSH_CONNECTION; pid="$(run_kz "$d" 1 "sh -c 'sleep 5'")"; echo "$pid" >"$d/pid" )
pid="$(cat "$d/pid")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
attach_then_drop "$SESSION"
check "T14 local terminal close kills the session" "$(tmux has-session -t "$SESSION" 2>/dev/null && echo yes || echo NO)" "NO"

# T15 — SSH_CONNECTION set: a dropped connection leaves the session running
d="$TK/ssh-detach"; mkdir -p "$d"
( export SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22"; pid="$(run_kz "$d" 1 "sh -c 'sleep 20'")"; echo "$pid" >"$d/pid" )
pid="$(cat "$d/pid")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
attach_then_drop "$SESSION"
check "T15 SSH-dropped connection leaves the session running" "$(tmux has-session -t "$SESSION" 2>/dev/null && echo yes || echo NO)" "yes"
check "T15 session listed by tmux ls" "$(tmux ls 2>/dev/null | grep -qc "^${SESSION}:" && echo yes || echo NO)" "yes"
attach_then_drop "$SESSION"
check "T15 tmux attach reattaches" "$(tmux has-session -t "$SESSION" 2>/dev/null && echo yes || echo NO)" "yes"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T16 — absence check: no code path in kz-tmux.sh calls tmux kill-server
check "T16 kz-tmux.sh never calls tmux kill-server" "$(grep -c 'kill-server' "$KZ" | tr -d ' ')" "0"
check "T16 no other test file calls tmux kill-server" "$(grep -rl 'kill-server' "$REPO/tests" 2>/dev/null | grep -vc "$SCENARIO_DIR/ISSUE-075-kz-tmux.sh")" "0"

rm -rf "$TMUX_SOCK_DIR"
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
