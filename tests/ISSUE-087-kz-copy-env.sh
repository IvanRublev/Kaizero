#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=120s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCENARIO_DIR/test-setup.sh"

# ISSUE-087-kz-copy-env — kz-tmux.sh: KZ_COPY_ENV names variables that tmux copies from the
# launching shell into every pane, without a value on any command line, and the global
# update-environment option is put back once the session exists.
# Needs real claude: no
# Tools beyond the shared prerequisites: tmux
# Folder under $TESTROOT: $TESTROOT/ISSUE-087-kz-copy-env
# Wall-clock budget: short `sleep`s inside tmux panes — well under 120s
#
# Hard rule: every tmux server this scenario touches is isolated via TMUX_TMPDIR, never the
# operator's default server.

command -v tmux >/dev/null || { echo "FATAL: tmux not on PATH — a prerequisite of this suite" >&2; exit 1; }

KZ="$REPO/kz-tmux.sh"
[ -x "$KZ" ] || { echo "FATAL: $KZ not found or not executable" >&2; exit 1; }
REAL_TMUX="$(command -v tmux)"

TK="$TESTROOT/ISSUE-087-kz-copy-env"; mkdir -p "$TK"
unset TMUX
TMUX_SOCK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kzt.XXXXXX")"
export TMUX_TMPDIR="$TMUX_SOCK_DIR"
export XDG_STATE_HOME="$TK/xdg-state"

wait_session(){ local s="$1" i=0; while ! tmux has-session -t "$s" 2>/dev/null; do
  i=$((i+1)); [ "$i" -ge 50 ] && return 1; sleep 0.1; done; return 0; }
# waits until DIR holds N env.* dump files, or gives up after ~15s
wait_dumps(){ local d="$1" n="$2" i=0
  while [ "$(find "$d" -name 'env.*' 2>/dev/null | wc -l | tr -d ' ')" -lt "$n" ]; do
    i=$((i+1)); [ "$i" -ge 150 ] && return 1; sleep 0.1; done; return 0; }
# ends every session (the last one ends the server, so the next case starts on a clean server)
reset(){ local s; for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
  tmux kill-session -t "$s" 2>/dev/null; done; sleep 0.3; }
# pane command: dumps the pane's environment to DIR/env.<pid>, then idles
dump_cmd(){ echo "sh -c 'env > $1/tmp.\$\$ && mv $1/tmp.\$\$ $1/env.\$\$; sleep 20'"; }
# run_kz DIR [NAME=value ...] -- kz-tmux args...: starts kz-tmux.sh detached, prints its pid
run_kz(){
  local dir="$1"; shift; local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  mkdir -p "$dir"
  ( cd "$dir" && exec env ${envs[@]+"${envs[@]}"} bash "$KZ" "$@" >out.log 2>err.log </dev/null ) &
  echo $!
}
# count of dump files in DIR that hold the exact line LINE
dumps_with(){ local d="$1" line="$2" n=0 f; for f in "$d"/env.*; do
  [ -f "$f" ] && grep -qxF "$line" "$f" && n=$((n+1)); done; echo "$n"; }
# a pane-less server that stays up while the launches under test run against it
start_server(){ env -u SECRET_A -u SECRET_B -u NOPE_X tmux new-session -d -s keep 'sleep 120'; }

VA="valA-$$"; VB="valB-$$"
KE="SECRET_A=$VA SECRET_B=$VB"

# T1 — fresh server: both panes of a 2-pane launch hold both values
reset
d="$TK/fresh"; mkdir -p "$d"
pid="$(run_kz "$d" KZ_COPY_ENV="SECRET_A SECRET_B" $KE -- -t 0 2 "$(dump_cmd "$d")")"
wait_dumps "$d" 2 || true
check "T1 fresh server: SECRET_A matches in both panes" "$(dumps_with "$d" "SECRET_A=$VA")" "2"
check "T1 fresh server: SECRET_B matches in both panes" "$(dumps_with "$d" "SECRET_B=$VB")" "2"

# T2 — running server (started without the values): first and split panes hold both values;
# the stub process started in the pane in place of kaizero is the dump itself
reset; start_server
d="$TK/running"; mkdir -p "$d"
pid="$(run_kz "$d" KZ_COPY_ENV="SECRET_A SECRET_B" $KE -- -t 0 3 "$(dump_cmd "$d")")"
wait_dumps "$d" 3 || true
check "T2 running server: SECRET_A matches in 3 panes" "$(dumps_with "$d" "SECRET_A=$VA")" "3"
check "T2 running server: SECRET_B matches in 3 panes" "$(dumps_with "$d" "SECRET_B=$VB")" "3"

# T3 — running server: update-environment is as before the launch
reset; start_server
before="$(tmux show-options -gv update-environment)"
d="$TK/restore"; mkdir -p "$d"
pid="$(run_kz "$d" KZ_COPY_ENV="SECRET_A SECRET_B" $KE -- -t 0 1 "$(dump_cmd "$d")")"
wait_dumps "$d" 1 || true
check "T3 running server: update-environment restored" "$(tmux show-options -gv update-environment)" "$before"

# T4 — fresh server: update-environment equals the built-in defaults of a fresh server
reset
d="$TK/restore-fresh"; mkdir -p "$d"
pid="$(run_kz "$d" KZ_COPY_ENV="SECRET_A SECRET_B" $KE -- -t 0 1 "$(dump_cmd "$d")")"
wait_dumps "$d" 1 || true
after="$(tmux show-options -gv update-environment)"
defaults="$(tmux -L kzdefaults new-session -d -s x 'sleep 5' && tmux -L kzdefaults show-options -gv update-environment)"
tmux -L kzdefaults kill-session -t x 2>/dev/null
check "T4 fresh server: update-environment equals built-in defaults" "$after" "$defaults"

# T5 — two consecutive launches leave update-environment unchanged, no name twice
reset; start_server
before="$(tmux show-options -gv update-environment)"
for k in one two; do
  d="$TK/twice-$k"; mkdir -p "$d"
  pid="$(run_kz "$d" KZ_COPY_ENV="SECRET_A SECRET_B" $KE -- -t 0 1 "$(dump_cmd "$d")")"
  wait_dumps "$d" 1 || true
done
check "T5 two launches: update-environment unchanged" "$(tmux show-options -gv update-environment)" "$before"

# T6 — a later launch without KZ_COPY_ENV from a shell that still exports the names: no values
d="$TK/later"; mkdir -p "$d"
pid="$(run_kz "$d" $KE -- -t 0 1 "$(dump_cmd "$d")")"
wait_dumps "$d" 1 || true
check "T6 later launch without KZ_COPY_ENV: SECRET_A absent" "$(dumps_with "$d" "SECRET_A=$VA")" "0"
check "T6 later launch without KZ_COPY_ENV: SECRET_B absent" "$(dumps_with "$d" "SECRET_B=$VB")" "0"

# T7 — a NAME=value prefix and KZ_COPY_ENV together
reset; start_server
d="$TK/prefix"; mkdir -p "$d"
pid="$(run_kz "$d" KZ_COPY_ENV="SECRET_A SECRET_B" $KE -- -t 0 1 "PREFIX_V=pv $(dump_cmd "$d")")"
wait_dumps "$d" 1 || true
check "T7 prefix variable present" "$(dumps_with "$d" "PREFIX_V=pv")" "1"
check "T7 copied variable present" "$(dumps_with "$d" "SECRET_A=$VA")" "1"

# T8 — a name unset in the launching shell: pane lacks it, launch succeeds
reset; start_server
d="$TK/unset-name"; mkdir -p "$d"
pid="$(run_kz "$d" KZ_COPY_ENV="SECRET_A NOPE_X" $KE -- -t 0 1 "$(dump_cmd "$d")")"
wait_dumps "$d" 1 || true
check "T8 unset name: launch succeeded, copied name present" "$(dumps_with "$d" "SECRET_A=$VA")" "1"
check "T8 unset name: pane lacks it" "$(cat "$d"/env.* | grep -c '^NOPE_X=')" "0"

# tmux shim logging every argv, one argument per line
SHIM="$TK/shim"; mkdir -p "$SHIM"
cat >"$SHIM/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >>"\$TMUX_ARGV_LOG"
exec "$REAL_TMUX" "\$@"
EOF
chmod +x "$SHIM/tmux"

# T9 — malformed names: usage-style error, exit 1, no tmux command run
reset
for bad in "A;B" "A*" "1A"; do
  d="$TK/bad-$(echo "$bad" | tr -c 'A-Za-z0-9\n' '_')"; mkdir -p "$d"
  log="$d/argv.log"; : >"$log"
  ( cd "$d" && PATH="$SHIM:$PATH" TMUX_ARGV_LOG="$log" KZ_COPY_ENV="$bad" bash "$KZ" 1 "echo hi" >out.log 2>err.log </dev/null ); rc=$?
  check "T9 '$bad' exit 1" "$rc" "1"
  check "T9 '$bad' usage on stderr" "$(grep -qi usage "$d/err.log" && echo yes || echo NO)" "yes"
  check "T9 '$bad' no tmux command run" "$(wc -c <"$log" | tr -d ' ')" "0"
done

# T10 — unset and blank KZ_COPY_ENV hand tmux the same arguments and set the same options
argv_of(){ # label [KZ_COPY_ENV=...]
  local label="$1"; shift; local d="$TK/argv-$label"; mkdir -p "$d"; : >"$d/argv.log"
  reset
  local pid; pid="$(run_kz "$d" PATH="$SHIM:$PATH" TMUX_ARGV_LOG="$d/argv.log" "$@" -- -t 0 1 "sleep 20")"
  wait_session "kz-argv-$label-$pid" || true; sleep 0.5
  sed "s/kz-argv-$label-$pid/SESSION/g; s#$d#DIR#g" "$d/argv.log" >"$d/argv.norm"
  local s; s="$(tmux list-sessions -F '#{session_name}' | head -1)"
  { for o in mouse repeat-time status-right remain-on-exit; do tmux show-options -t "$s" -v "$o" 2>&1; tmux show-window-options -t "$s" -v "$o" 2>&1; done; } >"$d/opts.txt"
}
argv_of unset
argv_of blank KZ_COPY_ENV=" "
check "T10 blank hands tmux the same arguments as unset" "$(cmp -s "$TK/argv-unset/argv.norm" "$TK/argv-blank/argv.norm" && echo same || echo DIFF)" "same"
check "T10 blank sets the same options as unset" "$(cmp -s "$TK/argv-unset/opts.txt" "$TK/argv-blank/opts.txt" && echo same || echo DIFF)" "same"
check "T10 unset hands tmux no update-environment" "$(grep -c update-environment "$TK/argv-unset/argv.norm")" "0"
check "T10 session options are set" "$([ "$(grep -c '^on$' "$TK/argv-unset/opts.txt")" -ge 2 ] && echo yes || echo NO)" "yes"

# T11 — the value never appears in any argv, nor in any pane's scrollback
reset; start_server
MARK="mk-$$-$RANDOM"
d="$TK/marker"; mkdir -p "$d"; : >"$d/argv.log"
pid="$(run_kz "$d" PATH="$SHIM:$PATH" TMUX_ARGV_LOG="$d/argv.log" KZ_COPY_ENV="SECRET_A" SECRET_A="$MARK" -- -t 0 2 "$(dump_cmd "$d")")"
wait_dumps "$d" 2 || true
check "T11 pane holds the marker" "$(dumps_with "$d" "SECRET_A=$MARK")" "2"
check "T11 no tmux argv holds the marker" "$(grep -c "$MARK" "$d/argv.log")" "0"
scroll=""; for p in $(tmux list-panes -a -F '#{pane_id}'); do scroll="$scroll$(tmux capture-pane -p -S - -t "$p")"; done
check "T11 no pane scrollback holds the marker" "$(printf '%s' "$scroll" | grep -c "$MARK")" "0"
reset

# T12 — absence checks on the script itself
check "T12 no tmux default update-environment names listed" "$(grep -cE 'DISPLAY|SSH_AUTH_SOCK|SSH_CONNECTION=|WINDOWID|XAUTHORITY' "$KZ")" "0"
check "T12 usage line unchanged" "$(grep -cF 'USAGE="usage: kz-tmux.sh [-v|-vv|-vvv] [-t <wait_sec>] <num-terminals> <kaizero-command...> (wait_sec: 0-900, default is 1)"' "$KZ")" "1"
check "T12 no secret store read" "$(grep -cE 'security (find|add)|pass (show|insert)|keychain|secret-tool' "$KZ")" "0"

# T13 — documentation: usage header and README carry the variable and the example
EX='KZ_COPY_ENV="ACC_ID ACC_TOKEN" kz-tmux 2 KAIZERO_LINK=node_modules kaizero todo.md --local-merge'
check "T13 header describes KZ_COPY_ENV" "$([ "$(sed -n '1,/^set -/p' "$KZ" | grep -c 'KZ_COPY_ENV')" -gt 0 ] && echo yes || echo NO)" "yes"
check "T13 header holds the example" "$(sed -n '1,/^set -/p' "$KZ" | grep -cF "$EX")" "1"
check "T13 README holds the example" "$(grep -cF "$EX" "$REPO/README.md")" "1"

rm -rf "$TMUX_SOCK_DIR"
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
