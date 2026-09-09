#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=85s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCENARIO_DIR/test-setup.sh"

# B-002-doctor-prerequisites — run_doctor with no ~/.claude/settings.json, a missing
# claude/flock, and -h outside a git repository.
# Needs real claude: no — claude is never launched to do real work (claude still has to be on
# PATH and runnable: run_doctor runs `claude -v` before any startup guard runs)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/B-002-doctor-prerequisites
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# run_doctor coverage: no ~/.claude/settings.json is a prerequisite anymore, and --doctor is the
# same code path a normal startup runs first, so both are driven from one HOME with no ~/.claude
# directory at all. The dirty repo of the guard scenario is rebuilt here because B7 reads it: a
# normal startup under that same HOME must get past the settings check and refuse on the
# dirty-tree guard instead. The last case needs no repository at all — -h/--help outside any git
# repository.

TB="$TESTROOT/B-002-doctor-prerequisites"
for name in dirty detached nested worktree untracked; do
  mkdir -p "$TB/$name"
  ( cd "$TB/$name"; git init -q; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init
    echo "- [ ] G1 noop" > todo.md; git add todo.md; git commit -qm todo )
done
( cd "$TB/dirty";    echo change >> f )       # dirty working tree

# B6 — --doctor --local-merge needs no ~/.claude/settings.json
# run_doctor coverage: no ~/.claude/settings.json is a prerequisite anymore, and --doctor is the
# same code path a normal startup runs first. `mkbin DIR tool…` symlinks only the named tools
# into an otherwise-empty dir, so PATH=DIR alone proves a tool's true absence — --doctor exits
# before main() reaches any of git/sed/awk/uuidgen/etc, so `basename`, `mktemp` and
# (conditionally) `claude`/`flock` are the whole surface it needs.
mkbin(){ local d="$1"; shift; mkdir -p "$d"; local t p; for t in "$@"; do p=$(command -v "$t") || { echo "REFUSING: '$t' not found — cannot build $d" >&2; exit 1; }; ln -sf "$p" "$d/$t"; done; }
BASH_BIN="$(command -v bash)"   # PATH=bin-no* below excludes bash itself; invoke it by absolute path
mkdir -p "$TB/emptyhome"    # HOME with no ~/.claude directory at all

# --local-merge: these fixtures carry no origin, and a bare --doctor now makes the same origin
# decision a launch does — which is U-004-the-origin-decides-the-mode's subject (U60), not this one's.
if out=$(HOME="$TB/emptyhome" bash "$SCRIPT" --doctor --local-merge 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" = 0 ] && echo "$out" | grep -qi 'all prerequisites OK'; then r6=ok; else r6="rc=$rc: $out"; fi
check "B6 doctor-no-settings" "$r6" "ok"

# B7 — a normal startup from the same HOME gets past that check and refuses on the dirty tree
cd "$TB/dirty"                                 # same dirty tree as B1, now under the empty HOME
if out=$(HOME="$TB/emptyhome" timeout 20 bash "$SCRIPT" --local-merge todo.md -t x 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" != 0 ] && echo "$out" | grep -qi dirty; then r7=refused; else r7="rc=$rc: $out"; fi
check "B7 startup-no-settings" "$r7" "refused"

# B8 — --doctor refuses when claude is absent
mkbin "$TB/bin-noclaude" basename mktemp flock
if out=$(HOME="$TB/emptyhome" PATH="$TB/bin-noclaude" "$BASH_BIN" "$SCRIPT" --doctor 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" != 0 ] && echo "$out" | grep -qi 'claude CLI not found'; then r8=refused; else r8="rc=$rc: $out"; fi
check "B8 doctor-no-claude" "$r8" "refused"

# B9 — --doctor refuses when flock is absent
mkbin "$TB/bin-noflock" basename mktemp claude
if out=$(HOME="$TB/emptyhome" PATH="$TB/bin-noflock" "$BASH_BIN" "$SCRIPT" --doctor 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" != 0 ] && echo "$out" | grep -qi 'flock not found'; then r9=refused; else r9="rc=$rc: $out"; fi
check "B9 doctor-no-flock" "$r9" "refused"

# B10 — --doctor refuses when flock is present but not runnable
mkbin "$TB/bin-badflock" basename mktemp claude
printf '#!/usr/bin/env bash\nexit 1\n' > "$TB/bin-badflock/flock"; chmod +x "$TB/bin-badflock/flock"
if out=$(HOME="$TB/emptyhome" PATH="$TB/bin-badflock" "$BASH_BIN" "$SCRIPT" --doctor 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" != 0 ] && echo "$out" | grep -qi 'flock present but not runnable'; then r10=refused; else r10="rc=$rc: $out"; fi
check "B10 doctor-flock-broken" "$r10" "refused"

# B12 — --doctor refuses when claude is on PATH but fails to execute (BUG-058j: a version-manager
# shim that resolves to no install — `command -v` finds it, invoking it fails)
mkbin "$TB/bin-badclaude" basename mktemp flock uname bash
printf '#!/usr/bin/env bash\necho "asdf: No version is set for command claude" >&2\nexit 126\n' > "$TB/bin-badclaude/claude"; chmod +x "$TB/bin-badclaude/claude"
if out=$(HOME="$TB/emptyhome" PATH="$TB/bin-badclaude" "$BASH_BIN" "$SCRIPT" --doctor 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" != 0 ] && echo "$out" | grep -qi 'No version is set for command claude'; then r12=refused; else r12="rc=$rc: $out"; fi
check "B12 doctor-claude-not-runnable" "$r12" "refused"

# B11 — -h/--help outside any git repository
mkdir -p "$TB/notgit"                          # no .git anywhere above this dir
if out=$(cd "$TB/notgit" && timeout 20 bash "$SCRIPT" -h 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" = 0 ] && echo "$out" | grep -qi '^usage:' && ! echo "$out" | grep -qi 'not a git repository'; then r11=ok; else r11="rc=$rc: $out"; fi
check "B11 help-outside-git" "$r11" "ok"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
