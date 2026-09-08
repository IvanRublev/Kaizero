#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=47s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# I-001-claim-exit-paths — zero.sh claim exit paths. The four claim outcomes — free, peer-held,
# peer-landed, validation-failed — and their exit codes, plus the exit-3 claim leak.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/I-001-claim-exit-paths
# Cross-references named in the body below: Scenario I-002 -> tests/I-002-claim-usage-and-owner-fatal.sh
#
# claim is the whole "is this task mine to work?" decision: validate, acquire, validate,
# re-check. It prints the worktree path on stdout and exits 0 when the task is yours, else 1
# (not claimed), 2 (id validation failed), 3 (validation failed), 4 (a peer already landed it),
# 6 (this task_id's own Task-file/Acceptance-Criteria validation failed), or 7 (ensure_owner's
# own FATAL — no valid session record at all). No real claude needed — but claim goes through
# ensure_owner, which requires a valid KAIZERO_SESSION_RECORD, so the driver below writes one
# for itself before calling zero.sh.
# I-002-claim-usage-and-owner-fatal.sh continues this same driver sequence, from the state I1
# through I5 leave behind, to cover raw-vs-sanitized id matching, the retired acquire
# subcommand's usage/exit-64 fall-through, and ensure_owner's own exit-7 FATAL.

# Setup
TI="$TESTROOT/I-001-claim-exit-paths"; mkdir -p "$TI/repo" "$TI/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TI/bin/claude"; chmod +x "$TI/bin/claude"
cd "$TI/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] I1 a\n- [ ] I3 b\n- [ ] I4 c\n- [ ] I5 d\n- [ ] I6/a e\n- [ ] I10a g\n' > todo.md
mkdir -p tasks
for f in I1 I3 I4 I5 I6-a I10a; do printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/$f.md"; done
git add -A; git commit -qm init
# bootstrap: real kaizero writes .git/zero.sh, stub claude exits, loop ends
PATH="$TI/bin:$PATH" timeout 30 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TI/boot.log" 2>&1 || true
# drive.sh runs as its own bash subprocess (not sourced), so its own check() calls use the
# check() test-setup.sh exports (BASH_FUNC_check%%) for exactly this reason. Its FAILED/ERRORED
# stay local to that subprocess — a shell variable doesn't cross a process boundary — so I1's own
# invocation below folds drive.sh's exit status into this script's own FAILED.
cat > "$TI/drive.sh" <<'DRIVE'
set -uo pipefail
cd "$TI/repo"
ZERO="$(cd "$(git rev-parse --git-dir)" && pwd)/zero.sh"
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
REC="$TI/session-record"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" "1" > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH="1"
FAILED=0; ERRORED=0

# I1 — free task: exit 0, worktree path on stdout and nothing else
wt=$("$ZERO" claim I1); rc=$?
check "I1 exit" "$rc" "0"
check "I1 branch" "$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)" "main-task-I1"
check "I1 stdout clean" "$([ "$(printf '%s' "$wt" | wc -l | tr -d ' ')" = 0 ] && [ "$(printf '%s' "$wt" | wc -w | tr -d ' ')" = 1 ] && echo yes || echo NO)" "yes"
# I1 PASS — exit, branch and stdout clean all report their want value.

# I2 — already held by a live session: exit 1, no second worktree
before=$(git worktree list | grep -c 'task-I1')
out=$("$ZERO" claim I1 2>&1 >/dev/null); rc=$?
check "I2 exit" "$rc" "1"
echo "stderr for I2      : $out"
check "I2 no new worktree" "$([ "$(git worktree list | grep -c 'task-I1')" = "$before" ] && echo yes || echo NO)" "yes"
# I2 PASS — exit, stderr and no new worktree all report their want value.

# I10 — one task per session: still owning I1 (unreleased), claim a DIFFERENT, never-claimed id.
# Refused, no worktree for it appears, and I1's own worktree is untouched — the ownership this
# session already holds is not overwritten by the second call.
out=$("$ZERO" claim I10a 2>&1 >/dev/null); rc=$?
# refused, not the id's own outcome
check "I10 exit" "$rc" "1"
echo "stderr for I10           : $out"
check "I10 no worktree for I10a" "$(git worktree list | grep -c 'task-I10a')" "0"
check "I10 I1 worktree untouched" "$([ -d "$wt" ] && [ "$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)" = main-task-I1 ] && echo yes || echo NO)" "yes"
# I10 PASS — exit, no worktree for I10a and I1 worktree untouched all report their want value.

# I11 — a refused (failed) second claim leaves the held ownership so intact that it still
# releases cleanly afterward — proving the refusal touched nothing about I1's own record.
out=$("$ZERO" release I1 2>&1 >/dev/null); rc=$?
check "I11 release I1 after refusal" "$rc" "0"
check "I11 I1 worktree gone" "$(git worktree list | grep -c 'task-I1')" "0"

# I3 — a peer landed it on base first: exit 4, and the worktree/branch it briefly held are gone
sed -i'' -e 's/^- \[ \] I3 /- [x] I3 /' todo.md; git commit -qam 'peer landed I3'
out=$("$ZERO" claim I3 2>&1 >/dev/null); rc=$?
check "I3 exit" "$rc" "4"
echo "stderr for I3      : $out"
check "I3 worktree gone" "$(git worktree list | grep -c 'task-I3')" "0"
check "I3 branch gone" "$(git branch --list 'main-task-I3' | wc -l | tr -d ' ')" "0"
# I3 PASS — exit, stderr, worktree gone and branch gone all report their want value.

# I4 — validation failure, FAULT-INJECTED: acquire hands back a detached worktree. Unreachable in
# normal operation (acquire always lands on the task branch), so inject rather than fabricate.
sed 's|^  set_current "\$n"$|  set_current "$n"; git -C "$wt" checkout -q --detach|' \
  "$ZERO" > "$TI/zero-bad.sh"; chmod +x "$TI/zero-bad.sh"
out=$("$TI/zero-bad.sh" claim I4 2>&1 >/dev/null); rc=$?
check "I4 exit" "$rc" "3"
echo "stderr for I4      : $out"
# exit 3 must NOT remove it
check "I4 worktree kept" "$(git worktree list | grep -c 'task-I4')" "1"
# no session still names I4
check "I4 marker cleared" "$(grep -l '^I4$' "$GC"/session/* 2>/dev/null | wc -l | tr -d ' ')" "0"
# I4 PASS — exit, stderr, worktree kept and marker cleared all report their want value — the exit-3 claim leak's first half.

# I5 — the leaked-claim regression: after an exit 3 the session may still claim another task
wt5=$("$ZERO" claim I5); rc=$?
# the failed claim did not leak
check "I5 exit" "$rc" "0"
check "I5 branch" "$(git -C "$wt5" symbolic-ref --short HEAD 2>/dev/null)" "main-task-I5"
"$ZERO" release I5 >/dev/null 2>&1   # one task per session (I10/I11): free the slot before I6's own claim
# I5 PASS — exit and branch both report their want value — the exit-3 claim leak's second half.

# I6 — the RAW id reaches is_done: an id needing sanitization still matches its todo line
sed -i'' -e 's|^- \[ \] I6/a |- [x] I6/a |' todo.md; git commit -qam 'peer landed I6/a'
out=$("$ZERO" claim 'I6/a' 2>&1 >/dev/null); rc=$?
# raw 'I6/a' matched the todo line, the branch used the slug
check "I6 exit" "$rc" "4"
# I6 PASS — exit reports its want value.

check "I7 usage" "$("$ZERO" 2>&1 | grep -c 'claim N')" "1"
# I7 PASS — usage reports its want value.

# I8 — the retired `acquire` subcommand falls through to the same usage/exit-64 case as any
# other unknown subcommand
"$ZERO" acquire I1 >"$TI/i8.out" 2>&1; rc=$?
check "I8 exit" "$rc" "64"
check "I8 usage" "$(grep -c 'claim N' "$TI/i8.out")" "1"
# I8 PASS — exit and usage both report their want value.

# I9 — ensure_owner's own FATAL (no valid session record), NOT claim_task's own exit 3: unset
# KAIZERO_SESSION_RECORD so find_owner has nothing to read, deterministically, regardless of
# the valid record this driver itself exports above
out=$(env -u KAIZERO_SESSION_RECORD "$ZERO" claim I1 2>&1 >/dev/null); rc=$?
check "I9 exit" "$rc" "7"
echo "stderr for I9      : $out"
# I9 PASS — exit and stderr both report their want value.

# I11/I12 — Task-file scoping: X resolves cleanly, Y's Acceptance Criteria section is empty.
# claiming X must succeed despite Y being broken (localized, not whole-tail); claiming Y itself
# must exit 6.
printf -- '- [ ] Ix1 ok\n- [ ] Iy1 bad\n' >> todo.md
printf '## Ix1\n### Acceptance criteria\n- [ ] a thing\n' > tasks/Ix1.md
printf '## Iy1\n### Acceptance criteria\n' > tasks/Iy1.md
git add -A; git commit -qm 'add Ix1/Iy1 task files'
outY=$("$ZERO" claim Iy1 2>&1 >/dev/null); rcY=$?
check "I12 exit" "$rcY" "6"
echo "stderr for I12     : $outY"
wtX=$("$ZERO" claim Ix1); rcX=$?
# Iy1's broken file must not block claiming Ix1
check "I11 exit" "$rcX" "0"
check "I11 branch" "$(git -C "$wtX" symbolic-ref --short HEAD 2>/dev/null)" "main-task-Ix1"
"$ZERO" release Ix1 >/dev/null 2>&1   # one task per session: free the slot before I13's own claim
# I11 PASS — exit and branch both report their want value.
# I12 PASS — exit reports its want value.

# I13 — mid-session id drift: a duplicate id introduced after a prior clean validate-ids pass.
# Run last: a duplicate id taints KAIZERO_ID_HISTORY forever, so nothing after it may claim.
"$ZERO" validate-ids >/dev/null 2>&1
printf -- '- [ ] I13a x\n- [ ] I13a x\n' >> todo.md; git commit -qam 'duplicate id drift'
out=$("$ZERO" claim I13a 2>&1 >/dev/null); rc=$?
check "I13 exit" "$rc" "2"
echo "stderr for I13     : $out"
# I13 PASS — exit reports its want value.

[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE

# I1 — free task: exit 0, worktree path on stdout and nothing else
# drive.sh writes its own BUG 057 session record and exports KAIZERO_SESSION_RECORD /
# KAIZERO_SESSION_EPOCH at its top (see Setup above), so find_owner resolves THIS driver
# process as the owner — no ancestor process named claude, and no inherited CLAUDE_PID, is
# consulted at all. This one invocation runs the whole drive.sh — I2 through I9 below read back
# what it already printed, not a second run.
# intentional: exports TI (unexported until now) to the child using the RHS's current
# (parent) value, evaluated before the fork
# shellcheck disable=SC2097,SC2098
TI="$TI" bash "$TI/drive.sh"
DRC=$?
[ "$DRC" = 0 ] || FAILED=1

# I2 — already held by a live session: exit 1, no second worktree
# (checked inside drive.sh, above)

# I10 — one task per session: a second claim for a different id is refused, ownership kept
# (checked inside drive.sh, above)

# I3 — a peer landed it on base first: exit 4, worktree and branch gone
# (checked inside drive.sh, above)

# I4 — validation failure, fault-injected: exit 3, worktree kept, marker cleared
# (checked inside drive.sh, above) — the exit-3 claim leak's first half.

# I5 — the leaked-claim regression: a failed claim does not block the next one
# (checked inside drive.sh, above) — the exit-3 claim leak's second half.

# I6 — the raw id reaches `is_done`: an id needing sanitization still matches its todo line
# (checked inside drive.sh, above)

# I7 — usage names `claim N`
# (checked inside drive.sh, above)

# I8 — the retired `acquire` subcommand falls through to the usage/exit-64 case
# (checked inside drive.sh, above)

# I9 — `ensure_owner`'s own FATAL when no claude ancestor can be found
# (checked inside drive.sh, above)

# I13 — mid-session id drift: `claim` re-proves id validation on every attempt
# (checked inside drive.sh, above)

# I11/I12 — Task-file scoping: another id's broken file never blocks this claim
# (checked inside drive.sh, above)

# I14 — exit 8: this task's branch cannot fast-forward onto origin's, the claim refuses, nothing created
#
# claim's 0/1/3/4 cases above run entirely in --local-merge mode against a single repository, the
# shape their own driver already sets up; exit 8 is MR-mode only (BUG 048), and needs a real,
# fetchable, no-host bare origin on a two-repository layout that driver never builds. Rather than
# bend I1-I13's shared driver/fixture, this case brings its own — the same mkorigin/bake/
# run_claim shape D-001-a-branch-take-back-from-origin.sh uses — self-contained, so I1-I13 above
# are untouched by it.
TI8="$TESTROOT/I-001-claim-exit-paths-i14"; mkdir -p "$TI8/bin"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1"; git config user.email t@t.t; git config user.name test )
}
printf '#!/usr/bin/env bash\n[ "$1 $2" = "auth status" ] && exit 0\nexit 0\n' > "$TI8/bin/gh"; chmod +x "$TI8/bin/gh"
export PATH="$TI8/bin:$PATH" KAIZERO_FORGE=gh
bake(){
  ( cd "$1"; KAIZERO_TEST_EMIT=1 bash "$SCRIPT" "$2/todo.md" >/dev/null 2>&1 )
  local zsh="$2/.git/zero.sh" url; url=$(printf '%q' "$1-origin.git")
  sed -i.bak "s#^ORIGIN_URL=.*#ORIGIN_URL=$url#" "$zsh"; rm -f "$zsh.bak"
}
# run a claim as its own disposable driver process, writing a BUG 057 session record naming
# itself so ensure_owner has a valid owner to resolve — no ancestor process named claude needed.
run_claim(){
  local plandir=$1 id=$2 errfile=$3 drv
  drv="$TI8/drv-$id-$RANDOM.sh"
  cat > "$drv" <<'DRV'
REC="$0.rec"
printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
DRV
  printf 'cd "%s"\nbash .git/zero.sh claim %s\n' "$plandir" "$id" >> "$drv"
  bash "$drv" 2>"$errfile"
}

mkorigin "$TI8/i14code"; mkrepo "$TI8/i14plan"
( cd "$TI8/i14plan"; printf -- '- [ ] i14a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/i14a.md; git add -A; git commit -qm todo )
bake "$TI8/i14code" "$TI8/i14plan"

twt=$(run_claim "$TI8/i14plan" i14a "$TI8/i14.err")   # first claim: fresh fork off base
echo local-only >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "local-only commit" >/dev/null
git -C "$TI8/i14code" worktree remove --force "$twt"   # simulate: the session died before it ever pushed

# a different machine pushed a DIFFERENT commit under the same branch name straight to origin
git clone -q "$TI8/i14code-origin.git" "$TI8/i14other"
( cd "$TI8/i14other"; git config user.email o@o.o; git config user.name other
  git checkout -qb i14a-fix-widget; echo other-work >> f; git commit -qam "other machine's work"; git push -q origin i14a-fix-widget )
remote_tip_short=$(git -c safe.bareRepository=all -C "$TI8/i14code-origin.git" rev-parse --short i14a-fix-widget)

BEFORE_REFS=$(git -C "$TI8/i14code" for-each-ref refs/heads/)
BEFORE_WT=$(git -C "$TI8/i14code" worktree list)
out=$(run_claim "$TI8/i14plan" i14a "$TI8/i14b.err"); rc=$?
AFTER_REFS=$(git -C "$TI8/i14code" for-each-ref refs/heads/)
errtxt=$(cat "$TI8/i14b.err")
check "I14 exit" "$rc" "8"
check "I14 stdout empty" "$([ -z "$out" ] && echo yes || echo NO)" "yes"
check "I14 stderr names the branch" "$([ "$(printf '%s' "$errtxt" | grep -c 'i14a-fix-widget')" -ge 1 ] && echo ok || echo none)" "ok"
check "I14 stderr names origin's short tip" "$([ "$(printf '%s' "$errtxt" | grep -c "$remote_tip_short")" -ge 1 ] && echo ok || echo none)" "ok"
check "I14 stderr names the repair command" "$([ "$(printf '%s' "$errtxt" | grep -cE 'branch -f i14a-fix-widget origin/i14a-fix-widget|branch -D i14a-fix-widget')" -ge 1 ] && echo ok || echo none)" "ok"
check "I14 nothing created (refs unchanged)" "$([ "$BEFORE_REFS" = "$AFTER_REFS" ] && echo yes || echo NO)" "yes"
check "I14 nothing created (worktree list unchanged)" "$([ "$BEFORE_WT" = "$(git -C "$TI8/i14code" worktree list)" ] && echo yes || echo NO)" "yes"
# I14 PASS — claim exits 8, its stdout empty, its stderr naming the branch, origin's own short
# tip and the two-command repair — no worktree, branch or .owner created, refs/heads/ and git
# worktree list byte-identical before and after. Brings its own MR-mode two-repository fixture
# (mkorigin/bake/run_claim, the same shape D-001 uses) rather than reusing I1-I13's
# --local-merge driver, so those cases' own Setup and fixtures are untouched by this one.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
