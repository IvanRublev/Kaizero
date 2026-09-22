#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# TASK-066f-stop-hook-marker — the emitted Stop hook (compact-exit-hook.sh), invoked directly the
# way .github/check-embedded.sh's own KAIZERO_TEST_EMIT convention does, writes the per-instance
# turn marker on a real firing, at the exact path derived from KAIZERO_EXIT_REASON (same
# directory, same <slug>-<instance> suffix, "turn-concluded-" in place of "claude-exit-reason-" —
# no new KAIZERO_* env var for this).
# Needs real claude: no — the hook is invoked directly, no claude process involved
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/TASK-066f-stop-hook-marker

TW="$TESTROOT/TASK-066f-stop-hook-marker"; mkdir -p "$TW/repo" "$TW/bin"
cd "$TW/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] T1 x\n' > todo.md; git add -A; git commit -qm init
printf '#!/usr/bin/env bash\nexit 0\n' > "$TW/bin/claude"; chmod +x "$TW/bin/claude"

# TW6 — the hook writes the marker at its derived path on a real firing
cd "$TW/repo"
KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md -t x >/dev/null 2>&1 || true
HOOK="$TW/repo/.git/compact-exit-hook.sh"
check "TW6 hook emitted" "$([ -x "$HOOK" ] && echo yes || echo no)" "yes"
EXITREASON="$TW/claude-exit-reason-x-1"; : > "$EXITREASON"
MARKER="$TW/turn-concluded-x-1"
rm -f "$MARKER"
printf '{}' | KAIZERO_INSTANCE=1 KAIZERO_EXIT_REASON="$EXITREASON" KAIZERO_SAFE_TO_EXIT="" "$HOOK" >/dev/null 2>&1 || true
check "TW6 marker written" "$([ -f "$MARKER" ] && echo yes || echo no)" "yes"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
