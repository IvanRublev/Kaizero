#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=260s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# J-001-fleet-total — fleet TOTAL on the exit path. The exit-path report sums every peer's
# per-instance todo/token files into one fleet TOTAL, including a crashed peer that left files
# but no live marker.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/J-001-fleet-total
#
# The exit path (Ctrl+C or MAX_LOOPS) prints this instance's report and then a fleet-wide TOTAL
# summed from every peer's per-instance files for this base. No real claude and no parallelism:
# the stub fabricates two peer instances FROM INSIDE THE RUN, so they land after startup GC —
# PEER1 with a live marker, DEADPEER with files but no marker (a crashed peer's merged todos
# still belong in the total). The fabricated transcript repeats one requestId on three lines and
# carries the nested iterations[]/cache_creation copies, so the token sum also proves dedupe and
# no-double-count.

# Setup
TJ="$TESTROOT/J-001-fleet-total"; mkdir -p "$TJ/repo" "$TJ/bin"
cat > "$TJ/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"; mkdir -p "$GC/instance"
# PEER1: live marker (this stub's own pid) -> survives any later GC. DEADPEER: files only.
printf '%s\n%s\n' "$$" "$(ps -o lstart= -p $$ | awk '{$1=$1;print}')" > "$GC/instance/PEER1"
printf '100\n' > "$GC/todos-seconds-main-PEER1";   printf '2\n' > "$GC/todos-done-main-PEER1"
printf '50\n'  > "$GC/todos-seconds-main-DEADPEER"; printf '1\n' > "$GC/todos-done-main-DEADPEER"
tr="$GC/tx-PEER1.jsonl"; : > "$tr"
u='"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":248,"cache_creation":{"ephemeral_5m_input_tokens":148,"ephemeral_1h_input_tokens":100},"cache_read_input_tokens":1000,"iterations":[{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":248,"cache_read_input_tokens":1000}]'
for i in 1 2 3; do printf '{"requestId":"req_AAA","message":{"usage":{%s}}}\n' "$u" >> "$tr"; done
printf '%s\n' "$tr" > "$GC/transcripts-main-PEER1"
exit 0
EOF
chmod +x "$TJ/bin/claude"
cd "$TJ/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] J1 x\n' > todo.md; git add -A; git commit -qm init

# J1 — TOTAL equals the sum of the per-instance files
cd "$TJ/repo"
PATH="$TJ/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TJ/run.log" 2>&1
# the report never fails the exit path
check "J1 exit" "$?" "0"
sed -n '/TOTAL/,$p' "$TJ/run.log"
# PEER1 + DEADPEER, dead peer counted
check "J1 instances" "$(grep -o 'TOTAL ([0-9]*' "$TJ/run.log" | tr -dc 0-9)" "2"
# want 2m30s · 3 Landed = 100+50s, 2+1
check "J1 todos sum" "$(sed -n '/TOTAL/,$p' "$TJ/run.log" | grep -oE '2m30s.*3 Landed' | head -1)" "2m30s  .  3 Landed"
# want 1.2k = 10+20+248+1000, counted ONCE
check "J1 token sum" "$(sed -n '/TOTAL/,$p' "$TJ/run.log" | grep -oE 'Tokens: [^ ]+ Total')" "Tokens: 1.2k Total"
check "J1 categories" "$(sed -n '/TOTAL/,$p' "$TJ/run.log" | grep -oE 'In 10 . Out 20 . Cache write 248 . Cache read 1.0k')" "In 10 . Out 20 . Cache write 248 . Cache read 1.0k"
# glob, no aggregate file
# shellcheck disable=SC2010
check "J1 no registry" "$(ls "$TJ/repo/.git" | grep -cE '^(fleet|total)-')" "0"
# J1 PASS — exit = 0, instances = 2, the todo sum is 2m30s · 3 Landed, the token total is 1.2k
# with categories in 10 · out 20 · cache write 248 · cache read 1.0k (the requestId appeared on
# three lines and the nested iterations[]/ephemeral_* copies were ignored), and no registry = 0.

# J2 — solo run prints a singular TOTAL; unreadable peer files degrade, never lie
cd "$TJ/repo"
# no peers: this run's own id only
cat > "$TJ/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"; tr="$GC/tx-solo.jsonl"
printf '{"requestId":"req_S","message":{"usage":{"input_tokens":70,"output_tokens":30,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$tr"
printf '%s\n' "$tr" > "$KAIZERO_TRANSCRIPTS"   # the hook's job, done by hand: one id on disk
exit 0
EOF
chmod +x "$TJ/bin/claude"
PATH="$TJ/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TJ/solo.log" 2>&1 || true
# one id still gets the block; the heading names the count
check "J2 solo TOTAL" "$(grep -c 'TOTAL' "$TJ/solo.log")" "1"
check "J2 solo heading" "$(grep -o 'TOTAL (1 instance)' "$TJ/solo.log")" "TOTAL (1 instance)"
# each equals the per-instance block above
check "J2 solo figures" "$(sed -n '/TOTAL/,$p' "$TJ/solo.log" | grep -cE '0s  .  0 Landed|Tokens: 100 Total|In 70 . Out 30 . Cache write 0 . Cache read 0')" "3"
# summed wall times are not a duration
check "J2 solo run loop" "$(sed -n '/TOTAL/,$p' "$TJ/solo.log" | grep -c 'Kaizero run loop:')" "0"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TJ/bin/claude"       # writes nothing: zero ids on disk
PATH="$TJ/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TJ/none.log" 2>&1 || true
# n=0 stays silent, the guard is -ge 1 not -ge 0
check "J2 no-files TOTAL" "$(grep -c 'TOTAL' "$TJ/none.log")" "0"
cat > "$TJ/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
printf 'not-a-number\n' > "$GC/todos-seconds-main-GARB"; printf 'xx\n' > "$GC/todos-done-main-GARB"
printf '/nonexistent/transcript.jsonl\n' > "$GC/transcripts-main-GONE"
exit 0
EOF
chmod +x "$TJ/bin/claude"
PATH="$TJ/bin:$PATH" timeout 40 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TJ/degrade.log" 2>&1
check "J2 degrade exit" "$?" "0"
# zeroed todos row + n/a tokens
check "J2 degrade TOTAL" "$(sed -n '/TOTAL/,$p' "$TJ/degrade.log" | grep -cE '0s  .  0 Landed|Tokens: n/a')" "2"
# J2 PASS — solo TOTAL = 1 with the singular heading, solo figures = 3, solo run loop = 0 and
# no-files TOTAL = 0, degrade exit = 0 with degrade TOTAL = 2 (a garbled counter contributes 0
# and a missing transcript degrades to Tokens: n/a).

# J3 — the Tasks row names the landing route: `Landed` locally, `Handed off` in MR mode
# Same report path, MR mode: the fleet opens requests and a reviewer owns every merge, so the
# row counts Hand offs (docs/CONTEXT.md, Hand off), never landings. Two repositories plus a
# real, fetchable, no-host bare origin — so KAIZERO_FORGE names the forge — and a stub gh for
# the doctor's auth check. The stub claude fabricates one peer exactly as J1's does, so both the
# per-instance row and the TOTAL carry a nonzero count to label.
mkdir -p "$TJ/mrbin" "$TJ/mrstub"
mkdir -p "$TJ/code-seed"
( cd "$TJ/code-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init )
git clone -q --bare "$TJ/code-seed" "$TJ/code-origin.git"
git clone -q "$TJ/code-origin.git" "$TJ/code"
( cd "$TJ/code"; git config user.email t@t.t; git config user.name test )
mkdir -p "$TJ/plan"
( cd "$TJ/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] J3 x\n' > todo.md; git add -A; git commit -qm init )
# also answers check 5's --help/--json probes with the real default flag/field lists, so the
# doctor's flag-surface check does not itself refuse before the claim/hand-off is reached.
cat > "$TJ/mrbin/gh" <<'STUB'
#!/usr/bin/env bash
is_help=0
for a in "$@"; do [ "$a" = --help ] && is_help=1; done
if [ "$1 ${2:-}" = "pr list" ] && [ "${3:-}" = "--json" ] && [ $# -eq 3 ]; then
  printf '%s\n' 'number headRefOid baseRefName state url' >&2
  exit 1
fi
if [ "$is_help" = 1 ]; then
  case "$1 ${2:-}" in
    "pr list")     printf '%s\n' --repo --head --state --limit --json ;;
    "pr create")   printf '%s\n' --repo --head --base --title --body-file ;;
    "auth status") printf '%s\n' --hostname ;;
  esac
  exit 0
fi
exit 0
STUB
chmod +x "$TJ/mrbin/gh"
# the peer's files belong to the COORDINATION repository — claude runs with its cwd in the
# target, so `git rev-parse` there would name the wrong git dir; bake the coordination one in.
printf '#!/usr/bin/env bash\nGC=%q\n' "$TJ/plan/.git" > "$TJ/mrbin/claude"
cat >> "$TJ/mrbin/claude" <<'EOF'
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
mkdir -p "$GC/instance"
printf '%s\n%s\n' "$$" "$(ps -o lstart= -p $$ | awk '{$1=$1;print}')" > "$GC/instance/MRPEER"
printf '100\n' > "$GC/todos-seconds-main-MRPEER"; printf '2\n' > "$GC/todos-done-main-MRPEER"
exit 0
EOF
chmod +x "$TJ/mrbin/claude"
for t in flock git timeout jq; do p=$(command -v "$t") || { echo "REFUSING: '$t' not found — cannot build $TJ/mrbin" >&2; exit 1; }; ln -sf "$p" "$TJ/mrbin/$t"; done
( cd "$TJ/code"; PATH="$TJ/mrbin:/usr/bin:/bin" KAIZERO_FORGE=gh timeout 40 \
    env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" "$TJ/plan/todo.md" -t x > "$TJ/mr.log" 2>&1 )
check "J3 mr exit" "$?" "0"
sed -n '/execution stats/,$p' "$TJ/mr.log"
# the per-instance row and the TOTAL, both labelled by the route
check "J3 instance row" "$(grep -cE 'Tasks:.*.  [0-9]+ Handed off' "$TJ/mr.log")" "2"
# no row claims a landing the reviewer has not made
check "J3 never Landed" "$(grep -cE 'Tasks:.*Landed' "$TJ/mr.log")" "0"
# want 1m40s · 2 Handed off — the peer's own figures
check "J3 TOTAL count" "$(sed -n '/TOTAL/,$p' "$TJ/mr.log" | grep -oE '1m40s.*2 Handed off' | head -1)" "1m40s  .  2 Handed off"
# J1's local-merge run still says Landed
check "J3 local unchanged" "$(grep -cE 'Tasks:.*.  [0-9]+ Landed' "$TJ/run.log")" "2"
# J3 PASS — mr exit = 0, instance row = 2, never Landed = 0, TOTAL count = 1m40s · 2 Handed off,
# and local unchanged = 2: one report path, labelled Handed off when the run hands Tasks to
# reviewers and Landed when it merges them itself, with the local-merge wording untouched.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
