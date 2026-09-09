#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=120s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# R-011-merge-land-gate-evidence — `merge_task`/`mr_task` refuse to land a Task file whose
# TASK-056 gate notes or ticked-criterion evidence lines are missing, verified — not merely
# trusted — at land time. TASK-058f.

TR="$TESTROOT/R-011-merge-land-gate-evidence"; mkdir -p "$TR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/claude"; chmod +x "$TR/bin/claude"

# G1 — direct unit tests of check_gate_evidence/ac_land_gate_findings (plus the ac_section_bounds
# helper they share with check_ac_file), sourced straight out of the emitted zero.sh (same idiom
# T-013's T23 uses to eval one function at a time) — precise wording checks with no git/worktree
# overhead.
newrepo(){
  local d="$TR/$1"; mkdir -p "$d"; cd "$d"
  git init -q -b main; git config user.email t@t.t; git config user.name test
  printf -- '- [ ] Z0 seed\n' > todo.md; git add -A; git commit -qm init
  KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
  ZERO="$d/.git/zero.sh"
}
newrepo unit
eval "$(sed -n '/^ac_section_bounds() {/,/^}$/p' "$ZERO")"
eval "$(sed -n '/^ac_land_gate_findings() {/,/^}$/p' "$ZERO")"
eval "$(sed -n '/^check_gate_evidence() {/,/^}$/p' "$ZERO")"

U="$TR/unit"

# both gate notes missing, both criteria ticked and evidenced
cat > "$U/f-missing-both.md" <<'EOF'
### Acceptance criteria

- [x] first thing works
  > 2026-09-01 10:00-0700 verified via unit test
- [x] second thing works
  > 2026-09-01 10:05-0700 verified via integration test
EOF
out=$(check_gate_evidence "$U/f-missing-both.md"); rc=$?
check "G1 missing-both rc" "$rc" "1"
check "G1 missing-both names AC gate" "$(printf '%s' "$out" | grep -c 'missing gate note: Acceptance criteria gate')" "1"
check "G1 missing-both names SR gate" "$(printf '%s' "$out" | grep -c 'missing gate note: Agentic self-review gate')" "1"

# only the self-review gate missing
cat > "$U/f-missing-sr.md" <<'EOF'
### Acceptance criteria

- [x] first thing works
  > 2026-09-01 10:00-0700 verified via unit test

> Acceptance criteria gate: passed 2026-09-01 10:10-0700
EOF
out=$(check_gate_evidence "$U/f-missing-sr.md"); rc=$?
check "G1 missing-sr rc" "$rc" "1"
check "G1 missing-sr names only SR gate" "$(printf '%s' "$out" | grep -c 'missing gate note:')" "1"
check "G1 missing-sr names the right one" "$(printf '%s' "$out" | grep -c 'missing gate note: Agentic self-review gate')" "1"

# both gates present, one ticked criterion has no evidence line
cat > "$U/f-missing-evidence.md" <<'EOF'
### Acceptance criteria

- [x] first thing works
  > 2026-09-01 10:00-0700 verified via unit test
- [x] second thing has no evidence line at all

> Acceptance criteria gate: passed 2026-09-01 10:10-0700
> Agentic self-review gate: passed 2026-09-01 10:11-0700
EOF
out=$(check_gate_evidence "$U/f-missing-evidence.md"); rc=$?
check "G1 missing-evidence rc" "$rc" "1"
check "G1 missing-evidence no gate finding" "$(printf '%s' "$out" | grep -c 'missing gate note:')" "0"
check "G1 missing-evidence quotes criterion" "$(printf '%s' "$out" | grep -c 'no evidence line: - \[x\] second thing has no evidence line at all')" "1"

# clean: both gates, every ticked criterion evidenced — no refusal
cat > "$U/f-clean.md" <<'EOF'
### Acceptance criteria

- [x] first thing works
  > 2026-09-01 10:00-0700 verified via unit test
- [x] second thing works
  > 2026-09-01 10:05-0700 verified via integration test
- [ ] a human-only step, left unticked

> Acceptance criteria gate: passed 2026-09-01 10:10-0700
> Agentic self-review gate: passed 2026-09-01 10:11-0700
EOF
out=$(check_gate_evidence "$U/f-clean.md"); rc=$?
check "G1 clean rc" "$rc" "0"
check "G1 clean no findings" "${#out}" "0"

# TASK-059b: a failed-manual-noted gate clears the local gate the same way a passed-noted one
# does — same fixture shape as f-clean, only the AC gate note's outcome differs.
cat > "$U/f-clean-failed-manual.md" <<'EOF'
### Acceptance criteria

- [x] first thing works
  > 2026-09-01 10:00-0700 verified via unit test
- [x] second thing works
  > 2026-09-01 10:05-0700 verified via integration test
- [ ] a human-only step, left unticked

> Acceptance criteria gate: failed-manual 2026-09-01 10:10-0700
> Agentic self-review gate: passed 2026-09-01 10:11-0700
EOF
out=$(check_gate_evidence "$U/f-clean-failed-manual.md"); rc=$?
check "G1 failed-manual rc" "$rc" "0"
check "G1 failed-manual no findings" "${#out}" "0"

# TASK-059b absence check: an unrecognized AC gate outcome string (plain "failed", or a
# misspelling) still refuses exactly like a missing note.
cat > "$U/f-unrecognized-outcome.md" <<'EOF'
### Acceptance criteria

- [x] first thing works
  > 2026-09-01 10:00-0700 verified via unit test

> Acceptance criteria gate: failed 2026-09-01 10:10-0700
> Agentic self-review gate: passed 2026-09-01 10:11-0700
EOF
out=$(check_gate_evidence "$U/f-unrecognized-outcome.md"); rc=$?
check "G1 unrecognized-outcome rc" "$rc" "1"
check "G1 unrecognized-outcome names AC gate" "$(printf '%s' "$out" | grep -c 'missing gate note: Acceptance criteria gate')" "1"

# TASK-059b absence check: the Agentic self-review gate line stays passed-only — failed-manual
# on THAT line still refuses, even though the AC gate line now accepts it.
cat > "$U/f-sr-failed-manual.md" <<'EOF'
### Acceptance criteria

- [x] first thing works
  > 2026-09-01 10:00-0700 verified via unit test

> Acceptance criteria gate: passed 2026-09-01 10:10-0700
> Agentic self-review gate: failed-manual 2026-09-01 10:11-0700
EOF
out=$(check_gate_evidence "$U/f-sr-failed-manual.md"); rc=$?
check "G1 sr-failed-manual rc" "$rc" "1"
check "G1 sr-failed-manual names SR gate" "$(printf '%s' "$out" | grep -c 'missing gate note: Agentic self-review gate')" "1"

# Absence check: an unticked criterion with no evidence line is never a finding — proven above
# (f-clean's own unticked line) by "G1 clean rc"/"G1 clean no findings" already passing.

# Absence check: an extra, stale-looking third gate line beyond the two named notes is not
# refused for that alone.
cat > "$U/f-stale-extra.md" <<'EOF'
### Acceptance criteria

- [x] first thing works
  > 2026-09-01 09:00-0700 an earlier, stale evidence line
  > 2026-09-01 10:00-0700 verified via unit test

> Acceptance criteria gate: passed 2026-08-01 09:00-0700
> Acceptance criteria gate: passed 2026-09-01 10:10-0700
> Agentic self-review gate: passed 2026-09-01 10:11-0700
EOF
out=$(check_gate_evidence "$U/f-stale-extra.md"); rc=$?
check "G1 stale-extra rc" "$rc" "0"
check "G1 stale-extra no findings" "${#out}" "0"
# G1 PASS — check_gate_evidence/ac_land_gate_findings report exactly the missing gate note(s) or
# the exact text of an unevidenced ticked criterion, never flag an unticked criterion, and never
# refuse a file for carrying stale extra gate/evidence lines alongside the required ones.

# G2 — `zero.sh merge` integration: the land gate refuses a Task file missing both gate notes,
# quoting both; a fully ticked and evidenced Task file proceeds exactly as before this task.
newrepo two
own_session "$TR/two-session"
mkdir -p tasks
printf -- '- [ ] G1a clean task\n- [ ] G2a ungated task\n- [ ] G3a tick-after-claim task\n' > todo.md
cat > tasks/G1a.md <<'EOF'
### Acceptance criteria

- [x] a thing works
  > 2026-09-01 10:00-0700 verified
- [ ] a human-only step

> Acceptance criteria gate: passed 2026-09-01 10:10-0700
> Agentic self-review gate: passed 2026-09-01 10:11-0700
EOF
cat > tasks/G2a.md <<'EOF'
### Acceptance criteria

- [x] a thing works
EOF
cat > tasks/G3a.md <<'EOF'
### Acceptance criteria

- [x] a thing works
EOF
git add -A; git commit -qm "add G1a/G2a/G3a task files"
KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
ZERO="$TR/two/.git/zero.sh"

t1=$("$ZERO" claim G1a)
echo work1 > "$t1/n1.txt"; git -C "$t1" add n1.txt; git -C "$t1" commit -qm work1
out=$("$ZERO" merge G1a "$t1" 2>&1); rc=$?
check "G2 clean-task merge exit" "$rc" "0"
check "G2 clean-task box ticked" "$(grep -c '\[x\] G1a' todo.md)" "1"

t2=$("$ZERO" claim G2a)
echo work2 > "$t2/n2.txt"; git -C "$t2" add n2.txt; git -C "$t2" commit -qm work2
out=$("$ZERO" merge G2a "$t2" 2>&1); rc=$?
check "G2 ungated-task merge exit" "$rc" "5"
# 3 lines: G2a.md's one ticked, unevidenced criterion plus both missing gate notes, each its own
# "land gate failed at local: " line.
check "G2 says land gate failed" "$(printf '%s' "$out" | grep -c 'land gate failed at local')" "3"
check "G2 names AC gate missing" "$(printf '%s' "$out" | grep -c 'missing gate note: Acceptance criteria gate')" "1"
check "G2 names SR gate missing" "$(printf '%s' "$out" | grep -c 'missing gate note: Agentic self-review gate')" "1"
check "G2 box unchecked" "$(grep -c '\[ \] G2a' todo.md)" "1"
"$ZERO" release G2a "$t2" >/dev/null 2>&1 || true
# G2 PASS — a fully ticked and evidenced Task file lands through `zero.sh merge` exactly as
# before this task; a Task file missing both gate notes is refused at exit 5, stderr naming
# both, and the box is left unchecked.

# G2b — the realistic tick flow: the AC edit + gate notes are made after claiming, directly in
# $COORD_ROOT (the "even when that is the checkout your cwd is in" exception the zeroing
# algorithm carves out for the Task file), landed via `commit_ac_checkoff` exactly as a real
# session does — never pre-baked into the file before the branch forked, unlike G1a/G2a above.
# The task worktree's own copy of the Task file is therefore stale by design; the gate must still
# read the fresh, real content.
t5=$("$ZERO" claim G3a)
cat > "$TR/two/tasks/G3a.md" <<'EOF'
### Acceptance criteria

- [x] a thing works
  > 2026-09-01 10:00-0700 verified

> Acceptance criteria gate: passed 2026-09-01 10:10-0700
> Agentic self-review gate: passed 2026-09-01 10:11-0700
EOF
"$ZERO" commit_ac_checkoff G3a > /dev/null
echo work5 > "$t5/n5.txt"; git -C "$t5" add n5.txt; git -C "$t5" commit -qm work5
out=$("$ZERO" merge G3a "$t5" 2>&1); rc=$?
check "G2b tick-after-claim merge exit" "$rc" "0"
check "G2b tick-after-claim box ticked" "$(grep -c '\[x\] G3a' todo.md)" "1"
# G2b PASS — the land gate reads $COORD_ROOT's own, fresh copy of the Task file, not the task
# worktree's stale pre-tick snapshot.

# G3 — `zero.sh mr` applies the identical check at the identical point, before anything is
# pushed: MR mode's two-repository layout (target `three-code`, coordination `three-plan`), a
# real fetchable bare origin for the target (same `mkorigin` idiom as X-001), plus a stub `gh`
# that always succeeds — so a pre-fix run proves it would otherwise push and open a request
# (the negative control this RED phase needs), and a post-fix run proves the new gate refuses
# before either.
cat > "$TR/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr create") printf 'https://example.invalid/pr/1\n' ;;
  "pr list")   printf '[]' ;;
esac
exit 0
STUB
chmod +x "$TR/bin/gh"
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1"; git config user.email t@t.t; git config user.name test )
}
mkplan(){
  mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
    mkdir -p tasks
    printf -- '- [ ] M1 no-evidence task\n- [ ] M2 missing-both task\n- [ ] M3 missing-sr task\n- [ ] M4 fixed-on-claim-branch task\n' > todo.md
    cat > tasks/M1.md <<'EOF'
### Acceptance criteria

- [x] a thing works

> Acceptance criteria gate: passed 2026-09-01 10:10-0700
> Agentic self-review gate: passed 2026-09-01 10:11-0700
EOF
    cat > tasks/M2.md <<'EOF'
### Acceptance criteria

- [x] a thing works
  > 2026-09-01 10:00-0700 verified
EOF
    cat > tasks/M3.md <<'EOF'
### Acceptance criteria

- [x] a thing works
  > 2026-09-01 10:00-0700 verified

> Acceptance criteria gate: passed 2026-09-01 10:10-0700
EOF
    cat > tasks/M4.md <<'EOF'
### Acceptance criteria

- [x] a thing works
EOF
    git add -A; git commit -qm "add M1/M2/M3/M4 task files" )
}
mkorigin "$TR/three-code"; mkplan "$TR/three-plan"
PATH="$TR/bin:$PATH"
( cd "$TR/three-code"; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh bash "$SCRIPT" "$TR/three-plan/todo.md" -t x > /dev/null 2>&1 )
ZERO3="$TR/three-plan/.git/zero.sh"
# ORIGIN_URL bakes empty under TEST_EMIT (doctor skipped) — patch it to the real bare origin so
# a pre-fix run's mr_list/mr_create `--repo` points somewhere real (same idiom as X-001's `boot`).
sed -i.bak "s#^ORIGIN_URL=.*#ORIGIN_URL=$(printf '%q' "$TR/three-code-origin.git")#" "$ZERO3"; rm -f "$ZERO3.bak"
own_session "$TR/three-session"
cd "$TR/three-plan"
bodyfile=$("$ZERO3" mr-body-path M1)
printf 'a request description, for a pre-fix run to reach the push\n' > "$bodyfile"
t3=$("$ZERO3" claim M1)
echo work3 > "$t3/n3.txt"; git -C "$t3" add n3.txt; git -C "$t3" commit -qm work3
before_branches=$(git -c safe.bareRepository=all -C "$TR/three-code-origin.git" branch --list | wc -l | tr -d ' ')
out=$("$ZERO3" mr M1 "$t3" 2>&1); rc=$?
check "G3 mr exit" "$rc" "5"
check "G3 mr says land gate failed" "$(printf '%s' "$out" | grep -c 'land gate failed at local')" "1"
check "G3 mr quotes criterion" "$(printf '%s' "$out" | grep -c 'no evidence line: - \[x\] a thing works')" "1"
check "G3 mr box unchecked" "$(grep -c '\[ \] M1' todo.md)" "1"
check "G3 mr never pushed" "$(git -c safe.bareRepository=all -C "$TR/three-code-origin.git" branch --list | wc -l | tr -d ' ')" "$before_branches"

# same two remaining failing fixtures as G1/G2 (missing-both, missing-sr), through `mr` too — the
# three-fixture parity TASK-058f's own AC text promises for `mr_task`, not just the one above.
t3b=$("$ZERO3" claim M2)
echo work3b > "$t3b/n3b.txt"; git -C "$t3b" add n3b.txt; git -C "$t3b" commit -qm work3b
out=$("$ZERO3" mr M2 "$t3b" 2>&1); rc=$?
check "G3 mr missing-both exit" "$rc" "5"
check "G3 mr missing-both names AC gate" "$(printf '%s' "$out" | grep -c 'missing gate note: Acceptance criteria gate')" "1"
check "G3 mr missing-both names SR gate" "$(printf '%s' "$out" | grep -c 'missing gate note: Agentic self-review gate')" "1"
check "G3 mr missing-both box unchecked" "$(grep -c '\[ \] M2' todo.md)" "1"

t3c=$("$ZERO3" claim M3)
echo work3c > "$t3c/n3c.txt"; git -C "$t3c" add n3c.txt; git -C "$t3c" commit -qm work3c
out=$("$ZERO3" mr M3 "$t3c" 2>&1); rc=$?
check "G3 mr missing-sr exit" "$rc" "5"
check "G3 mr missing-sr names only SR gate" "$(printf '%s' "$out" | grep -c 'missing gate note:')" "1"
check "G3 mr missing-sr names the right one" "$(printf '%s' "$out" | grep -c 'missing gate note: Agentic self-review gate')" "1"
check "G3 mr missing-sr box unchecked" "$(grep -c '\[ \] M3' todo.md)" "1"

check "G3 mr never pushed (all three fixtures)" "$(git -c safe.bareRepository=all -C "$TR/three-code-origin.git" branch --list | wc -l | tr -d ' ')" "$before_branches"
# G3 PASS — `mr` refuses at the identical land-gate point, before any push or forge call, across
# all three failing fixtures (missing-evidence, missing-both, missing-sr): the origin's branch
# count never grows, every box stays unchecked.

"$ZERO3" release M1 "$t3" >/dev/null 2>&1 || true
"$ZERO3" release M2 "$t3b" >/dev/null 2>&1 || true
"$ZERO3" release M3 "$t3c" >/dev/null 2>&1 || true

# G4 — the same realistic tick-after-claim flow as G2b, in `mr` mode: the AC edit + gate notes
# are made after claiming, directly in $COORD_ROOT (here $TR/three-plan, the coordination repo's
# own main checkout), landed via `commit_ac_checkoff` — never pre-baked before the branch forked,
# and never written to the target CODE worktree (`three-code`, which has no tasks/ directory at
# all in two-repo mode) or to the internal coordination claim-branch worktree (a claim marker
# only — committing onto it directly is refused elsewhere, "a claim, not a carrier"). `mr` must
# read $COORD_ROOT's fresh copy and proceed.
bodyfile=$("$ZERO3" mr-body-path M4)
printf 'a request description, for the tick-after-claim run\n' > "$bodyfile"
t3d=$("$ZERO3" claim M4)
cat > "$TR/three-plan/tasks/M4.md" <<'EOF'
### Acceptance criteria

- [x] a thing works
  > 2026-09-01 10:00-0700 verified

> Acceptance criteria gate: passed 2026-09-01 10:10-0700
> Agentic self-review gate: passed 2026-09-01 10:11-0700
EOF
"$ZERO3" commit_ac_checkoff M4 > /dev/null
echo work3d > "$t3d/n3d.txt"; git -C "$t3d" add n3d.txt; git -C "$t3d" commit -qm work3d
out=$("$ZERO3" mr M4 "$t3d" 2>&1); rc=$?
check "G4 mr sees tick-after-claim fix, proceeds" "$rc" "0"
check "G4 mr box marked" "$(grep -c '\[.\] M4' todo.md)" "1"
check "G4 mr box not left unchecked" "$(grep -c '\[ \] M4' todo.md)" "0"
# G4 PASS — the land gate reads $COORD_ROOT's own, fresh copy of the Task file (the one
# commit_ac_checkoff actually writes to), not the target code worktree or the coordination
# claim-branch worktree's stale pre-tick snapshot.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
