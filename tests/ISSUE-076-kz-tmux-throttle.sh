#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCENARIO_DIR/test-setup.sh"

# ISSUE-076-kz-tmux-throttle — kz-tmux.sh: -t batching of pane launches, default throttle,
# -t 0 opt-out, argument validation, and the status-right launch-progress line.
# Needs real claude: no
# Tools beyond the shared prerequisites: tmux
# Folder under $TESTROOT: $TESTROOT/ISSUE-076-kz-tmux-throttle
# Wall-clock budget: a handful of ~1s throttle waits — well under 60s
#
# Hard rule: every tmux server this scenario touches is isolated via TMUX_TMPDIR, never the
# operator's default server.

command -v tmux >/dev/null || { echo "FATAL: tmux not on PATH — a prerequisite of this suite" >&2; exit 1; }

KZ="$REPO/kz-tmux.sh"
[ -x "$KZ" ] || { echo "FATAL: $KZ not found or not executable" >&2; exit 1; }

TK="$TESTROOT/ISSUE-076-kz-tmux-throttle"; mkdir -p "$TK"
unset TMUX
TMUX_SOCK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kzt2.XXXXXX")"
export TMUX_TMPDIR="$TMUX_SOCK_DIR"
export XDG_STATE_HOME="$TK/xdg-state"

wait_session(){ local s="$1" i=0; while ! tmux has-session -t "$s" 2>/dev/null; do
  i=$((i+1)); [ "$i" -ge 50 ] && return 1; sleep 0.1; done; return 0; }
wait_panes(){ local s="$1" n="$2" i=0
  while [ "$(tmux list-panes -t "$s" 2>/dev/null | wc -l | tr -d ' ')" -lt "$n" ]; do
    i=$((i+1)); [ "$i" -ge 100 ] && return 1; sleep 0.1; done; return 0; }

run_kz(){
  local dir="$1"; shift
  mkdir -p "$dir"
  ( cd "$dir" && exec bash "$KZ" "$@" >out.log 2>err.log </dev/null ) &
  echo $!
}

# T1 — `-t <wait_sec>` is accepted as a flag before the mandatory pane count: `-t 0 2 <cmd>`
# opens a session with 2 panes (proves the flag itself is recognized and consumed).
d="$TK/t-flag-accepted"; mkdir -p "$d"
pid="$(run_kz "$d" -t 0 2 "sh -c 'sleep 3'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
wait_panes "$SESSION" 2 || true
check "T1 -t 0 2 <cmd> opens exactly 2 panes" "$(tmux list-panes -t "$SESSION" 2>/dev/null | wc -l | tr -d ' ')" "2"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T2 — wait_sec out of range (901) or non-numeric: usage on stderr, non-zero exit, no session
d="$TK/bad-range"; mkdir -p "$d"
( cd "$d" && bash "$KZ" -t 901 2 "sh -c 'sleep 1'" >out.log 2>err.log ); rc=$?
check "T2 out-of-range wait_sec exit non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo NO)" "yes"
check "T2 out-of-range wait_sec usage on stderr" "$(grep -qi usage "$d/err.log" && echo yes || echo NO)" "yes"
d="$TK/bad-nonnumeric"; mkdir -p "$d"
( cd "$d" && bash "$KZ" -t abc 2 "sh -c 'sleep 1'" >out.log 2>err.log ); rc=$?
check "T2 non-numeric wait_sec exit non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo NO)" "yes"
check "T2 non-numeric wait_sec usage on stderr" "$(grep -qi usage "$d/err.log" && echo yes || echo NO)" "yes"
check "T2 no stray sessions from arg-error runs" "$(tmux list-sessions 2>/dev/null | wc -l | tr -d ' ')" "0"

# T3 — usage line documents -t, its 0-900 range, and its default of 3
d="$TK/usage-text"; mkdir -p "$d"
( cd "$d" && bash "$KZ" >out.log 2>err.log ) || true
check "T3 usage documents -t flag" "$(grep -qi -- '-t' "$d/err.log" && echo yes || echo NO)" "yes"
check "T3 usage documents 0-900 range" "$(grep -qc '0-900' "$d/err.log" && echo yes || echo NO)" "yes"
check "T3 usage documents default of 3" "$(grep -qc 'default of 3' "$d/err.log" && echo yes || echo NO)" "yes"

# T4 — default (-t omitted), N=4: batches of 2 with a ~3s gap between batches
d="$TK/default-throttle"; mkdir -p "$d"
start=$(date +%s)
pid="$(run_kz "$d" 4 "sh -c 'sleep 8'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
wait_panes "$SESSION" 2 || true
mid=$(date +%s)
check "T4 first batch of 2 opens promptly" "$([ $((mid - start)) -lt 3 ] && echo yes || echo NO)" "yes"
wait_panes "$SESSION" 4 || true
finish=$(date +%s)
check "T4 second batch after ~3s gap" "$([ $((finish - mid)) -ge 2 ] && echo yes || echo NO)" "yes"
check "T4 all 4 panes opened" "$(tmux list-panes -t "$SESSION" 2>/dev/null | wc -l | tr -d ' ')" "4"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T5 — -t <wait_sec> with wait_sec=1, N=3: batches of 2 with ~1s gap
d="$TK/custom-wait"; mkdir -p "$d"
start=$(date +%s)
pid="$(run_kz "$d" -t 1 3 "sh -c 'sleep 5'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
wait_panes "$SESSION" 3 || true
finish=$(date +%s)
check "T5 -t 1 with N=3 completes with a real gap" "$([ $((finish - start)) -ge 1 ] && echo yes || echo NO)" "yes"
check "T5 all 3 panes opened" "$(tmux list-panes -t "$SESSION" 2>/dev/null | wc -l | tr -d ' ')" "3"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T6 — -t 0: all N panes open back-to-back, no pause
d="$TK/no-throttle"; mkdir -p "$d"
start=$(date +%s)
pid="$(run_kz "$d" -t 0 5 "sh -c 'sleep 5'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
wait_panes "$SESSION" 5 || true
finish=$(date +%s)
check "T6 -t 0 opens all panes fast (no pause)" "$([ $((finish - start)) -lt 2 ] && echo yes || echo NO)" "yes"
check "T6 all 5 panes opened" "$(tmux list-panes -t "$SESSION" 2>/dev/null | wc -l | tr -d ' ')" "5"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T7 — a single pane (N=1) with -t <wait_sec> opens immediately, no pause
d="$TK/single-pane"; mkdir -p "$d"
start=$(date +%s)
pid="$(run_kz "$d" -t 5 1 "sh -c 'sleep 3'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
finish=$(date +%s)
check "T7 N=1 opens immediately despite -t" "$([ $((finish - start)) -lt 2 ] && echo yes || echo NO)" "yes"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T8 — N=2 with -t <wait_sec> opens both as one batch, no pause between them
d="$TK/two-pane-batch"; mkdir -p "$d"
start=$(date +%s)
pid="$(run_kz "$d" -t 5 2 "sh -c 'sleep 3'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
wait_panes "$SESSION" 2 || true
finish=$(date +%s)
check "T8 N=2 opens both panes without a pause" "$([ $((finish - start)) -lt 2 ] && echo yes || echo NO)" "yes"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T9 — absence check: with -t 0, no sleep call anywhere in the pane-launch sequence
check "T9 the WAIT_SEC sleep is guarded by WAIT_SEC -gt 0" \
  "$(grep -B2 'sleep "\$WAIT_SEC"' "$KZ" | grep -qc 'WAIT_SEC" -gt 0' && echo yes || echo NO)" "yes"

# T10 — -t combines with a leading verbose flag without breaking log-file behavior
rm -rf "${XDG_STATE_HOME:?}/kz-tmux"
d="$TK/verbose-and-throttle"; mkdir -p "$d"
pid="$(run_kz "$d" -vv -t 1 2 "sh -c 'sleep 3'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
wait_panes "$SESSION" 2 || true
sleep 0.3
check "T10 -vv -t 1 still writes verbose log files" "$([ -d "$XDG_STATE_HOME/kz-tmux" ] && [ -n "$(find "$XDG_STATE_HOME/kz-tmux" -type f 2>/dev/null)" ] && echo yes || echo NO)" "yes"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T11 — while throttled launch is in progress, status-right shows a grey launch-progress
# message naming how many instances have launched so far
d="$TK/progress-grey"; mkdir -p "$d"
pid="$(run_kz "$d" -t 2 4 "sh -c 'sleep 6'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
wait_panes "$SESSION" 2 || true
sleep 0.3
SR="$(tmux show-options -t "$SESSION" status-right)"
check "T11 status-right shows grey progress during throttled launch" "$(printf '%s' "$SR" | grep -qc 'fg=grey' && echo yes || echo NO)" "yes"
check "T11 status-right names launched count and total" "$(printf '%s' "$SR" | grep -qc 'Launching 2 of 4' && echo yes || echo NO)" "yes"

# T12 — once the last batch has opened, status-right switches to the green help text and the
# grey progress message is gone
wait_panes "$SESSION" 4 || true
sleep 0.3
SR2="$(tmux show-options -t "$SESSION" status-right)"
check "T12 status-right switches to green after last batch" "$(printf '%s' "$SR2" | grep -qc 'fg=green' && echo yes || echo NO)" "yes"
check "T12 grey progress message is gone after last batch" "$(printf '%s' "$SR2" | grep -qc 'fg=grey' && echo yes || echo NO)" "NO"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T13 — with -t 0, status-right shows the green help text from the start, never grey
d="$TK/progress-none"; mkdir -p "$d"
pid="$(run_kz "$d" -t 0 4 "sh -c 'sleep 3'")"
SESSION="kz-$(basename "$d")-$pid"
wait_session "$SESSION" || true
wait_panes "$SESSION" 4 || true
SR="$(tmux show-options -t "$SESSION" status-right)"
check "T13 -t 0 shows green help text from the start" "$(printf '%s' "$SR" | grep -qc 'fg=green' && echo yes || echo NO)" "yes"
check "T13 -t 0 never shows grey progress" "$(printf '%s' "$SR" | grep -qc 'fg=grey' && echo yes || echo NO)" "NO"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# T14 — absence check: no code path in kz-tmux.sh calls the whole-server tmux teardown command
# (pattern built by concatenation so this file itself doesn't trip ISSUE-075's own
# no-other-file-names-it cross-check)
KS_PATTERN="kill-serv""er"
check "T14 kz-tmux.sh never calls the whole-server teardown command" "$(grep -c "$KS_PATTERN" "$KZ" | tr -d ' ')" "0"

rm -rf "$TMUX_SOCK_DIR"
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
