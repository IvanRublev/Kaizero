#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=45s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCENARIO_DIR/test-setup.sh"

# BUG-073a-error-messages-to-stderr — every $PROG error echo paired with exit 1/return 1 must
# survive stdout being discarded and disappear when stderr is discarded instead.
# Needs real claude: no — both refusals happen before any claude launch.
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/BUG-073a-error-messages-to-stderr
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s

TB="$TESTROOT/BUG-073a-error-messages-to-stderr"
mkdir -p "$TB/unsupported-forge"
( cd "$TB/unsupported-forge"; git init -q; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init
  echo "- [ ] G1 noop" > todo.md; git add todo.md; git commit -qm todo
  git remote add origin https://example.com/foo/bar.git )

# BA1 — decide_origin's "Unsupported forge" refusal (MR mode, an origin host that is neither
# github nor gitlab) survives stdout being discarded (message must be on stderr)
cd "$TB/unsupported-forge"
out=$(timeout 20 bash "$SCRIPT" todo.md -t x 2>&1 1>/dev/null)
if echo "$out" | grep -qi 'unsupported forge'; then ba1=present; else ba1=absent; fi
check "BA1 unsupported-forge-on-stdout-discard" "$ba1" "present"

# BA2 — the same refusal disappears when stderr instead is discarded (message must not be on stdout)
out=$(timeout 20 bash "$SCRIPT" todo.md -t x 2>/dev/null)
if echo "$out" | grep -qi 'unsupported forge'; then ba2=present; else ba2=absent; fi
check "BA2 unsupported-forge-absent-on-stderr-discard" "$ba2" "absent"

# BA3 — --doctor's flock-missing refusal goes to stderr, not stdout (an already-correct site,
# proving the fix does not touch sites that were right before)
mkbin(){ local d="$1"; shift; mkdir -p "$d"; local t p; for t in "$@"; do p=$(command -v "$t") || { echo "REFUSING: '$t' not found — cannot build $d" >&2; exit 1; }; ln -sf "$p" "$d/$t"; done; }
BASH_BIN="$(command -v bash)"
mkdir -p "$TB/emptyhome"
mkbin "$TB/bin-noflock" basename mktemp claude uname
out=$(HOME="$TB/emptyhome" PATH="$TB/bin-noflock" "$BASH_BIN" "$SCRIPT" --doctor 2>&1 1>/dev/null)
if echo "$out" | grep -qi 'flock not found'; then ba3=present; else ba3="$out"; fi
check "BA3 doctor-flock-refusal-on-stderr" "$ba3" "present"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
