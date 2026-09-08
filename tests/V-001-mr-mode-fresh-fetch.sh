#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# V-001-mr-mode-fresh-fetch — MR mode forks off a freshly fetched origin. A real, fetchable,
# no-host bare origin, advanced through a throwaway clone: a fresh fork carries the commit just
# pushed there, and the operator's own checkout stays untouched; an unreachable origin now REFUSES
# the claim outright (required, not best-effort, in MR mode — a claim that cannot learn origin's tip
# must not proceed on a stale local copy); and exactly three network round trips run per claim in this
# scenario (the required reachability probe, then the base fetch, structurally before
# `acquire_task`'s own reclaim lock, then `origin_branches_for_id`'s `ls-remote` once
# `acquire_target` has named the branch, under the per-task reclaim lock and nothing wider).
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/V-001-mr-mode-fresh-fetch
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# `acquire_task` forks an MR-mode task from `$TB` (`refs/remotes/origin/$TARGET_BASE`, baked by
# the doctor) — this scenario proves the ref is kept fresh: one best-effort `git fetch origin
# "+refs/heads/$TARGET_BASE:refs/remotes/origin/$TARGET_BASE"` runs at the very top of
# `acquire_task`, before `reap_dead_sessions` or any `flock`. A real, fetchable, no-host bare
# `origin` throughout (same shape as `U-002-the-doctors-mr-checks`'s `mkorigin`) — advanced through a THROWAWAY
# clone so the operator's own checkout never sees the push locally except via the claim's own
# fetch. `claim` goes through `ensure_owner` (a `claude` ancestor), so the driver runs under a
# copy of `bash` named `claude`, same trick as Scenario I.

# --- Setup ---
TV="$TESTROOT/V-001-mr-mode-fresh-fetch"; mkdir -p "$TV/bin"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktodo(){ ( cd "$1"; printf -- '- [ ] %s task\n' "$2" > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/$2.md"; git add -A; git commit -qm todo ); }
# real, fetchable, no-host origin — $1 = target dir; makes "$1-seed" (throwaway source),
# "$1-origin.git" (bare) and "$1" (the operator's own clone/checkout).
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1"; git config user.email t@t.t; git config user.name test )
}
# push a new commit straight to the bare origin, through a THROWAWAY clone — never touches
# "$1" itself, so a claim afterward sees a stale local checkout and a fresher origin.
advance_origin(){
  git clone -q "$1-origin.git" "$1-advance"
  ( cd "$1-advance"; echo y > g; git add g; git commit -qm advance; git push -q origin main )
}
printf '#!/usr/bin/env bash\nexit 0\n' > "$TV/bin/claude"; chmod +x "$TV/bin/claude"
# bootstrap: writes zero.sh into the coordination repo's git dir; never starts claude for real.
# KAIZERO_FORGE=gh: MR mode is the default and these fixtures' origin is a local bare
# path with no host, which only the override resolves to a forge.
boot(){ ( cd "$1"; PATH="$TV/bin:$PATH" KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$2" >/dev/null 2>&1 ); true; }

# V1 — a fresh fork carries origin's latest commit; the operator's own checkout is untouched
mkorigin "$TV/v1code"; mkrepo "$TV/v1plan"; mktodo "$TV/v1plan" V1
boot "$TV/v1code" "$TV/v1plan/todo.md"
advance_origin "$TV/v1code"       # pushed to the bare; "$TV/v1code" never fetched it itself

cat > "$TV/v1drive.sh" <<'DRIVE'
set -uo pipefail
REC="$TV/v1.rec"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
cd "$TV/v1plan"
FAILED=0; ERRORED=0
wt=$(bash .git/zero.sh claim V1); rc=$?
check "V1 claim exit" "$rc" "0"
# the just-pushed commit, on the forked branch's OWN history, not --all's every ref
check "V1 forked from origin >=1" "$([ "$(git -C "$wt" log --oneline | grep -c advance)" -ge 1 ] && echo yes || echo no)" "yes"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TV="$TV" bash "$TV/v1drive.sh" || FAILED=1
check "V1 operator branch unchanged" "$(git -C "$TV/v1code" symbolic-ref --short HEAD)" "main"
check "V1 operator tree clean" "$([ -z "$(git -C "$TV/v1code" status --porcelain)" ] && echo yes || echo NO)" "yes"
# V1 PASS — the forked branch carries the commit pushed to origin AFTER the launch-time
# bootstrap, proving the claim's own fetch (not a stale clone-time ref) supplied it; the
# target's main checkout stays on `main`, clean — a fetch never touches the operator's own tree.

# V2 — required: an unreachable origin refuses the claim, nothing created
mkorigin "$TV/v2code"; mkrepo "$TV/v2plan"; mktodo "$TV/v2plan" V2
boot "$TV/v2code" "$TV/v2plan/todo.md"
git -C "$TV/v2code" remote set-url origin "$TV/v2code-origin-MISSING.git"   # fetch fails fast, no network hang

cat > "$TV/v2drive.sh" <<'DRIVE'
set -uo pipefail
REC="$TV/v2.rec"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
cd "$TV/v2plan"
FAILED=0; ERRORED=0
out=$(bash .git/zero.sh claim V2 2>&1); rc=$?
check "V2 claim exit refused" "$([ "$rc" -ne 0 ] && echo yes || echo NO)" "yes"
check "V2 origin-unreachable message" "$(printf '%s' "$out" | grep -c 'acquire V2: origin unreachable — claim refused, nothing created')" "1"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TV="$TV" bash "$TV/v2drive.sh" || FAILED=1
check "V2 no worktree created" "$(git -C "$TV/v2code" worktree list | grep -c 'tt-V2-')" "0"
# V2 PASS — the fetch's own failure now refuses the claim outright: nothing forked
# off a local `$TB` that origin might have moved past — the fleet parks instead (the outage guard)
# until origin answers again.

# V3 — exactly three network round trips per claim (the required reachability probe, the base
# fetch, then the task's own branch lookup once acquired_target has named it)
REALGIT="$(type -P git)"   # baked by value, never by PATH search — see U15's own note on this
mkdir -p "$TV/fbin"
cat > "$TV/fbin/git" <<EOF
#!/usr/bin/env bash
case " \$* " in *" fetch "*|*" ls-remote "*) echo "\$*" >> "$TV/fetch.log" ;; esac
exec "$REALGIT" "\$@"
EOF
chmod +x "$TV/fbin/git"
mkorigin "$TV/v3code"; mkrepo "$TV/v3plan"; mktodo "$TV/v3plan" V3
boot "$TV/v3code" "$TV/v3plan/todo.md"

cat > "$TV/v3drive.sh" <<'DRIVE'
set -uo pipefail
REC="$TV/v3.rec"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
cd "$TV/v3plan"
PATH="$TV/fbin:$PATH" bash .git/zero.sh claim V3 >/dev/null
DRIVE
# shellcheck disable=SC2097,SC2098
TV="$TV" bash "$TV/v3drive.sh"
# V3's origin holds no task branch, so no FOURTH, branch-specific fetch runs
check "V3 network round trips" "$(wc -l < "$TV/fetch.log" 2>/dev/null | tr -d ' ')" "3"
# scoped to acquire_task's OWN function body — the base fetch line is byte-identical to the launch
# doctor's (run_doctor, a separate function), so a bare grep over the whole file could silently
# match the wrong one; extracting acquire_task's body first makes this locator fail if it ever
# drifts onto run_doctor's copy instead.
funcbody(){ awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print NR": "$0} p && /^}/ {exit}' "$REAL_SCRIPT"; }
ACQBODY=$(funcbody acquire_task)
# the base and branch fetches route through fetch_ref_safe (BUG 048: race-safe against a
# concurrent peer refreshing the same remote-tracking ref) rather than a literal `git fetch` —
# call-site greps here, not the old command text, so the locator still resolves to
# acquire_task's OWN two call sites and not fetch_ref_safe's single definition elsewhere in the file.
FETCHLINE=$(printf '%s\n' "$ACQBODY" | grep 'fetch_ref_safe "\$TARGET_BASE"' | head -1 | cut -d: -f1)
LOCKLINE=$(printf '%s\n' "$ACQBODY" | grep '"\$FLOCK_BIN" -n 9' | head -1 | cut -d: -f1)
check "V3 base fetch found inside acquire_task's own body" "$([ -n "$FETCHLINE" ] && echo yes || echo NO)" "yes"
check "V3 base fetch precedes the reclaim lock in source" "$([ "$FETCHLINE" -lt "$LOCKLINE" ] && echo yes || echo NO)" "yes"
BRANCHFETCHLINE=$(printf '%s\n' "$ACQBODY" | grep 'fetch_ref_safe "\$obr"' | head -1 | cut -d: -f1)
check "V3 branch fetch found inside acquire_task's own body" "$([ -n "$BRANCHFETCHLINE" ] && echo yes || echo NO)" "yes"
check "V3 branch fetch runs after acquire_target, once the branch is named" "$([ "$BRANCHFETCHLINE" -gt "$LOCKLINE" ] && echo yes || echo NO)" "yes"
# the doctor's own base-fetch line must NOT be the one this locator found — it lives in a
# different function entirely (required vs. best-effort, per this scenario's own D6/D-001 split).
DOCBODY=$(funcbody run_doctor)
DOCFETCHLINE=$(printf '%s\n' "$DOCBODY" | grep 'git -C "\$TARGET_ROOT" fetch origin .*TARGET_BASE' | head -1 | cut -d: -f1)
check "V3 acquire_task's fetch line differs from the doctor's" "$([ "$FETCHLINE" != "$DOCFETCHLINE" ] && echo yes || echo NO)" "yes"
# V3 PASS — `claim` makes exactly three network round trips here: the required reachability
# probe, then `$TARGET_BASE` (structurally before `acquire_task`'s own `"$FLOCK_BIN" -n 9`, the
# reclaim lock, and every other lock this claim could take — best-effort in `--local-merge` mode,
# required in MR mode), then the task's own branch once `acquire_target` has named it (necessarily
# after that lock, required — never best-effort — since a claim that cannot ask origin must refuse rather than
# guess). The locator resolves both fetch lines from inside `acquire_task`'s own function body, so
# it can never accidentally match `run_doctor`'s byte-identical base-fetch line instead.


# V4 — the claim-side half of the `--single-branch` clone case: the first claim's own base fetch
# creates the ref and forks from it, no `worktree add` fatal
mkdir -p "$TV/v4-seed"; ( cd "$TV/v4-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git checkout -q -b other; git commit -q --allow-empty -m other )
git clone -q --bare "$TV/v4-seed" "$TV/v4code-origin.git"
git clone -q --branch other --single-branch "$TV/v4code-origin.git" "$TV/v4code"
( cd "$TV/v4code"; git config user.email t@t.t; git config user.name test; git checkout -q -b main )
mkrepo "$TV/v4plan"; mktodo "$TV/v4plan" V4
boot "$TV/v4code" "$TV/v4plan/todo.md"   # TEST_EMIT: writes zero.sh only, the doctor itself is skipped (U8 covers the doctor's own fetch)
PRE4=$( cd "$TV/v4code"; git rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1 && echo yes || echo no )

cat > "$TV/v4drive.sh" <<'DRIVE'
set -uo pipefail
REC="$TV/v4.rec"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
cd "$TV/v4plan"
FAILED=0; ERRORED=0
wt=$(bash .git/zero.sh claim V4); rc=$?
check "V4 claim exit" "$rc" "0"
check "V4 worktree created" "$([ -d "$wt" ] && echo yes || echo NO)" "yes"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TV="$TV" bash "$TV/v4drive.sh" || FAILED=1
POST4=$( cd "$TV/v4code"; git rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1 && echo yes || echo no )
check "V4 ref absent before the claim" "$PRE4" "no"
check "V4 ref created by the claim's fetch" "$POST4" "yes"
# V4 PASS — `refs/remotes/origin/main` does not exist in the `--single-branch` clone before
# the claim (the doctor itself is skipped here — U8 already proves its own fetch creates the ref
# in exactly this fixture shape); the claim's own base fetch creates it and the fork completes
# with no `worktree add` fatal.

# V5 — characterization: an existing `<id>-…` branch is reattached, never re-pointed at the
# fetched base (pins `acquire_target`'s already-landed reattach rule)
mkorigin "$TV/v5code"; mkrepo "$TV/v5plan"; mktodo "$TV/v5plan" V5
boot "$TV/v5code" "$TV/v5plan/todo.md"
ZS5="$TV/v5plan/.git/zero.sh"
BR5=$( cd "$TV/v5plan" && bash "$ZS5" target-branch V5 task )
( cd "$TV/v5code" && git branch "$BR5" )
PRETIP5=$(git -C "$TV/v5code" rev-parse "$BR5")
advance_origin "$TV/v5code"   # origin's base moves past what BR5 forked from

cat > "$TV/v5drive.sh" <<'DRIVE'
set -uo pipefail
REC="$TV/v5.rec"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
cd "$TV/v5plan"
FAILED=0; ERRORED=0
wt=$(bash .git/zero.sh claim V5); rc=$?
check "V5 claim exit" "$rc" "0"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TV="$TV" bash "$TV/v5drive.sh" || FAILED=1
check "V5 branch not re-pointed" "$([ "$(git -C "$TV/v5code" rev-parse "$BR5")" = "$PRETIP5" ] && echo yes || echo NO)" "yes"
check "V5 branch differs from base" "$([ "$(git -C "$TV/v5code" rev-parse "$BR5")" != "$(git -C "$TV/v5code" rev-parse refs/remotes/origin/main)" ] && echo yes || echo NO)" "yes"
# V5 PASS — after the claim, `$BR5`'s tip is exactly what it was before the claim (the
# fetched base never re-points an existing branch) and still differs from `origin/main`'s tip.

# V6 — characterization: a sequence of claims runs against a target main checkout dirtied,
# switched to another branch, and left mid-rebase (pins that nothing in this mode touches the
# operator's own checkout)
mkorigin "$TV/v6code"; mkrepo "$TV/v6plan"
( cd "$TV/v6plan"; printf -- '- [ ] V6a task\n- [ ] V6b task\n' > todo.md; mkdir -p tasks
  printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/V6a.md; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/V6b.md
  git add -A; git commit -qm todo )
boot "$TV/v6code" "$TV/v6plan/todo.md"
( cd "$TV/v6code"
  git checkout -q -b other
  echo otherchange > f; git commit -qam other
  git checkout -q main
  echo mainchange > f; git commit -qam mainmove
  git checkout -q other
  echo untracked > u.txt
  git rebase main >/dev/null 2>&1 || true   # conflicts on f — leaves a mid-rebase, detached, dirty tree
)
BASE_TIP6=$(git -C "$TV/v6code" rev-parse main)

cat > "$TV/v6drive.sh" <<'DRIVE'
set -uo pipefail
REC="$TV/v6.rec"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
cd "$TV/v6plan"
FAILED=0; ERRORED=0
wta=$(bash .git/zero.sh claim V6a); rca=$?
bash .git/zero.sh release V6a >/dev/null 2>&1   # one-task-per-session: release before claiming a second
wtb=$(bash .git/zero.sh claim V6b); rcb=$?
check "V6 claim a exit" "$rca" "0"
check "V6 claim b exit" "$rcb" "0"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TV="$TV" bash "$TV/v6drive.sh" || FAILED=1
check "V6 base tip unchanged" "$([ "$(git -C "$TV/v6code" rev-parse main)" = "$BASE_TIP6" ] && echo yes || echo NO)" "yes"
# untouched by the claim path
check "V6 still mid-rebase" "$([ -d "$TV/v6code/.git/rebase-merge" ] || [ -d "$TV/v6code/.git/rebase-apply" ] && echo yes || echo NO)" "yes"
# V6 PASS — both claims complete with the target checkout dirty, detached and mid-rebase
# throughout, `main`'s tip never moves, and the rebase is still in progress afterward — nothing
# in the claim path forks from, checks out, advances or merges the operator's local base.
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
