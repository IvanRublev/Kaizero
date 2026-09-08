#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# TASK-059e-co-authorship — write_prepare_commit_msg_hook installs an idempotent, opt-outable
# prepare-commit-msg hook into a given repo's own git dir (never the caller's cwd), and
# mr_body_add_closing_line appends the MR closing line the same idempotent, opt-outable way.
# Needs real claude: no — both functions are exercised directly, no session is launched.
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/TASK-059e-co-authorship

TT="$TESTROOT/TASK-059e-co-authorship"
mkdir -p "$TT"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }

# extract_fn <name> <file>: sed out a single top-level function body verbatim and eval it into
# the calling shell — write_prepare_commit_msg_hook lives in kaizero.sh's own main flow (not the
# emitted zero.sh, which has no case dispatch to source up to), so this is simpler and has none
# of sourcing the whole script's side effects.
extract_fn(){ eval "$(sed -n "/^$1() {/,/^}/p" "$2")"; }

# --- prepare-commit-msg hook: install ---
mkrepo "$TT/r1"
( extract_fn write_prepare_commit_msg_hook "$REAL_SCRIPT"
  write_prepare_commit_msg_hook "$TT/r1"
  hook="$TT/r1/.git/hooks/prepare-commit-msg"
  check "hook file exists" "$([ -f "$hook" ] && echo yes || echo no)" "yes"
  check "hook file executable" "$([ -x "$hook" ] && echo yes || echo no)" "yes"

  msg="$TT/r1-msg1"; printf 'a commit\n' > "$msg"
  "$hook" "$msg"
  check "hook appends trailer" "$(grep -cF 'Co-authored-by: Kaizero <noreply@kaizero.sh>' "$msg")" "1"
)
# PASS — write_prepare_commit_msg_hook installs an executable hook in the given repo's git dir,
# and running it appends the Kaizero trailer.

# --- MR body closing line ---
( extract_fn mr_body_add_closing_line "$REAL_SCRIPT"
  body="$TT/body1.md"; printf 'A description of the change.\n' > "$body"
  mr_body_add_closing_line "$body"
  check "closing line appended" "$(grep -cF 'Guided by [Kaizero](https://kaizero.sh)' "$body")" "1"
)
# PASS — mr_body_add_closing_line appends the Kaizero closing line to the MR body.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
