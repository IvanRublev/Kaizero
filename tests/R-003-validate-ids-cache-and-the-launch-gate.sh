#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=85s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# R-003-validate-ids-cache-and-the-launch-gate — the todo-SHA cache, and the launch that refuses
# before any claude starts.
# - Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# - Tools beyond the shared prerequisites: none
# - Folder under $TESTROOT: $TESTROOT/R-003-validate-ids-cache-and-the-launch-gate
# - Wall-clock budget: its longest Run command is `timeout 30` — allow that command at least 30s
#
# What surrounds the two legs: the cache keyed by todo SHA short-circuits a second run at the same
# SHA and never lets a leg-2-skipped run mark a SHA clean for a later default run, a zero-mode
# launch against a duplicated-id todo refuses before any claude starts (report intact, exit 2),
# and the prompt no longer reads the ids itself. Each case gets its own throwaway repo. Format
# conversion of tests/R-003-validate-ids-cache-and-the-launch-gate.md (ISSUE-058c) — every case
# already existed and already passed.

TR="$TESTROOT/R-003-validate-ids-cache-and-the-launch-gate"; mkdir -p "$TR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/claude"; chmod +x "$TR/bin/claude"

# fresh repo under $TR/$1, one seed commit, real zero.sh emitted (no claude launch needed).
# Sets $ZERO for the caller and leaves cwd inside the new repo. The cache filename is a hash of
# (base, todo path, pattern) — not fixed — so callers look it up with cache_of "$d".
newrepo(){
  local d="$TR/$1"; mkdir -p "$d"; cd "$d"
  git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] Z0 seed\n' > todo.md; git add -A; git commit -qm init
  KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
  ZERO="$d/.git/zero.sh"
}
cache_of(){ ls "$1/.git"/todo-ids-ok-* 2>/dev/null | head -1; }

# R8 — the cache never lets a leg-2-skipped run mark a SHA clean for a later default run
newrepo r8
printf -- '- [ ] G1 was original text\n' > todo.md; git add -A; git commit -qm "g-add"
printf -- '- [ ] N1 noop\n' > todo.md; git add -A; git commit -qm "g-delete"
printf -- '- [ ] G1 totally different text\n- [ ] N1 noop\n' > todo.md; git add -A; git commit -qm "g-reuse-different"
KAIZERO_ID_HISTORY=0 "$ZERO" validate-ids; check "R8 history=0 exit" "$?" "0"
check "R8 no cache from history=0" "$([ -n "$(cache_of "$TR/r8")" ] && echo NO || echo yes)" "yes"
"$ZERO" validate-ids > "$TR/r8.out" 2>&1; check "R8 default still catches it" "$?" "1"
# R8 PASS — an ID_HISTORY=0 clean-current-file run writes no cache; the very next default
# run still walks history and still refuses.

# R9 — cache short-circuits a second run at the same SHA, proven by a git-log-recording shim
newrepo r9
printf -- '- [ ] C1 clean\n' > todo.md; git add -A; git commit -qm clean
"$ZERO" validate-ids; check "R9 first run" "$?" "0"
CACHE=$(cache_of "$TR/r9")
check "R9 cache written after clean run" "$([ -f "$CACHE" ] && echo yes || echo no)" "yes"

# a git shim on PATH that records the full argv of every invocation (the subcommand sits after
# leg2_ids' own `-C "$COORD_ROOT"`, never in $1), then execs the real git — a rollback-to-
# identical-content trick can't tell "cache trusted" from "a real walk answered the same way",
# only counting the actual git calls made can.
REALGIT=$(type -P git)
mkdir -p "$TR/gitbin"
cat > "$TR/gitbin/git" <<SHIM
#!/usr/bin/env bash
echo "\$*" >> "$TR/gitcalls.log"
exec "$REALGIT" "\$@"
SHIM
chmod +x "$TR/gitbin/git"

: > "$TR/gitcalls.log"
PATH="$TR/gitbin:$PATH" "$ZERO" validate-ids
check "R9 second run at unchanged sha" "$?" "0"
check "R9 walks nothing — no log call recorded" "$(grep -w -c log "$TR/gitcalls.log")" "0"

# negative control: the shim itself detects a walk once the cache file is gone — proves the
# assertion above is live and would fail if the short-circuit were removed, not vacuously true.
rm -f "$CACHE"
: > "$TR/gitcalls.log"
PATH="$TR/gitbin:$PATH" "$ZERO" validate-ids
check "R9 cache-deleted rerun walks — a log call is recorded" "$([ "$(grep -w -c log "$TR/gitcalls.log")" -ge 1 ] && echo yes || echo NO)" "yes"
# R9 PASS — first run = 0 with the cache written; a second validate-ids at the identical
# todo SHA returns 0 and the git shim on PATH records zero log calls, proving the walk itself
# was skipped rather than merely re-answering the same way; deleting the cache file makes the
# very same shim record a log call again, so the zero-calls assertion above is a real check on
# the short-circuit, not one a broken or absent cache would also pass.

# R10 — zero-mode integration: refuse before any claude launch, report intact, exit 2
newrepo r10
printf -- '- [ ] Z1 a\n- [ ] Z1 b\n' > todo.md; git add -A; git commit -qm "dup ids"
PATH="$TR/bin:$PATH" timeout 30 bash "$SCRIPT" --local-merge todo.md -t x > "$TR/r10.log" 2>&1
rc=$?
check "R10 exit" "$rc" "2"
check "R10 heading" "$(grep -c 'Task id validation failed' "$TR/r10.log")" "1"
check "R10 report present" "$(grep -c 'Execution stats' "$TR/r10.log")" "1"
# R10 PASS — no claude launch (nothing but the heading and the report in the log), exit 2.

# R11 — absence check: the prompt no longer reads the ids itself
check "R11 no direct id collection" "$(grep -c 'collect the ids' "$REAL_SCRIPT")" "0"
check "R11 calls validate-ids" "$([ "$(grep -c 'validate-ids' "$REAL_SCRIPT")" -ge 1 ] && echo yes || echo NO)" "yes"   # the prompt now calls the subcommand
# R11 PASS — both counts as wanted.

# R22 — the cache does not let a second todo file share a first todo file's clean verdict.
# Verified in-session before conversion (todo1 clean=0, todo2 dup=1, todo1 cache intact=yes).
newrepo r22
printf -- '- [ ] C1 clean\n' > todo.md; git add -A; git commit -qm "todo1"
"$ZERO" validate-ids; check "R22 todo1 clean" "$?" "0"
CACHE1=$(cache_of "$TR/r22")
printf -- '- [ ] E1 a\n- [ ] E1 b\n' > todo2.md; git add -A; git commit -qm "todo2"
KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo2.md -t x > /dev/null 2>&1
"$ZERO" validate-ids > "$TR/r22.out" 2>&1; check "R22 todo2 dup caught" "$?" "1"   # its own cache key, not todo1's
check "R22 todo1 cache intact" "$([ -n "$CACHE1" ] && [ -f "$CACHE1" ] && echo yes || echo no)" "yes"
# R22 PASS — two todo files added on one base never share a cache identity: TODO_PATH is
# part of the key.

# R23 — the cache does not let a loosened-pattern run mark a SHA clean for the default pattern.
# Verified in-session before conversion (pattern=. clean=0, default catches=1).
newrepo r23
printf -- '- [ ] fix bug\n' > todo.md; git add -A; git commit -qm "prose id"
KAIZERO_TASK_ID_PATTERN='.' "$ZERO" validate-ids; check "R23 pattern=. clean" "$?" "0"
"$ZERO" validate-ids > "$TR/r23.out" 2>&1; check "R23 default catches" "$?" "1"   # the loosened-pattern run's cache does not apply
# R23 PASS — KAIZERO_TASK_ID_PATTERN is part of the cache key, so the very next
# default-pattern run at the identical SHA still walks and still refuses.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
