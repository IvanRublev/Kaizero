#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=160s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# Y-001-always-on-park — `--always-on` parks instead of exiting. An all-landed todo parks with
# no claude launched instead of closing; a new commit adding an unchecked task wakes the park and
# launches claude for it; SIGTERM while parked still reaches the shared closer (report, fleet TOTAL,
# `dojo_proud`) and exits 143; without the flag the same all-landed todo still exits as before.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/Y-001-always-on-park
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# Same closer, same STOP plumbing as every other park (M, U) — `all_todos_done` breaking the
# loop is replaced by `wait_for_new_task` parking on it instead, only when `--always-on` is
# passed. All peers share `COORD_ROOT`'s own `.git` dir, so a landed commit is visible to
# `all_todos_done` the instant it lands; no fetch, no polling of anything but the repo already
# on disk.
#
# Every poll loop below greps for `'Always-on · every Task landed'`, not the bare substring
# `'always-on'` — this scenario's own folder is `$TESTROOT/Y-001-always-on-park`, so a bare
# `'always-on'` self-matches on the very first setup line that prints that path (e.g. `wrote
# .../Y-001-always-on-park/repo/.git/zero.sh`), long before the real park announcement
# (`kaizero.sh`'s `wait_for_new_task`) ever prints. The longer phrase is the literal text of
# that announcement and does not appear in the path.

# --- Setup ---
TY="$TESTROOT/Y-001-always-on-park"; mkdir -p "$TY/repo" "$TY/bin"
cat > "$TY/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$STUB_LAUNCHED"
exit 0
EOF
chmod +x "$TY/bin/claude"
cd "$TY/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [x] Y0 done already\n' > todo.md; git add -A; git commit -qm init
export STUB_LAUNCHED="$TY/launched"
export KAIZERO_WAIT_TICK=1

# Y1 — everything landed: parks (no claude, no exit) instead of closing
cd "$TY/repo"
: > "$STUB_LAUNCHED"
# MAX_LOOPS=1: the stub claude ticks nothing, so an unbounded run would just keep restarting
# it every RESTART_WAIT once Y2 resumes it below — capping loops isolates "did it resume and
# launch once" from "does it ever stop", which is KAIZERO_MAX_LOOPS's own job, not always-on's.
PATH="$TY/bin:$PATH" env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md --always-on -t x > "$TY/y1.log" 2>&1 &
Y1PID=$!
i=0; while ! grep -q 'Always-on · every Task landed' "$TY/y1.log" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
check "Y1 park line >=1" "$([ "$(grep -c 'Always-on · every Task landed' "$TY/y1.log")" -ge 1 ] && echo yes || echo no)" "yes"
# parked, not exited
check "Y1 still running" "$(kill -0 "$Y1PID" 2>/dev/null && echo yes || echo no)" "yes"
# no claude while parked
check "Y1 launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "0"
# Y1 PASS — `park line >= 1`, `still running = yes`, `launches = 0`.

# Y2 — a new commit adding an unchecked task wakes the park and launches claude for it
cd "$TY/repo"
printf -- '- [x] Y0 done already\n- [ ] Y2 new task\n' > todo.md; git add -A; git commit -qm "add Y2"
RC=0; wait "$Y1PID" || RC=$?
# MAX_LOOPS=1 hit right after the resumed launch
check "Y2 exit" "$RC" "0"
# parked run resumed and claimed the new task, no fetch/relaunch of the old one
check "Y2 launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "1"
# names what it woke for
check "Y2 wake line" "$(grep -c 'Y2 is claimable again · starting a session' "$TY/y1.log")" "1"
# Y2 PASS — `exit = 0`, `launches = 1`, `wake line = 1`.

# Y3 — SIGTERM while parked still lands at the closer, `dojo_proud` included, exit 143
cd "$TY/repo"
printf -- '- [x] Y0 done already\n- [x] Y2 new task\n' > todo.md; git add -A; git commit -qm "close Y2"
: > "$STUB_LAUNCHED"
PATH="$TY/bin:$PATH" bash "$SCRIPT" --local-merge todo.md --always-on -t x > "$TY/y3.log" 2>&1 &
Y3PID=$!
i=0; while ! grep -q 'Always-on · every Task landed' "$TY/y3.log" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
kill -TERM "$Y3PID" 2>/dev/null
RC=0; wait "$Y3PID" || RC=$?
# 128+15
check "Y3 exit" "$RC" "143"
check "Y3 launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "0"
# the park's own break still reaches the shared closer
check "Y3 closer ran" "$(grep -c 'Execution stats' "$TY/y3.log")" "1"
# all_todos_done was still true
check "Y3 proud line" "$(grep -c 'surveys the frozen field' "$TY/y3.log")" "1"
# Y3 PASS — `exit = 143`, `launches = 0`, `closer ran = 1`, `proud line = 1`.

# Y4 — without `--always-on`, the same all-landed todo still exits instead of parking (unchanged
# default)
cd "$TY/repo"
: > "$STUB_LAUNCHED"
PATH="$TY/bin:$PATH" timeout 20 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TY/y4.log" 2>&1
check "Y4 exit" "$?" "0"
check "Y4 launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "0"
# the flag is opt-in
check "Y4 no park line" "$(grep -c 'Always-on · every Task landed' "$TY/y4.log")" "0"
# Y4 PASS — `exit = 0`, `launches = 0`, `no park line = 0`.

# Y5 — MR mode parks on the same all-zeroed todo, and the park line names the route
# Same park, other landing route: a `[↑]` box is a Hand off, not a landing (docs/CONTEXT.md,
# **Hand off**), so the MR-mode park line must not say "landed". Two repositories plus a real,
# fetchable, no-host bare origin, `KAIZERO_FORGE` naming the forge, and a stub `gh`.
mkdir -p "$TY/mrbin" "$TY/code-seed" "$TY/plan"
( cd "$TY/code-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init )
git clone -q --bare "$TY/code-seed" "$TY/code-origin.git"
git clone -q "$TY/code-origin.git" "$TY/code"
( cd "$TY/code"; git config user.email t@t.t; git config user.name test )
( cd "$TY/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [x] Y5 done already\n' > todo.md; git add -A; git commit -qm init )
# auth status passes and everything else exits 0, as before; also answers check 5's --help/--json
# probes with the real default flag/field lists, so the doctor's flag-surface check
# does not itself refuse before the park is ever reached.
# every call recorded, so the "forge CLI invoked zero times during the park" absence check
# below can prove it from this scenario's own log rather than by inspection alone.
cat > "$TY/mrbin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TY/mrbin/gh-calls.log"
is_help=0
for a in "\$@"; do [ "\$a" = --help ] && is_help=1; done
if [ "\$1 \${2:-}" = "pr list" ] && [ "\${3:-}" = "--json" ] && [ \$# -eq 3 ]; then
  printf '%s\n' 'number headRefOid baseRefName state url' >&2
  exit 1
fi
if [ "\$1 \${2:-}" = "pr list" ] && [ \$# -gt 3 ]; then
  [ -f "$TY/mrbin/gh-list.out" ] && cat "$TY/mrbin/gh-list.out"
  exit 0
fi
if [ "\$is_help" = 1 ]; then
  case "\$1 \${2:-}" in
    "pr list")     printf '%s\n' --repo --head --state --limit --json ;;
    "pr create")   printf '%s\n' --repo --head --base --title --body-file ;;
    "auth status") printf '%s\n' --hostname ;;
  esac
  exit 0
fi
exit 0
STUB
chmod +x "$TY/mrbin/gh"
cp "$TY/bin/claude" "$TY/mrbin/claude"
for t in flock git timeout jq; do p=$(command -v "$t") || { echo "REFUSING: '$t' not found — cannot build $TY/mrbin" >&2; exit 1; }; ln -sf "$p" "$TY/mrbin/$t"; done
: > "$STUB_LAUNCHED"
: > "$TY/mrbin/gh-calls.log"
# the only thing backgrounded is the plain kaizero.sh command itself — $! is then that
# process's own pid, not a wrapper's (AC: "every stop signal the scenario sends is delivered to
# the kaizero.sh process itself, not to a wrapper the signal dies in").
cd "$TY/code"
PATH="$TY/mrbin:/usr/bin:/bin" KAIZERO_FORGE=gh \
    env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" "$TY/plan/todo.md" --always-on -t x > "$TY/y5.log" 2>&1 &
Y5PID=$!
i=0; while ! grep -q 'always-on · every Task' "$TY/y5.log" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done
# the MR route's wording
check "Y5 park line >=1" "$([ "$(grep -c 'Always-on · every Task handed off' "$TY/y5.log")" -ge 1 ] && echo yes || echo no)" "yes"
# no landing claimed for a handed-off box
check "Y5 never landed" "$(grep -c 'every Task landed' "$TY/y5.log")" "0"
check "Y5 still running" "$(kill -0 "$Y5PID" 2>/dev/null && echo yes || echo no)" "yes"
GHCALLS_AT_PARK=$(wc -l < "$TY/mrbin/gh-calls.log" | tr -d ' ')
sleep 3
GHCALLS_AFTER=$(wc -l < "$TY/mrbin/gh-calls.log" | tr -d ' ')
# zero forge calls while parked
check "Y5 gh calls during park" "$GHCALLS_AT_PARK -> $GHCALLS_AFTER" "$GHCALLS_AT_PARK -> $GHCALLS_AT_PARK"
kill -TERM "$Y5PID" 2>/dev/null; wait "$Y5PID" 2>/dev/null
cd "$TY/repo"
# Y1's local-merge park still says landed
check "Y5 local wording >=1" "$([ "$(grep -c 'Always-on · every Task landed' "$TY/y1.log")" -ge 1 ] && echo yes || echo no)" "yes"
# Y5 PASS — `park line >= 1`, `never landed = 0`, `still running = yes`, `local wording >= 1`,
# `gh calls during park` unchanged: one park, labelled by the route it parked on, with the forge
# untouched for the whole time it sits there.

# Y6 — a Release Todo List with no task lines at all: diagnosed exit, same with and without the
# flag
TY6="$TESTROOT/Y-001-always-on-park-y6"; mkdir -p "$TY6/repo"
cd "$TY6/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '## Release Todo List\n' > todo.md; git add -A; git commit -qm init
: > "$STUB_LAUNCHED"
PATH="$TY/bin:$PATH" timeout 20 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge todo.md -t x > "$TY6/plain.log" 2>&1
RC_PLAIN=$?
PATH="$TY/bin:$PATH" timeout 20 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge --always-on todo.md -t x > "$TY6/always.log" 2>&1
RC_ALWAYS=$?
check "Y6 plain diag >=1" "$([ "$(grep -c 'no task lines found' "$TY6/plain.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "Y6 always diag >=1" "$([ "$(grep -c 'no task lines found' "$TY6/always.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "Y6 same exit (got $RC_PLAIN vs $RC_ALWAYS)" "$([ "$RC_PLAIN" = "$RC_ALWAYS" ] && echo yes || echo NO)" "yes"
# never entered the park
check "Y6 no park line" "$(grep -c 'always-on · every Task' "$TY6/always.log")" "0"
check "Y6 no launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "0"
# Y6 PASS — both logs name the reason, same exit code, no park line, no launch: a list the
# parser finds no task lines in is not "everything landed", and never parks.

# Y7 — MR mode, an open `[↑]` request, `KAIZERO_REVIEW_WAIT=0`: `--always-on` exits exactly
# as without it
TY7="$TESTROOT/Y-001-always-on-park-y7"; mkdir -p "$TY7/plan"
# A bare '[↑]' box with no matching PR is what sync-mrs treats as unresolved and rewrites to
# '[?]' before this run ever gets a chance to judge it — so the fixture needs a real target
# branch and a stub PR that resolves it OPEN, the same way U-017's own park fixtures do, or the
# park path this case exists to test is never reached.
( cd "$TY/code"; git checkout -qb Y7-open-request; echo y > g; git add g; git commit -qm work
  git rev-parse HEAD > "$TY7/y7.sha"; git checkout -q main )
y7sha=$(cat "$TY7/y7.sha")
cat > "$TY/mrbin/gh-list.out" <<JSON
[{"number":7,"headRefOid":"$y7sha","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/7"}]
JSON
( cd "$TY7/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [\xe2\x86\x91] Y7 open request\n' > todo.md; git add -A; git commit -qm init )
: > "$STUB_LAUNCHED"
( cd "$TY/code"; PATH="$TY/mrbin:/usr/bin:/bin" KAIZERO_FORGE=gh \
    timeout 20 env KAIZERO_REVIEW_WAIT=0 KAIZERO_MAX_LOOPS=1 \
    bash "$SCRIPT" "$TY7/plan/todo.md" --always-on -t x > "$TY7/y7.log" 2>&1 )
# same as the identical command without --always-on
check "Y7 exit" "$?" "0"
# an open request never parks
check "Y7 no park line" "$(grep -c 'always-on · every Task' "$TY7/y7.log")" "0"
check "Y7 no launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "0"
rm -f "$TY/mrbin/gh-list.out"
# Y7 PASS — `exit = 0`, `no park line = 0`, `no launches = 0`: a todo whose only remaining box
# is an outstanding request is not "nothing outstanding", so `--always-on` never parks on it —
# it ends the run exactly as the same command does without the flag.

# Y8 — a duplicate id committed while parked ends the park through the same id-validation
# refusal a fresh launch gives
TY8="$TESTROOT/Y-001-always-on-park-y8"; mkdir -p "$TY8/repo"
cd "$TY8/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [x] Y8 done already\n' > todo.md; git add -A; git commit -qm init
: > "$STUB_LAUNCHED"
PATH="$TY/bin:$PATH" timeout 20 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge --always-on todo.md -t x > "$TY8/y8.log" 2>&1 &
Y8PID=$!
i=0; while ! grep -q 'Always-on · every Task' "$TY8/y8.log" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
printf -- '- [x] Y8 done already\n- [ ] D1 a\n- [ ] D1 b\n' > todo.md; git add -A; git commit -qm "add duplicate id"
RC=0; wait "$Y8PID" || RC=$?
# same as validate-ids's own refusal, a fresh launch on this todo gives
check "Y8 exit" "$RC" "2"
check "Y8 refusal >=1" "$([ "$(grep -c 'Task id validation failed' "$TY8/y8.log")" -ge 1 ] && echo yes || echo no)" "yes"
# no claude session launches
check "Y8 no launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "0"
# Y8 PASS — `exit = 2`, `refusal >= 1`, `no launches = 0`: the resumed pass re-runs the same
# start-of-pass gates a fresh launch runs, not just the park's own wake check.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
