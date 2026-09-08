#!/usr/bin/env bash
# Shared setup for tests/*.sh — sourced once as the first line of every scenario script, from
# that script's own directory. Prints TESTROOT=<dir>. Defines every helper a scenario needs
# (check, git, ago, write_gate, own_session, zap, cd) and writes env.sh under TESTROOT so a
# retained root (implementor mode) or test-teardown-delete.sh can restore REPO/SCRIPT/TESTROOT
# and the helpers without re-running this file (which would mint a second TESTROOT).
set -eu
set -o pipefail
# the checkout this file itself lives in, deterministically — never $(pwd): a scenario's own
# later `cd` must not retarget REPO. Anchored to ${BASH_SOURCE[0]} instead of `git worktree list`
# (which always lists the main working tree first): a task worktree's own tests/ must resolve to
# that worktree's own kaizero.sh, not silently fall back to main's.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && command git rev-parse --show-toplevel)" || true
REAL_SCRIPT="$REPO/kaizero.sh"
[ -f "$REAL_SCRIPT" ] || { echo "FATAL: $REAL_SCRIPT not found — not inside the kaizero.sh repo" >&2; exit 1; }

# prerequisites, checked once here so no case downstream has to decide whether it can assert.
for t in flock uuidgen timeout git date find stat mv shellcheck jq python3; do
  command -v "$t" >/dev/null || { echo "FATAL: $t not on PATH — a prerequisite of this suite" >&2; exit 1; }
done
# a chmod 000 fixture is still readable by root, so the degradation cases it feeds would assert
# nothing there — and nothing in this suite needs that authority anyway.
[ "$(id -u)" != 0 ] || { echo "FATAL: refusing to run as root — chmod 000 fixtures do not deny root, so the cases that stage them cannot mean anything" >&2; exit 1; }
# a real binary path, resolved now — an asdf shim re-searches PATH internally and would 127 once
# a scenario narrows PATH below it (the MR-mode scenarios U-001 and up do). Used by S-001, not
# this file — shellcheck can't see that from here.
# shellcheck disable=SC2034
if command -v asdf >/dev/null 2>&1 && asdf which shellcheck >/dev/null 2>&1; then
  SHELLCHECK="$(asdf which shellcheck)"
else
  SHELLCHECK="$(type -P shellcheck)"
fi
# resolved now, same reason as SHELLCHECK above: the guard wrapper's own internal bash calls run
# under whatever PATH a scenario narrowed to (B8/B9/B10 strip bash off PATH entirely to prove
# run_doctor's own missing-prerequisite messages) — a bareword `bash` there would 127 before
# run_doctor is ever reached.
BASH_ABS="$(command -v bash)"
# bash 3.x for the parse case: macOS ships it as /bin/bash, Homebrew installs it as bash-3.2.
B3=""
for c in /bin/bash /usr/local/bin/bash-3.2 /opt/homebrew/bin/bash-3.2; do
  [ -x "$c" ] && "$c" --version 2>/dev/null | head -1 | grep -q 'version 3\.' && { B3="$c"; break; }
done
[ -n "$B3" ] || { echo "FATAL: no bash 3.x binary on this host (/bin/bash, /usr/local/bin/bash-3.2, /opt/homebrew/bin/bash-3.2) — a prerequisite of this suite" >&2; exit 1; }

TESTROOT="$(mktemp -d "${TMPDIR:-/tmp}/kaizero-tests.XXXXXX")"   # isolated, outside the repo
TESTROOT="$(cd "$TESTROOT" && pwd -P)"          # canonical path: on macOS $TMPDIR is /var→/private/var; the root-guard compares $PWD to git's physical path, so an uncanonicalized /var path misfires "not at repo root" at the real root
echo "TESTROOT=$TESTROOT"
# A and C's fixed, pre-trusted coordination repos (see TEST.md Prerequisites) live here, not under
# $TESTROOT — real `claude`'s trust dialog is keyed on a git repo's own root, not inherited from an
# ancestor, so their $T/$TC must be a permanent path, trusted once, out of band. Named exactly, not
# a wildcard over $HOME: the root-guard below allows this one purpose-built directory in addition to
# $TESTROOT, nothing else.
ANCHOR="$HOME/.kaizero-test-root"

# which run mode this scenario executes under (TEST.md "Run modes") — set by the caller before
# the script runs; report mode is the default. FAILED/ERRORED are the two verdict flags check()
# sets; both start clear and are read by this script's own trailing teardown block.
KAIZERO_TEST_MODE="${KAIZERO_TEST_MODE:-report}"
FAILED=0
ERRORED=0

# check "<label>" "<actual>" "<want>" — the suite's one verdict helper, expressing all three of
# TEST.md's outcomes. A guard refusal or a Setup that couldn't run has no meaningful actual-vs-want
# comparison to make, so it is reported as ERROR via the "ERROR:<text>" convention on $2, never as
# a FAIL disguised as a mismatched comparison — "neither a broken fixture nor an unrun command is a
# failure of the code under test" (TEST.md). Never calls exit: a FAIL/ERROR must still reach this
# script's own trailing teardown lines, so every case that can fail or error goes through check()
# and never exits on its own.
# shellcheck disable=SC2034
check(){
  case "$2" in
    ERROR:*) echo "$1 : ${2#ERROR:}  ERROR"; ERRORED=1 ;;
    *) if [ "$2" = "$3" ]; then echo "$1 : $2  (want $3)"
       else echo "$1 : $2  (want $3)  <-- FAIL"; FAILED=1; fi ;;
  esac
}
# exported so a case that drives its own checks from a nested `bash driver.sh` subprocess (a
# separate KAIZERO_SESSION_RECORD identity, e.g.) can call the same check() there too. That
# subprocess's own FAILED/ERRORED stay local to it (shell variables don't cross a process
# boundary) — such a driver ends with the same trailing `[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
# && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1` line every scenario does, and the case that
# invoked it folds the driver's exit status into its own FAILED/ERRORED on nonzero.
export -f check

# git wrapped to refuse outside $TESTROOT/$ANCHOR — a runtime guard, not a static one: no
# linter has a notion of "this path must stay under $TESTROOT", so a wrong-but-set path (a
# lost variable, a typo) would otherwise mutate the real checkout exactly as u53a/u57a did. Every
# scenario calls plain `git`, bypassing nothing, so any fixture command refuses the moment its cwd
# isn't under an allowed root, regardless of why it drifted there. Unconditional: no scenario
# needs the real repo's git state, so there is no case where refusing loses legitimate work.
git(){ case "$PWD" in
  "$TESTROOT"|"$TESTROOT"/*|"$ANCHOR"|"$ANCHOR"/*) command git "$@" ;;
  *) echo "REFUSING: git run outside \$TESTROOT (cwd=$PWD)" >&2; return 1 ;;
esac; }
# NOT exported, unlike check()/own_session(): kaizero.sh's own child-process runs (`bash
# "$SCRIPT" ...`) inherit this shell's exported functions too, and kaizero.sh's internal git
# calls going through this wrapper instead of the real binary silently broke its own execution
# (a refusal only when its cwd genuinely drifted outside TESTROOT/ANCHOR — which never happens in
# a passing run — so in practice this cost nothing observable except a confusing empty-output
# failure). A driver subprocess that needs the guard can't get it via export for that reason; it
# stays confined to $TU (already under $TESTROOT) instead, which the driver's own commands never
# leave.

# SCRIPT is a guarded wrapper, not $REAL_SCRIPT directly: the cwd-under-TESTROOT/ANCHOR check is
# baked into what `bash "$SCRIPT"` itself executes, so a bare invocation always refuses the moment
# its cwd strays, no per-call discipline required.
mkdir -p "$TESTROOT/guard"
SCRIPT="$TESTROOT/guard/kaizero-guarded.sh"
cat > "$SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\$PWD" in
  "$TESTROOT"|"$TESTROOT"/*) ;;
  "$ANCHOR"|"$ANCHOR"/*) ;;
  *) echo "REFUSING: cwd \$PWD is not under TESTROOT=$TESTROOT or ANCHOR=$ANCHOR — not invoking kaizero.sh" >&2; exit 1 ;;
esac
exec "$BASH_ABS" "$REAL_SCRIPT" "\$@"
EOF
chmod +x "$SCRIPT"

# no scenario needs to watch the visual "Starting session in 3...2...1" countdown before a real
# launch — skip it suite-wide so every real session this run launches doesn't pay its fixed 3s.
export KAIZERO_LAUNCH_COUNTDOWN=0

# every scenario's own checks assert kaizero.sh's plain, piped-log rendering (no snowflake-and-·
# box drawing, [ -t 1 ] false) — force that suite-wide, deterministically.
# kaizero.sh's own COLOR_CAPABLE gate already honors NO_COLOR for exactly this.
export NO_COLOR=1

# bg_setsid LOGFILE CMD... — launches CMD (inheriting this shell's own exported env — export
# vars first, don't prefix them onto this call) detached into its own session, stdout+stderr to
# LOGFILE, and prints the real pid. macOS ships no `setsid` binary, so python3's os.setsid is the
# only way to get one; same reason tests/AA-002's own aahung() reaches for python3 instead of
# bash for a signal a plain shell can't model. A plain `kill -SIGNAL -"$pid"` (note the leading
# `-`: CMD must be signaled as a process GROUP, not just its own pid) reaches it reliably from
# this same calling shell; a signal sent from a DIFFERENT process this shell didn't spawn itself
# (a separate python3 -c invocation doing the identical os.killpg, tried and confirmed silently
# swallowed) is not delivered at all in this harness's sandbox — signal permission here tracks
# process ancestry, not the syscall used.
# The pid this prints is not a child of the calling shell (`wait` cannot reap it or read its exit
# status): CMD is wrapped to write its own exit code to LOGFILE.rc, so a caller polls for that
# file (see wait_setsid) instead of using `wait`. The wrapper carries `trap ':' HUP` so a SIGHUP
# sent to the whole group (CMD must trap and handle it itself) doesn't also kill the wrapper before
# its trailing `echo $?` runs — bash's default HUP disposition is to exit immediately, even mid-wait
# for a foreground child, which used to make the wrapper die before writing LOGFILE.rc. A no-op
# *caught* handler (`trap ':' HUP`), not `trap '' HUP` (SIG_IGN): SIG_IGN would be inherited across
# CMD's fork/exec and block SIGHUP from ever reaching CMD at all; a caught handler resets to default
# on exec, so CMD still sees and can trap the signal normally.
bg_setsid(){
  local logfile=$1; shift
  python3 -c '
import subprocess, os, sys
logfile = sys.argv[1]
cmd = sys.argv[2:]
wrapped = ["bash", "-c", "trap ':' HUP; \"$@\"; echo $? > " + logfile + ".rc", "bash"] + cmd
p = subprocess.Popen(wrapped, stdout=open(logfile, "w"), stderr=subprocess.STDOUT, preexec_fn=os.setsid)
print(p.pid)
' "$logfile" "$@"
}

# wait_setsid LOGFILE [MAX_TICKS] — polls (0.2s ticks, default up to 200 = 40s) for the RC file
# bg_setsid's wrapper writes, then prints that exit code. Prints 124 (timeout's own convention)
# if it never appears.
wait_setsid(){
  local logfile=$1 max="${2:-200}" i=0
  while [ ! -f "$logfile.rc" ] && [ "$i" -lt "$max" ]; do sleep 0.2; i=$((i+1)); done
  if [ -f "$logfile.rc" ]; then cat "$logfile.rc"; else echo 124; fi
}

# touch-timestamp for N seconds ago, BSD (-v) or GNU (-d). Used by E.
ago(){ date -v-"$1"S +%Y%m%d%H%M.%S 2>/dev/null || date -d "-$1 sec" +%Y%m%d%H%M.%S; }

# BUG 057: session record for a driver run outside any real kaizero launch. own_session PATH
# [PID] writes a record at PATH naming PID (default: the calling shell's own $$) and exports
# KAIZERO_SESSION_RECORD/KAIZERO_SESSION_EPOCH so a `zero.sh` call in the same shell (or a
# child that inherits the env) resolves that pid as its owner. Epoch is always "1" — nothing here
# restarts, so one fixed value is all any driver needs.
own_session(){
  local f="$1" pid="${2:-$$}"
  printf '%s\n%s\n%s\n' "$pid" "$(ps -o lstart= -p "$pid" 2>/dev/null | awk '{$1=$1;print}')" 1 > "$f"
  export KAIZERO_SESSION_RECORD="$f" KAIZERO_SESSION_EPOCH=1
}
export -f own_session   # so a driver run as its own `bash driver.sh` subprocess can call it too

write_gate(){ cat > "$1" <<'INNEREOF'
#!/usr/bin/env bash
# Barrier + latch: block until NEED distinct agents are simultaneously in-flight,
# then latch open so later rounds pass instantly. Proves real parallelism
# independent of claude startup/shutdown skew (a fast agent waits for the slow one).
set -euo pipefail
G="$(cd "$(dirname "$0")" && pwd)/gate"; mkdir -p "$G/inflight"
label="${1:?usage: gate.sh LABEL [NEED] [TRIES]}"; need="${2:-3}"; tries="${3:-400}"
touch "$G/inflight/$label"
i=0
while [ ! -f "$G/opened" ] && [ "$i" -lt "$tries" ]; do
  flock "$G/lock" bash -c 'n=$(ls "$1/inflight" 2>/dev/null | wc -l); [ "$n" -ge "$2" ] && : > "$1/opened"' _ "$G" "$need" || true
  [ -f "$G/opened" ] || sleep 0.3
  i=$((i+1))
done
rm -f "$G/inflight/$label"
[ -f "$G/opened" ]   # exit 0 only if the latch opened (NEED-way overlap proven)
INNEREOF
chmod +x "$1"; }

# zap is the suite's only recursive delete, so the destructive-command hook in this repository
# has one construct to permit rather than one in every command the suite issues. It refuses any
# target that is not $TESTROOT or under it, and makes the tree writable first (chmod 000
# fixtures do not delete themselves). The containment check runs against the PHYSICAL path — `cd
# -P` resolves every `..` segment and follows every symlink on the way, including a $1 that is
# itself a symlink resolving outside $TESTROOT — a plain string/glob compare against "$1" would
# accept "$TESTROOT/../.." as a literal prefix match and delete outside the root.
zap(){
  local t="${1:-}" real dir base
  [ -n "$t" ] || { echo "REFUSING: no target given — not deleting" >&2; return 1; }
  real="$(cd -P -- "$t" 2>/dev/null && pwd -P)"
  if [ -z "$real" ]; then
    dir="$(dirname -- "$t")"; base="$(basename -- "$t")"
    real="$(cd -P -- "$dir" 2>/dev/null && pwd -P)/$base"
  fi
  case "$real" in
    "$TESTROOT"|"$TESTROOT"/*) chmod -R u+rwX "$t" 2>/dev/null || true
                               find "$t" -depth -delete 2>/dev/null || true; [ ! -e "$t" ] ;;
    *) echo "REFUSING: '$1' is not under TESTROOT=$TESTROOT — not deleting" >&2; return 1 ;;
  esac
}

# a bare `cd` that fails inside `( cd "$x"; ...more... )` doesn't abort the subshell — it prints
# to stderr and keeps running "...more..." in whatever cwd the subshell inherited (the project's
# own main worktree, in a fresh harness call). Overriding cd to hard-exit on failure turns that
# silent wrong-cwd fallthrough into an immediate, loud stop, everywhere, with no per-call changes
# to a scenario file.
cd(){ builtin cd "$@" || { echo "REFUSING: cd $* failed — aborting to avoid running in the wrong cwd" >&2; exit 1; }; }

# env.sh: restores REPO/SCRIPT/TESTROOT/ANCHOR and every helper above for whoever re-enters this
# TESTROOT later — test-teardown-delete.sh (needs zap), and an implementor manually re-entering a
# root this script's own trailing teardown retained. Not a per-command state chain any more: one
# script is one process, so nothing needs to survive a shell boundary during the run itself.
{
  printf 'TESTROOT=%q; REPO=%q; SCRIPT=%q; ANCHOR=%q\n' "$TESTROOT" "$REPO" "$SCRIPT" "$ANCHOR"
  declare -f check git ago own_session write_gate zap cd
} > "$TESTROOT/env.sh"

# land the scenario under an allowed root before it runs a single fixture command: the wrapped
# git() above (and $SCRIPT's own guard) refuse any call whose $PWD isn't under $TESTROOT/$ANCHOR,
# and a scenario's own cwd is otherwise whatever the caller's shell happened to be sitting in —
# the real repo checkout in a plain `bash tests/<KEY>.sh` invocation. Every scenario's own `cd`
# into its own fixture directory moves it further under here; nothing needs to cd here itself.
cd "$TESTROOT"

# this file is sourced, not run as a subprocess, so its own `set -eu`/`pipefail` above would
# otherwise leak into the rest of the scenario script for the remainder of the process. Restore
# errexit off here so the scenario runs under exactly the options its own opening line set
# (`set -uo pipefail`, no -e) — a scenario's cases are written to walk past a non-zero command on
# purpose (`cmd; echo $?`, a guard refusal captured via check()'s ERROR: path).
set +e
