#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCENARIO_DIR/test-setup.sh"

# E-001-timing-accounting — timing accounting.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/E-001-timing-accounting
# Wall-clock budget: its longest Run command is `timeout 30` — allow that command at least 30s
#
# The per-instance timing logic is deterministic and needs no real claude — a stub claude on
# PATH lets kaizero write zero.sh and loop out immediately, then we exercise the accounting
# paths directly. Covers the two bugs found while building the feature: crediting must work when
# called without a claude ancestor (lazy ensure_owner), and the in-flight sweep must be
# idempotent and route credit to the owner instance, not the caller. E2 covers startup GC of
# orphan time-files.

TE="$TESTROOT/E-001-timing-accounting"; mkdir -p "$TE/repo" "$TE/bin"
cat > "$TE/bin/claude" <<'EOF'
#!/usr/bin/env bash
exit 0                     # stub: do nothing; kaizero still writes zero.sh + registers instance
EOF
chmod +x "$TE/bin/claude"
cd "$TE/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] E1 x\n' > todo.md; git add -A; git commit -qm init
# bootstrap: real kaizero writes .git/zero.sh, stub claude exits, loop ends (MAX_LOOPS=1)
PATH="$TE/bin:$PATH" timeout 30 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TE/boot.log" 2>&1 || true
ZERO="$(cd "$(git rev-parse --git-dir)" && pwd)/zero.sh"
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
check "E0 zero.sh built" "$([ -x "$ZERO" ] && echo yes || echo NO)" "yes"

# E1 — in-flight credit: routes to owner, no-ancestor-safe, idempotent
cd "$TE/repo"
# fabricate an orphaned in-flight worktree: dead owner (pid 999999) of instance A, acquired 100s
# ago, last file activity 60s ago → expected credit ≈ 40s.
git worktree add -q "$TE/wt-E1" -b "main-task-E1" main
WT="$(cd "$TE/wt-E1" && pwd)"
find "$WT" -type f -not -path '*/.git/*' -exec touch -t "$(ago 100)" {} +
printf '%s\n%s\n%s\n%s\n' 999999 fake "$(( $(date +%s) - 100 ))" A > "$WT/.owner"
touch -t "$(ago 60)" "$WT/worked.txt"
# credit AS instance B, with NO claude ancestor → must credit A (owner line4), not B
KAIZERO_INSTANCE=B "$ZERO" credit_inflight_time; rc1=$?
a1=$(cat "$GC/todos-seconds-main-A" 2>/dev/null || echo MISSING)
KAIZERO_INSTANCE=B "$ZERO" credit_inflight_time            # second pass must be a no-op
a2=$(cat "$GC/todos-seconds-main-A" 2>/dev/null || echo MISSING)
# lazy ensure_owner, not FATAL 7
check "E1 exit (no anc)" "$rc1" "0"
# want ~40; 30..70 ok
check "E1 credited A" "$([ "$a1" -ge 30 ] 2>/dev/null && [ "$a1" -le 70 ] 2>/dev/null && echo yes || echo no)" "yes"
check "E1 idempotent" "$([ "$a1" = "$a2" ] && echo yes || echo "no ($a1 -> $a2)")" "yes"
check "E1 B untouched" "$([ -f "$GC/todos-seconds-main-B" ] && echo NO || echo yes)" "yes"
check "E1 owner kept" "$(sed -n 4p "$WT/.owner")" "A"
git worktree remove --force "$TE/wt-E1" 2>/dev/null || true
# E1 PASS — exit = 0, credited A in 30..70, idempotent = yes, B untouched = yes, owner kept = A.

# E2 — startup GC of orphan time-files
cd "$TE/repo"
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"; mkdir -p "$GC/instance"
printf '%s\n%s\n' 999999 fake > "$GC/instance/DEADID"          # marker of a dead instance
: > "$GC/todos-seconds-main-DEADID"; : > "$GC/todos-seconds-main-DEADID.lock"
: > "$GC/todos-done-main-DEADID";    : > "$GC/todos-done-main-DEADID.lock"
: > "$GC/safe-to-exit-main-DEADID"
: > "$GC/todos-seconds-main-NOMARK"                             # file with no marker at all
: > "$GC/todos-done-main-NOMARK"
: > "$GC/safe-to-exit-main-NOMARK"
# run kaizero once more (stub claude) → startup registers our live instance, then GCs orphans
PATH="$TE/bin:$PATH" timeout 30 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TE/boot2.log" 2>&1 || true
check "E2 dead file gone" "$([ -f "$GC/todos-seconds-main-DEADID" ] && echo NO || echo yes)" "yes"
check "E2 dead count gone" "$([ -f "$GC/todos-done-main-DEADID" ] || [ -f "$GC/todos-done-main-DEADID.lock" ] && echo NO || echo yes)" "yes"
check "E2 dead marker gone" "$([ -f "$GC/instance/DEADID" ] && echo NO || echo yes)" "yes"
check "E2 nomark file gone" "$([ -f "$GC/todos-seconds-main-NOMARK" ] && echo NO || echo yes)" "yes"
check "E2 nomark count gone" "$([ -f "$GC/todos-done-main-NOMARK" ] && echo NO || echo yes)" "yes"
check "E2 dead safe gone" "$([ -f "$GC/safe-to-exit-main-DEADID" ] && echo NO || echo yes)" "yes"
check "E2 nomark safe gone" "$([ -f "$GC/safe-to-exit-main-NOMARK" ] && echo NO || echo yes)" "yes"
# E2 PASS — all seven gone = yes: the dead instance's marker was reaped by liveness, and its
# time-file, its count-file (both + .lock), its safe-to-exit file, and the unmarked files were
# deleted. (This run's own instance marker is live during the sweep, so a real instance's file
# is never collateral.)

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
