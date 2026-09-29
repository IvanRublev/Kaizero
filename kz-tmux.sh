#!/usr/bin/env bash
# Run a kaizero command N times in the current folder, each instance in its own tiled tmux pane.
# Usage: kz-tmux.sh [-v|-vv|-vvv] [-t <wait_sec>] <num-terminals> <kaizero-command...>
#
# Pass a verbose flag -vvv to have tmux write its own debug logs under
# ${XDG_STATE_HOME:-$HOME/.local/state}/kz-tmux; by default no logs are written.
#
# Pane switching: mouse click, or Ctrl-b o (next pane), Ctrl-b ; (last active pane), Ctrl-b arrows.
# Stop all panes: Ctrl-b then Ctrl-c broadcasts Ctrl-c to every pane in the session;
# repeatable, so Ctrl-c can be pressed again within 5s without another Ctrl-b.
#
# Panes output remain visible on-exit until you stop them.
# Locally closing a terminal window kills the whole session, that eventually stops all panes.
# Over SSH, the session survives a dropped connection instead (SSH_CONNECTION set).
# To reconnect and manage it:
#   tmux ls
#   tmux attach -t kz-<dirname>-<pid>
#   tmux kill-session -t kz-<dirname>-<pid>
set -euo pipefail

VERSION="0.0.1"
echo "kz-tmux.sh v$VERSION"

USAGE="usage: kz-tmux.sh [-v|-vv|-vvv] [-t <wait_sec>] <num-terminals> <kaizero-command...> (wait_sec: 0-900, default of 3)"

VERBOSE=()
if [ "$#" -ge 1 ] && [[ "$1" =~ ^-v+$ ]]; then
  VERBOSE=("$1")
  shift
fi

WAIT_SEC=3
if [ "$#" -ge 1 ] && [ "$1" = "-t" ]; then
  if [ "$#" -lt 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -gt 900 ]; then
    echo "$USAGE" >&2
    exit 1
  fi
  WAIT_SEC="$2"
  shift 2
fi

if [ "$#" -lt 2 ]; then
  echo "$USAGE" >&2
  exit 1
fi

COUNT="$1"
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
  echo "$USAGE" >&2
  exit 1
fi
shift
CMD="$*; ec=\$?; echo; echo \"[exit \$ec]\""

SESSION="kz-$(basename "$PWD")-$$"
ORIG_PWD="$PWD"
LOG_DIR="$PWD"
if [ "${#VERBOSE[@]}" -gt 0 ]; then
  LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kz-tmux"
  mkdir -p "$LOG_DIR"
fi

STOP_ALL_STATUS='Ctrl-b Ctrl-c: sends stop signal to all panes (Ctrl-c is repeatable within 5s)'

(cd "$LOG_DIR" && tmux "${VERBOSE[@]}" new-session -d -s "$SESSION" -n "kz" -c "$ORIG_PWD" "$CMD" \; \
  set-option -t "$SESSION" mouse on \; \
  set-option -t "$SESSION" repeat-time 5000 \; \
  set-window-option -t "$SESSION" remain-on-exit on \; \
  set-option -t "$SESSION" status-right-length 90 \; \
  set-option -t "$SESSION" status-right "$STOP_ALL_STATUS" \; \
  bind-key -r C-c run-shell 'tmux list-panes -t "$(tmux display-message -p "#{session_name}")" -F "##{pane_id}" | xargs -I{} tmux send-keys -t {} C-c')

if [ -z "${SSH_CONNECTION:-}" ]; then
  tmux set-hook -t "$SESSION" client-detached "kill-session -t $SESSION"
fi
# Split in the background so the client attaches immediately and the panes
# become visible as each batch opens, instead of after the last one.
{
  launched=1
  i=2
  while [ "$i" -le "$COUNT" ]; do
    tmux split-window -t "$SESSION" "$CMD"
    tmux select-layout -t "$SESSION" tiled
    launched=$((launched + 1))
    i=$((i + 1))
    # pause after every 2nd pane (batch size 2), until the last batch has opened
    if [ "$WAIT_SEC" -gt 0 ] && [ $((launched % 2)) -eq 0 ] && [ "$launched" -lt "$COUNT" ]; then
      tmux set-option -t "$SESSION" status-right "#[fg=black,bg=colour244]Launching $launched of $COUNT instances...#[default]"
      sleep "$WAIT_SEC"
    fi
  done
  if [ "$WAIT_SEC" -gt 0 ]; then
    tmux set-option -t "$SESSION" status-right "$STOP_ALL_STATUS"
  fi
} &

(cd "$LOG_DIR" && tmux "${VERBOSE[@]}" attach -t "$SESSION")
