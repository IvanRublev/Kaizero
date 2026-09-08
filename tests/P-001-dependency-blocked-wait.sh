#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=260s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# P-001-dependency-blocked-wait — the dependency-blocked wait (KAIZERO_DEPENDENCY_WAIT). This
# is a format conversion of tests/P-001-dependency-blocked-wait.md (git history) per ISSUE-058c:
# same fixtures, same commands, same assertions, moved from markdown-with-echo to a single self
# contained shell script whose comparisons go through the shared check() helper instead of raw
# echo lines. No new behavior is being asserted here.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/P-001-dependency-blocked-wait

# Setup (unchanged from the .md's own Setup block)
TP="$TESTROOT/P-001-dependency-blocked-wait"; mkdir -p "$TP/repo" "$TP/bin"
cd "$TP/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] P1 x\n' > todo.md; git add -A; git commit -qm init
KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md >/dev/null 2>&1   # writes .git/zero.sh once, up front
export STUB_ZERO="$TP/repo/.git/zero.sh"
export STUB_LAUNCHED="$TP/launched"

# P1 — a marker blocks relaunch until the todo blob's SHA changes; a distinct waiting line
# (unchanged assertions from the .md; echo/want lines converted to check() calls)
cd "$TP/repo"
: > "$STUB_LAUNCHED"
cat > "$TP/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$STUB_LAUNCHED"
n=$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')
[ "$n" -eq 1 ] && "$STUB_ZERO" no-claim-mark   # only the FIRST launch marks the block, so the
exit 0                                          # marker file is provably gone once the wait ends
EOF
chmod +x "$TP/bin/claude"
( i=0; while ! grep -q 'now blocked' "$TP/p1.log" 2>/dev/null && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
  cd "$TP/repo"; sed -i'' -e 's/- \[ \]/- [x]/' todo.md; git add -A; git commit -qm 'flip P1' ) > "$TP/flipper1.out" 2>&1 &
FLIPPER=$!
PATH="$TP/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=2 KAIZERO_WAIT_TICK=1 KAIZERO_DEPENDENCY_WAIT=5m bash "$SCRIPT" --local-merge todo.md -t x > "$TP/p1.log" 2>&1
check "P1 exit" "$?" "0"
# one that marked the block, one after the flip broke it
check "P1 launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "2"
# its own wording, not wait_for_claimable's
check "P1 dependency line" "$([ "$(grep -c 'Waiting for a claimable Task (now blocked 1)' "$TP/p1.log")" -ge 1 ] && echo ok || echo none)" "ok"
# P1 is never peer-held, so that wait never runs here
check "P1 no plain line" "$(grep -c '^❄ waiting for a claimable Task · ' "$TP/p1.log")" "0"
# consumed once read
check "P1 marker gone" "$(ls "$TP/repo/.git"/no-claim-* 2>/dev/null | wc -l | tr -d ' ')" "0"
wait "$FLIPPER" 2>/dev/null || true
# P1 PASS — exit = 0, launches = 2, dependency line >= 1, no plain line = 0, marker gone = 0.

# P2 — a peer's marker going stale (its worktree dies) breaks the wait even though the blob is unchanged
cd "$TP/repo"
printf -- '- [ ] P2 x\n- [ ] P2H y\n' >> todo.md; git add -A; git commit -qm 'add P2 tasks'
sleep 600 > "$TP/peer2.out" 2>&1 & PEER2=$!
git worktree add -q -b main-task-P2H "$TP/wt2h" main
printf '%s\n%s\n%s\n%s\n' "$PEER2" "$(ps -o lstart= -p "$PEER2" | awk '{$1=$1;print}')" "$(date +%s)" "PEERINST" > "$TP/wt2h/.owner"
mkdir -p "$TP/repo/.git/session"
printf '%s\n%s\n' "$(ps -o lstart= -p "$PEER2" | awk '{$1=$1;print}')" "P2H" > "$TP/repo/.git/session/$PEER2"
: > "$STUB_LAUNCHED"
( i=0; while ! grep -q 'now blocked' "$TP/p2.log" 2>/dev/null && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
  kill "$PEER2" 2>/dev/null ) > "$TP/killer.out" 2>&1 &
KILLER=$!
PATH="$TP/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=2 KAIZERO_WAIT_TICK=1 KAIZERO_DEPENDENCY_WAIT=5m bash "$SCRIPT" --local-merge todo.md -t x > "$TP/p2.log" 2>&1
check "P2 exit" "$?" "0"
# the wait broke on the held-ids change, no todo edit at all
check "P2 launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "2"
wait "$KILLER" 2>/dev/null || true
git worktree remove --force "$TP/wt2h" 2>/dev/null || true; git branch -qD main-task-P2H 2>/dev/null || true
# P2 PASS — exit = 0, launches = 2.

# P3 — KAIZERO_DEPENDENCY_WAIT=0 relaunches immediately every cycle
cd "$TP/repo"
printf -- '- [ ] P3 x\n' >> todo.md; git add -A; git commit -qm 'add P3'
: > "$STUB_LAUNCHED"
PATH="$TP/bin:$PATH" timeout 20 env KAIZERO_MAX_LOOPS=2 KAIZERO_WAIT_TICK=1 KAIZERO_DEPENDENCY_WAIT=0 bash "$SCRIPT" --local-merge todo.md -t x > "$TP/p3.log" 2>&1
check "P3 exit" "$?" "0"
# 0 disables the wait outright
check "P3 launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "2"
check "P3 no wait line" "$(grep -c 'now blocked' "$TP/p3.log")" "0"
# P3 PASS — exit = 0, launches = 2, no wait line = 0.

# P4 — an unchanged signature past the ceiling forces a relaunch anyway
cd "$TP/repo"
printf -- '- [ ] P4 x\n' >> todo.md; git add -A; git commit -qm 'add P4'
: > "$STUB_LAUNCHED"
PATH="$TP/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=2 KAIZERO_WAIT_TICK=1 KAIZERO_DEPENDENCY_WAIT=6s bash "$SCRIPT" --local-merge todo.md -t x > "$TP/p4.log" 2>&1
check "P4 exit" "$?" "0"
# nothing changed, so the ceiling itself ended the wait
check "P4 launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "2"
check "P4 marker gone" "$(ls "$TP/repo/.git"/no-claim-* 2>/dev/null | wc -l | tr -d ' ')" "0"
# P4 PASS — exit = 0, launches = 2, marker gone = 0.

# P5 — absence check: no marker written, relaunch timing and output are unaffected
cd "$TP/repo"
printf -- '- [ ] P5 x\n' >> todo.md; git add -A; git commit -qm 'add P5'
cat > "$TP/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$STUB_LAUNCHED"
exit 0
EOF
chmod +x "$TP/bin/claude"
: > "$STUB_LAUNCHED"
PATH="$TP/bin:$PATH" timeout 20 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge todo.md -t x > "$TP/p5.log" 2>&1
check "P5 exit" "$?" "0"
# a claude that never marks a block is never made to wait
check "P5 launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "2"
# no marker, no new poll
check "P5 no wait line" "$(grep -c 'now blocked' "$TP/p5.log")" "0"
# P5 PASS — exit = 0, launches = 2, no wait line = 0.

# P6 — -h/--help names the variable
H="$(bash "$SCRIPT" -h)"
check "P6 names the var" "$(printf '%s' "$H" | grep -c 'KAIZERO_DEPENDENCY_WAIT=duration')" "1"
# P6 PASS — names the var = 1.

# P7 — a Task file landing mid-wait does not break it: only the todo blob or held ids do
cd "$TP/repo"
printf -- '- [ ] P7 x\n' >> todo.md; git add -A; git commit -qm 'add P7'
mkdir -p "$TP/repo/tasks"
cat > "$TP/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$STUB_LAUNCHED"
n=$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')
[ "$n" -eq 1 ] && "$STUB_ZERO" no-claim-mark   # only the FIRST launch marks the block, same as P1
exit 0
EOF
chmod +x "$TP/bin/claude"
: > "$STUB_LAUNCHED"
( i=0; while ! grep -q 'now blocked' "$TP/p7.log" 2>/dev/null && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
  printf -- '- [ ] c\n' > "$TP/repo/tasks/P7.md" ) > "$TP/fixer.out" 2>&1 &   # a Task file lands mid-wait, uncommitted — todo.md itself untouched
FIXER=$!
PATH="$TP/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=2 KAIZERO_WAIT_TICK=1 KAIZERO_DEPENDENCY_WAIT=6s bash "$SCRIPT" --local-merge todo.md -t x > "$TP/p7.log" 2>&1
check "P7 exit" "$?" "0"
# the Task file landing is invisible to the signature; only the ceiling ended the wait
check "P7 launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "2"
wait "$FIXER" 2>/dev/null || true
# P7 PASS — exit = 0, launches = 2.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
