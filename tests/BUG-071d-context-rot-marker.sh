#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=30s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# BUG-071d-context-rot-marker — the context-rot restart branch (term_owner "90 ...") writes the
# per-instance turn marker the same uuid-content way the ordinary end-of-turn branch does. Both
# exit paths share the single `mf` write above the branch split (compact-exit-hook.sh), so a
# transcript whose usage trips the context-rot threshold still leaves the marker holding that
# transcript's own newest record uuid.
# Needs real claude: no — the hook is invoked directly
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/BUG-071d-context-rot-marker

TW="$TESTROOT/BUG-071d-context-rot-marker"; mkdir -p "$TW/repo" "$TW/bin"
cd "$TW/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] T1 x\n' > todo.md; git add -A; git commit -qm init
printf '#!/usr/bin/env bash\nexit 0\n' > "$TW/bin/claude"; chmod +x "$TW/bin/claude"
PATH="$TW/bin:$PATH" KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md -t x >/dev/null 2>&1 || true
HOOK="$TW/repo/.git/compact-exit-hook.sh"
check "hook emitted" "$([ -x "$HOOK" ] && echo yes || echo no)" "yes"

TP="$TW/transcript.jsonl"
# a usage record whose input_tokens alone clears the 160000 default threshold, own uuid set
printf '%s\n' '{"type":"assistant","uuid":"rot-uuid-1","message":{"model":"claude-x","usage":{"input_tokens":200000,"output_tokens":5}}}' > "$TP"

EXITREASON="$TW/claude-exit-reason-x-1"; : > "$EXITREASON"
MARKER="$TW/turn-concluded-x-1"
rm -f "$MARKER"
INPUT="$(printf '{"transcript_path":"%s"}' "$TP")"
printf '%s' "$INPUT" | KAIZERO_INSTANCE=1 KAIZERO_EXIT_REASON="$EXITREASON" KAIZERO_SAFE_TO_EXIT="" "$HOOK" >/dev/null 2>&1 || true

check "marker written on context-rot branch" "$([ -f "$MARKER" ] && echo yes || echo no)" "yes"
check "marker content is transcript's own uuid" "$(cat "$MARKER" 2>/dev/null)" "rot-uuid-1"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
