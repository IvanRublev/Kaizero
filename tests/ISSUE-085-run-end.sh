#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=180s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# ISSUE-085-run-end — how a run ends over `[🚧]`, `[?]` and other boxes: the closing report names
# each box group apart, no "proud" cheer unless every box is `[x]`, a `[?]` never keeps the run
# waiting, a blocked remainder with nobody holding a Task ends the run in place of the dependency
# wait, the stats rows count blocked Tasks, and the doctor names a `[🚧]` box with no branch.
# Needs real claude: no — a stub `claude` stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/ISSUE-085-run-end

TR="$TESTROOT/ISSUE-085-run-end"; mkdir -p "$TR/bin"
export STUB_LAUNCHED="$TR/launched"
cat > "$TR/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$STUB_LAUNCHED"
[ -n "${STUB_MARK:-}" ] && "$STUB_ZERO" no-claim-mark
if [ -n "${STUB_BLOCKED_FILE:-}" ]; then
  G="$(dirname "$STUB_ZERO")"
  printf '1\n' > "$G/todos-blocked-main-$KAIZERO_INSTANCE"; printf '65\n' > "$G/todos-seconds-main-$KAIZERO_INSTANCE"
fi
exit 0
EOF
chmod +x "$TR/bin/claude"

newrepo(){   # newrepo NAME 'todo text'
  local d="$TR/$1"; mkdir -p "$d"; cd "$d"
  git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- "$2" > todo.md; git add -A; git commit -qm init
  KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
  export STUB_ZERO="$d/.git/zero.sh"
}
run(){   # run NAME [env...] — one kaizero run in repo NAME, output to $TR/NAME.log
  local n=$1; shift
  : > "$STUB_LAUNCHED"
  ( cd "$TR/$n"; PATH="$TR/bin:$PATH" timeout 60 env KAIZERO_MAX_LOOPS=2 KAIZERO_WAIT_TICK=1 "$@" bash "$SCRIPT" --local-merge todo.md -t x > "$TR/$n.log" 2>&1 ); echo $?
}
launches(){ wc -l < "$STUB_LAUNCHED" | tr -d ' '; }

# A — no `[ ]` left, boxes mixed: the run ends at once with the box report
newrepo a '- [x] A1 landed\n- [🚧] A2 blocked\n- [?] A3 review\n- [✓] A4 other\n'
check "A1 exit" "$(run a)" "0"
check "A1 no session launched" "$(launches)" "0"
check "A1 report block" "$(grep -c '^Task boxes:' "$TR/a.log")" "1"
check "A1 Landed group" "$(grep -c 'Landed \[x\]: 1 · A1' "$TR/a.log")" "1"
check "A1 Blocked group apart" "$(grep -c 'Blocked \[🚧\]: 1 · A2' "$TR/a.log")" "1"
check "A1 review group apart" "$(grep -c 'Branches review needed \[?\]: 1 · A3' "$TR/a.log")" "1"
check "A1 other symbols group apart" "$(grep -c 'Other symbols: 1 · A4 \[✓\]' "$TR/a.log")" "1"
check "A1 no cheer over a mixed list" "$(grep -c 'is proud' "$TR/a.log")" "0"
check "A1 no ALL TASKS LANDED" "$(grep -c 'ALL TASKS LANDED' "$TR/a.log")" "0"

# B — every box `[x]`: no box report, the cheer stays
newrepo b '- [x] B1 one\n- [x] B2 two\n'
check "B1 exit" "$(run b)" "0"
check "B1 no box report" "$(grep -c '^Task boxes:' "$TR/b.log")" "0"
check "B1 cheer" "$(grep -c 'is proud' "$TR/b.log")" "1"

# C — the rest Landed, one `[?]` left: no wait, no session, the `[?]` named
newrepo c '- [x] C1 one\n- [?] C2 review\n'
check "C1 exit" "$(run c KAIZERO_DEPENDENCY_WAIT=5m)" "0"
check "C1 no session launched" "$(launches)" "0"
check "C1 no wait line" "$(grep -c 'Waiting for' "$TR/c.log")" "0"
check "C1 names the [?] Task" "$(grep -c 'Branches review needed \[?\]: 1 · C2' "$TR/c.log")" "1"

# D — a session claims nothing, nobody holds a Task, a `[🚧]` box exists: the run ends in place of
# the dependency wait, naming the blocked and the unclaimed Tasks
newrepo d '- [ ] D1 waits\n- [🚧] D2 blocked\n'
check "D1 exit" "$(run d STUB_MARK=1 KAIZERO_DEPENDENCY_WAIT=5m)" "0"
check "D1 one session only" "$(launches)" "1"
check "D1 no dependency wait started" "$(grep -c 'now blocked' "$TR/d.log")" "0"
check "D1 blocked Task named" "$(grep -c 'Blocked \[🚧\]: 1 · D2' "$TR/d.log")" "1"
check "D1 unclaimed Task named" "$(grep -c 'Unclaimed \[ \]: 1 · D1' "$TR/d.log")" "1"
check "D1 marker consumed" "$(ls "$TR/d/.git"/no-claim-* 2>/dev/null | wc -l | tr -d ' ')" "0"

# E — absence: with no `[🚧]` box the same block still waits (the wait is not replaced)
newrepo e '- [ ] E1 waits\n- [?] E2 review\n'
check "E1 exit" "$(run e STUB_MARK=1 KAIZERO_DEPENDENCY_WAIT=3s)" "0"
check "E1 dependency wait ran" "$([ "$(grep -c 'now blocked' "$TR/e.log")" -ge 1 ] && echo ok || echo none)" "ok"
check "E1 relaunched after the ceiling" "$(launches)" "2"

# F — stats: the instance report and the fleet TOTAL count a parked Task as blocked
newrepo f '- [ ] F1 one\n'
check "F1 exit" "$(run f STUB_BLOCKED_FILE=1)" "0"
check "F1 instance row counts it" "$([ "$(grep -c 'Tasks: .*0 Landed.*1 blocked' "$TR/f.log")" -ge 2 ] && echo ok)" "ok"
check "F1 fleet TOTAL row counts it" "$(awk '/TOTAL \(/{t=1} t && /Tasks:/{print; exit}' "$TR/f.log" | grep -c '0 Landed.*1 blocked')" "1"
check "F1 elapsed time shown" "$([ "$(grep -c 'Tasks: .*1m05s' "$TR/f.log")" -ge 2 ] && echo ok)" "ok"

# G — doctor: a `[🚧]` box whose Task branch is gone is named; one whose branch exists passes
newrepo g '- [🚧] G1 gone\n- [🚧] G2 kept\n'
git -C "$TR/g" branch main-task-G2
out=$(cd "$TR/g"; PATH="$TR/bin:$PATH" bash "$SCRIPT" --doctor --local-merge todo.md 2>&1); rc=$?
check "G1 doctor exits nonzero" "$([ "$rc" != 0 ] && echo yes)" "yes"
check "G1 names the Task with no branch" "$(printf '%s' "$out" | grep -c 'Task G1 is blocked')" "1"
check "G1 does not name the Task with a branch" "$(printf '%s' "$out" | grep -c 'Task G2')" "0"
git -C "$TR/g" branch main-task-G1
out=$(cd "$TR/g"; PATH="$TR/bin:$PATH" bash "$SCRIPT" --doctor --local-merge todo.md 2>&1); rc=$?
check "G2 doctor passes once every branch exists" "$rc" "0"

cd "$TESTROOT"
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
