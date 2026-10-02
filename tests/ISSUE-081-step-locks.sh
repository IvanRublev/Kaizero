#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=180s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# ISSUE-081-step-locks — `zero.sh validate-tasks` and `zero.sh resolve-tasks` each run their
# check-and-build under their own flock: one launcher walks, the others wait for its result.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/ISSUE-081-step-locks
# Wall-clock budget: seconds to a minute
# Cross-references: ISSUE-077-task-cache-and-progress.sh and BUG-078-resolved-list.sh cover the caches.

TR="$TESTROOT/ISSUE-081-step-locks"; mkdir -p "$TR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/claude"; chmod +x "$TR/bin/claude"

newrepo(){
  local d="$TR/$1" n="$2" i; mkdir -p "$d/tasks"; cd "$d"
  git init -q -b main; git config user.email t@t.t; git config user.name test
  { printf -- '- [x] Z0 seed\n'; for (( i = 1; i <= n; i++ )); do printf -- '- [ ] TASK-%s x\n' "$i"; done; } > todo.md
  for (( i = 1; i <= n; i++ )); do printf -- '### Acceptance criteria\n- [ ] a\n' > "tasks/TASK-$i.md"; done
  git add -A; git commit -qm init
  KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
  ZERO="$d/.git/zero.sh"; D="$d"
  sleep 1   # the validate-tasks verdict must be strictly newer than the Task files
}
# step <tag> <subcommand> — one run, display (fd 4) a plain file, status in $RC
step(){ "$B3" "$ZERO" "$2" > "$TR/$1.out" 2>&1 4>"$TR/$1.fd4"; RC=$?; }
vlock(){ ls "$D/.git/"validate-tasks-*.lock 2>/dev/null | head -1; }
rlock(){ ls "$D/.git/"resolve-tasks-*.lock 2>/dev/null | head -1; }
# hold <lockfile> <tag> — a live holder in the background; its pid is in $HPID
hold(){ bash -c 'exec 9>"$1"; flock 9; exec sleep 300' _ "$1" & HPID=$!; sleep 0.5; }

# L1 — sixteen launchers on a cold cache: one walk of each kind, the rest read the result
newrepo c1 30
for k in $(seq 1 16); do
  ( "$B3" "$ZERO" validate-tasks > "$TR/v$k.out" 2>&1 4>"$TR/v$k.fd4"
    "$B3" "$ZERO" resolve-tasks > "$TR/r$k.out" 2>&1 4>"$TR/r$k.fd4" ) &
done
wait
check "L1 exactly one validate-tasks walk" "$(cat "$TR"/v[0-9]*.fd4 | grep -c 'Validating task definitions *0/')" "1"
check "L1 exactly one resolved-list rebuild" "$(cat "$TR"/r[0-9]*.fd4 | grep -c 'Resolving task files *0/')" "1"
check "L1 every launcher silent on the captured streams" "$(cat "$TR"/[vr][0-9]*.out | wc -c | tr -d ' ')" "0"
check "L1 lock files in the git dir" "$(vlock | grep -c .):$(rlock | grep -c .)" "1:1"
check "L1 no lock file in the working tree" "$(find "$D" -type f -not -path '*/.git/*' -name '*.lock' | wc -l | tr -d ' ')" "0"
check "L1 git status clean" "$(git status --porcelain | wc -l | tr -d ' ')" "0"

# L2 — current cache: no lock taken, no wait, even with both locks held
hold "$(vlock)" v; H1=$HPID; hold "$(rlock)" r; H2=$HPID
step hit1 validate-tasks; check "L2 validate hit with lock held" "$RC:$(wc -c < "$TR/hit1.fd4" | tr -d ' ')" "0:0"
step hit2 resolve-tasks;  check "L2 resolve hit with lock held" "$RC:$(wc -c < "$TR/hit2.fd4" | tr -d ' ')" "0:0"
# todo-list takes no lock
check "L2 todo-list returns with both held" "$(timeout 20 "$B3" "$ZERO" todo-list > /dev/null 2>&1; echo $?)" "0"

# L3 — missing cache + held lock: the launcher waits and prints one waiting line; independent locks
rm -f "$D/.git/"task-defs-ok-* "$D/.git/"task-resolved-*
kill "$H2"; wait "$H2" 2>/dev/null   # release the resolve lock, keep the validate lock held by H1
step ind resolve-tasks
check "L3 resolve runs while the validate lock is held" "$RC" "0"
check "L3 resolve rebuilt" "$(grep -c 'Resolving task files *0/' "$TR/ind.fd4")" "1"
KAIZERO_PROGRESS_DELAY=0 "$B3" "$ZERO" validate-tasks > "$TR/w.out" 2>&1 4>"$TR/w.fd4" & WPID=$!
sleep 3
check "L3 waiter still waiting after 3 s" "$(kill -0 "$WPID" 2>/dev/null && echo alive || echo gone)" "alive"
check "L3 exactly one waiting line" "$(grep -c 'Waiting for another launcher' "$TR/w.fd4")" "1"
check "L3 no walk while waiting" "$(grep -c 'Validating task' "$TR/w.fd4")" "0"
kill -9 "$H1"   # the dead holder frees the lock at once
SECONDS=0; wait "$WPID"; WRC=$?
check "L3 waiter finishes within 5 s of the holder's death" "$([ "$SECONDS" -le 5 ] && echo ok || echo "slow $SECONDS")" "ok"
check "L3 waiter walked itself and is clean and silent" "$WRC:$(grep -c 'Validating task definitions *0/' "$TR/w.fd4"):$(wc -c < "$TR/w.out" | tr -d ' ')" "0:1:0"
check "L3 lock file left behind does not block" "$(step again validate-tasks; echo $RC)" "0"
check "L3 no temp file left" "$(ls "$D/.git/" | grep -c 'tmp')" "0"

# L4 — two waiters on one lock: the first to get it walks, the second hits on its second check
rm -f "$D/.git/"task-defs-ok-*
hold "$(vlock)" v; H1=$HPID
"$B3" "$ZERO" validate-tasks > /dev/null 2>&1 4>"$TR/p1.fd4" & W1=$!
"$B3" "$ZERO" validate-tasks > /dev/null 2>&1 4>"$TR/p2.fd4" & W2=$!
sleep 1; kill "$H1"; wait "$H1" 2>/dev/null; wait "$W1" "$W2"
check "L4 one walk between two waiters" "$(cat "$TR"/p[12].fd4 | grep -c 'Validating task definitions *0/')" "1"

# L5 — unopenable lock (a directory in its place): both steps run unlocked with usual results
rm -f "$D/.git/"task-defs-ok-* "$D/.git/"task-resolved-*
L=$(vlock); rm -f "$L"; mkdir "$L"; R=$(rlock); rm -f "$R"; mkdir "$R"
step u1 validate-tasks; check "L5 validate unlocked exit 0, silent, walked" "$RC:$(wc -c < "$TR/u1.out" | tr -d ' '):$(grep -c 'Validating task definitions *0/' "$TR/u1.fd4")" "0:0:1"
step u2 resolve-tasks;  check "L5 resolve unlocked exit 0, silent, rebuilt" "$RC:$(wc -c < "$TR/u2.out" | tr -d ' '):$(grep -c 'Resolving task files *0/' "$TR/u2.fd4")" "0:0:1"
rmdir "$L" "$R"

# L6 — a walk with findings leaves no cache, and a lock held by a live process never makes a step give up
rm -f "$D/.git/"task-defs-ok-*; printf 'no heading\n' > "$D/tasks/TASK-2.md"
step f1 validate-tasks; check "L6 findings exit 1" "$RC" "1"
check "L6 no cache after findings" "$(ls "$D/.git/" | grep -c '^task-defs-ok-')" "0"

# L7 — SIGTERM on the holder frees the lock; the locks are independent the other way round; no display = silent wait
printf -- '### Acceptance criteria\n- [ ] a\n' > "$D/tasks/TASK-2.md"; sleep 1
rm -f "$D/.git/"task-defs-ok-* "$D/.git/"task-resolved-*; step re1 validate-tasks; step re2 resolve-tasks   # recreate the lock files L5 removed
rm -f "$D/.git/"task-defs-ok-* "$D/.git/"task-resolved-*
hold "$(rlock)" r; H2=$HPID
step ind2 validate-tasks; check "L7 validate runs while the resolve lock is held" "$RC:$(grep -c 'Validating task definitions *0/' "$TR/ind2.fd4")" "0:1"
"$B3" "$ZERO" resolve-tasks > "$TR/n.out" 2>&1 4>&- & WPID=$!
sleep 1.5
check "L7 waiter without a display descriptor waits silently" "$(kill -0 "$WPID" 2>/dev/null && echo alive):$(wc -c < "$TR/n.out" | tr -d ' ')" "alive:0"
kill -TERM "$H2"; wait "$H2" 2>/dev/null
SECONDS=0; wait "$WPID"; check "L7 SIGTERM on the holder frees the lock" "$?:$([ "$SECONDS" -le 5 ] && echo ok)" "0:ok"

cd "$TESTROOT"
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
