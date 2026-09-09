#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=350s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# X-001-mr-and-mr-body-path — `zero.sh mr`/`mr-body-path`. A real, fetchable, no-host bare
# origin. `mr` pushes the claimed branch, opens a request (reusing an already-open one instead of a
# second call), lands the box as `[↑]` on the coordination base, and removes both the coordination
# worktree/branch and the target worktree — the target branch alone is left, unmerged,
# for review; `sync-mrs`'s own teardown of a leftover target worktree at merge time is
# `U-022-a-whole-mr-landing`'s subject, not this file's.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/X-001-mr-and-mr-body-path
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# `mr` pushes the claimed branch to `origin`, opens or reuses one request for it, then lands the
# box as `[↑]` on the coordination base — no code merge, so the ONLY merge here is the coordination
# claim branch onto `COORD_BASE` (proven a no-op fork point, same as `merge_two_repos`' own box-side
# merge). A real, fetchable, no-host bare origin (same shape as Scenario V's `mkorigin`) so the push
# is real; `KAIZERO_TEST_EMIT=1` skips the doctor so `ORIGIN_URL` bakes empty — this
# scenario patches it to the real bare origin path after emit, the same "override after the bake"
# convention `U-008-mr-list`'s own `mrsetup` uses for `mr_list`/`mr_create`. `claim`/`mr` go through
# `ensure_owner`, so each driver writes its own `KAIZERO_SESSION_RECORD` (BUG 057) before calling
# `zero.sh`, the same technique Scenario I uses.

# --- Setup ---
TX="$TESTROOT/X-001-mr-and-mr-body-path"; mkdir -p "$TX/bin" "$TX/stub"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktask(){ mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/$1.md"; }
mktodo(){ ( cd "$1"; printf -- '- [ ] %s task\n' "$2" > todo.md; mktask "$2"; git add -A; git commit -qm todo ); }
# real, fetchable, no-host origin — $1 = target dir (same shape as Scenario V's mkorigin).
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1"; git config user.email t@t.t; git config user.name test )
}
printf '#!/usr/bin/env bash\nexit 0\n' > "$TX/bin/claude"; chmod +x "$TX/bin/claude"
# stub gh: records argv/cwd, serves canned list/create output from $TX/stub/gh-<verb>.out (same
# shape as `U-008-mr-list`'s own stub, narrowed to the two verbs mr_task ever calls). An absent
# gh-list.out answers "[]" — real gh's own --json flag always prints a valid empty array for zero
# matches, never empty stdout — so mr_list's jq stage sees valid JSON either way.
cat > "$TX/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TX/stub/gh.argv"
printf '%s\n' "\$PWD" >> "$TX/stub/gh.cwd"
verb=""
case "\$1 \${2:-}" in
  "pr create") verb=create ;;
  "pr list")   verb=list ;;
esac
outfile="$TX/stub/gh-\$verb.out"
exitfile="$TX/stub/gh-\$verb.exit"
# X5-C's race hook: a file naming a path to dirty, appended to right before this call answers —
# simulates a coordination checkout going dirty while this landing was inside the forge call.
dirtyfile="$TX/stub/dirty-target"
if [ "\$verb" = create ] && [ -f "\$dirtyfile" ]; then printf 'x\n' >> "\$(cat "\$dirtyfile")"; fi
# X15's mid-flight-delete hook: a file naming "<coord repo dir>|<line pattern>", consumed once —
# simulates a human deleting the task's line from the todo while this landing sits inside the
# forge call, strictly after step 1's pre-flight read it clean.
delfile="$TX/stub/delete-line-target"
if [ "\$verb" = create ] && [ -f "\$delfile" ]; then
  IFS='|' read -r drepo dpat < "\$delfile"; rm -f "\$delfile"
  ( cd "\$drepo"; sed -i.bak "/\$dpat/d" todo.md; rm -f todo.md.bak
    git add todo.md; git commit -qm "human deletes line mid-flight" >/dev/null )
fi
if [ -f "\$exitfile" ]; then
  [ -f "$TX/stub/gh-\$verb.err" ] && cat "$TX/stub/gh-\$verb.err" >&2
  exit "\$(cat "\$exitfile")"
fi
if [ "\$verb" = list ] && [ ! -f "\$outfile" ]; then printf '[]'; exit 0; fi
[ -n "\$verb" ] && [ -f "\$outfile" ] && cat "\$outfile"
exit 0
STUB
chmod +x "$TX/bin/gh"
# bootstrap: writes zero.sh (TEST_EMIT, doctor skipped — ORIGIN_URL bakes empty), then
# patches ORIGIN_URL to the real bare origin so mr_list/mr_create's `--repo` points somewhere real;
# FORGE already bakes "gh" from KAIZERO_FORGE under TEST_EMIT. $1 = target dir, $2 = todo path.
boot(){
  ( cd "$1"; PATH="$TX/bin:$PATH" KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$2" >/dev/null 2>&1 )
  local coord zsh url
  coord="$(cd "$(dirname "$2")" && pwd)"; zsh="$coord/.git/zero.sh"; url=$(printf '%q' "$1-origin.git")
  sed -i.bak "s#^ORIGIN_URL=.*#ORIGIN_URL=$url#" "$zsh"; rm -f "$zsh.bak"
}

# X1 — fresh open: push, create (no reuse), box lands `[↑]`, target worktree torn down (branch kept)
mkorigin "$TX/x1code"; mkrepo "$TX/x1plan"; mktodo "$TX/x1plan" X1
boot "$TX/x1code" "$TX/x1plan/todo.md"
printf 'https://example.invalid/pr/1\n' > "$TX/stub/gh-create.out"

cat > "$TX/x1drive.sh" <<'DRIVE'
set -uo pipefail
export PATH="$TX/bin:$PATH"   # `mr` shells out to `gh` (the stub) via zero.sh
REC="$TX/x1-session"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" "1" > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x1plan"
FAILED=0; ERRORED=0
twt=$(bash .git/zero.sh claim X1); rcc=$?
check "X1 claim exit" "$rcc" "0"
echo "$twt" > "$TX/x1-twt"
git -C "$twt" symbolic-ref --short HEAD > "$TX/x1-s"
echo hi >> "$twt/f"
git -C "$twt" add -A; git -C "$twt" commit -qm "X1 change" >/dev/null
bodyfile=$(bash .git/zero.sh mr-body-path X1)
check "X1 body path under COORD .git" "$(case "$bodyfile" in "$PWD"/.git/*) echo yes;; *) echo NO;; esac)" "yes"
printf 'X1 request body\n' > "$bodyfile"
# INSTANCE_ID defaults to "shared" when KAIZERO_INSTANCE is unset, same as F5 —
# mr_task is the one mark_safe_to_exit call site F5 doesn't reach (it only drives merge/no-claim-mark).
SAFE="$PWD/.git/safe-to-exit-main-shared"; rm -f "$SAFE"
out=$(bash .git/zero.sh mr X1 "$twt"); rcm=$?
check "X1 mr exit" "$rcm" "0"
check "X1 mr output names the URL" "$(echo "$out" | grep -c 'https://example.invalid/pr/1')" "1"
# mr_task's mark_safe_to_exit call
check "X1 mr marks safe-to-exit" "$([ -s "$SAFE" ] && echo yes || echo NO)" "yes"
check "X1 box symbol on base" "$(bash .git/zero.sh box-symbol-on-base X1)" "↑"
check "X1 coordination worktree gone" "$(git worktree list | grep -c task-X1)" "0"
check "X1 coordination branch gone" "$(git branch --list 'main-task-X1' | wc -l | tr -d ' ')" "0"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x1drive.sh" || FAILED=1

TWT=$(cat "$TX/x1-twt")
S=$(cat "$TX/x1-s")
check "X1 target worktree torn down" "$([ -d "$TWT" ] && echo NO || echo yes)" "yes"
check "X1 target branch kept" "$(git -C "$TX/x1code" branch --list "$S" | wc -l | tr -d ' ')" "1"
check "X1 branch pushed to origin" "$(git -c safe.bareRepository=all -C "$TX/x1code-origin.git" branch --list "$S" | wc -l | tr -d ' ')" "1"
check "X1 gh create called once" "$(grep -c '^pr create' "$TX/stub/gh.argv" 2>/dev/null || true)" "1"
check "X1 gh ran from \$TARGET_ROOT" "$(grep -c "^$TX/x1code\$" "$TX/stub/gh.cwd" 2>/dev/null || true)" "0"
# X1 PASS — `claim` forks a target worktree; `mr-body-path` names a path under the
# coordination repo's own `.git`; `mr` pushes that branch to the real bare origin, calls `gh pr
# create` exactly once (never from `$TARGET_ROOT`), lands `[↑]` on the coordination base, marks
# the running instance safe to exit, and removes the coordination worktree/branch and
# the target worktree — the pushed target branch alone is left in place, unmerged.

# X2 — an open request is reused, never a second `pr create`
mkorigin "$TX/x2code"; mkrepo "$TX/x2plan"; mktodo "$TX/x2plan" X2
boot "$TX/x2code" "$TX/x2plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out"   # X1 already asserted on these — start X2 clean

cat > "$TX/x2drive.sh" <<'DRIVE'
set -uo pipefail
export PATH="$TX/bin:$PATH"   # `mr` shells out to `gh` (the stub) via zero.sh
REC="$TX/x2-session"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" "1" > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x2plan"
FAILED=0; ERRORED=0
twt=$(bash .git/zero.sh claim X2)
S=$(git -C "$twt" symbolic-ref --short HEAD)
echo hi >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "X2 change" >/dev/null
printf '[{"number":7,"headRefOid":"deadbeef","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/7"}]' \
  > "$TX/stub/gh-list.out"
printf 'X2 request body\n' > "$(bash .git/zero.sh mr-body-path X2)"
out=$(bash .git/zero.sh mr X2 "$twt"); rcm=$?
check "X2 mr exit" "$rcm" "0"
check "X2 mr output reuses url" "$(echo "$out" | grep -c 'https://example.invalid/pr/7')" "1"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x2drive.sh" || FAILED=1
check "X2 gh create never called" "$(grep -c '^pr create' "$TX/stub/gh.argv" 2>/dev/null || true)" "0"
# X2 PASS — with an open request already listed for the branch's head, `mr` reuses its URL
# and never calls `gh pr create`.

# X4 — land-gate refusals: missing `$twt`, a claim-branch stray commit, a dirty tracked tree, and
# no diff against `origin/<target base>`
mkorigin "$TX/x4code"; mkrepo "$TX/x4plan"
( cd "$TX/x4plan"; printf -- '- [ ] X4a missing-twt task\n- [ ] X4b claim-branch task\n- [ ] X4c dirty task\n- [ ] X4d no-diff task\n' > todo.md
  for t in X4a X4b X4c X4d; do mktask "$t"; done; git add -A; git commit -qm todo )
boot "$TX/x4code" "$TX/x4plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out"   # X1/X2 already asserted on these — start X4 clean
cat > "$TX/x4drive.sh" <<DRIVE
set -uo pipefail
export PATH="$TX/bin:\$PATH"
REC="$TX/x4-session"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" "1" > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x4plan"
FAILED=0; ERRORED=0

# X4a: \$twt no longer exists.
t=\$(bash .git/zero.sh claim X4a)
find "\$t" -depth -delete 2>/dev/null || true
out=\$(bash .git/zero.sh mr X4a "\$t" 2>&1); rc=\$?
check "X4a missing-twt exit" "\$rc" "5"
check "X4a says no longer exists" "\$(printf '%s' "\$out" | grep -c 'no longer exists')" "1"
check "X4a box unchecked" "\$(grep -c '\[ \] X4a' todo.md)" "1"
bash .git/zero.sh release X4a >/dev/null 2>&1 || true

# X4b: coordination claim branch carries a commit beyond its fork point.
t=\$(bash .git/zero.sh claim X4b)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
cwt=\$(git worktree list --porcelain | awk -v b="refs/heads/main-task-X4b" '/^worktree /{p=substr(\$0,10)} /^branch /{if(substr(\$0,8)==b){print p;exit}}')
git -C "\$cwt" commit -q --allow-empty -m stray
out=\$(bash .git/zero.sh mr X4b "\$t" 2>&1); rc=\$?
check "X4b claim-branch exit" "\$rc" "5"
check "X4b says claim not carrier" "\$(printf '%s' "\$out" | grep -c 'is a claim, not a carrier')" "1"
bash .git/zero.sh release X4b >/dev/null 2>&1 || true

# X4c: dirty tracked tree.
t=\$(bash .git/zero.sh claim X4c)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
echo dirty >> "\$t/f"
out=\$(bash .git/zero.sh mr X4c "\$t" 2>&1); rc=\$?
check "X4c dirty exit" "\$rc" "5"
check "X4c says uncommitted" "\$(printf '%s' "\$out" | grep -c 'uncommitted change')" "1"
git -C "\$t" checkout -- f
bash .git/zero.sh release X4c >/dev/null 2>&1 || true

# X4d: no diff against origin/<target base>, and not an ancestor — same content-identical
# revert-then-redo shape T19's W2 uses, the squash-merge redo shape this test proves refuses.
t=\$(bash .git/zero.sh claim X4d)
GIT_EDITOR=true git -C "\$t" revert --no-edit HEAD --no-commit >/dev/null 2>&1 || true
echo change > "\$t/g"; git -C "\$t" add -A; git -C "\$t" commit -qm change
git -C "\$t" revert --no-edit HEAD >/dev/null
out=\$(bash .git/zero.sh mr X4d "\$t" 2>&1); rc=\$?
check "X4d no-diff exit" "\$rc" "5"
check "X4d names origin/main" "\$(printf '%s' "\$out" | grep -c 'carries no change against origin/main')" "1"
check "X4d box unchecked" "\$(grep -c '\[ \] X4d' todo.md)" "1"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x4drive.sh" || FAILED=1

check "X4 no branch pushed for any of them" "$(git -c safe.bareRepository=all -C "$TX/x4code-origin.git" branch --list 'main-task-X4*' | wc -l | tr -d ' ')" "0"
check "X4 no forge calls at all" "$([ -f "$TX/stub/gh.argv" ] && echo NO || echo yes)" "yes"
# X4 PASS — all four purely-local refusals fire with exit 5 under `mr <raw>:`'s `land gate
# failed at local:` wording, naming `origin/<target base>` rather than a local ref where the
# local mode would; none of them pushes a branch or calls the forge.

# X5 — purely-local refusals fire before the forge, and are re-checked as the race once inside
# `MERGE_LOCK`
mkorigin "$TX/x5code"; mkrepo "$TX/x5plan"
( cd "$TX/x5plan"; printf -- '- [ ] X5a task\n- [ ] X5b task\n- [ ] X5c task\n' > todo.md
  for t in X5a X5b X5c; do mktask "$t"; done; git add -A; git commit -qm todo )
boot "$TX/x5code" "$TX/x5plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out"
cat > "$TX/x5drive.sh" <<DRIVE
set -uo pipefail
export PATH="$TX/bin:\$PATH"
REC="$TX/x5-session"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" "1" > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x5plan"
FAILED=0; ERRORED=0

# X5a: dirty coordination checkout (\$TODO_PATH itself uncommitted) before the landing runs.
t=\$(bash .git/zero.sh claim X5a)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
printf 'X5a body\n' > \$(bash .git/zero.sh mr-body-path X5a)
echo dirty >> todo.md
out=\$(bash .git/zero.sh mr X5a "\$t" 2>&1); rc=\$?
check "X5a dirty-coord exit" "\$rc" "5"
check "X5a no forge calls" "\$([ -f "$TX/stub/gh.argv" ] && echo NO || echo yes)" "yes"
check "X5a box untouched" "\$(grep -c '\[ \] X5a' todo.md)" "1"
git checkout -- todo.md
bash .git/zero.sh release X5a >/dev/null 2>&1 || true

# X5b: the id's checkbox line deleted from the todo on COORD_BASE before the landing runs.
t=\$(bash .git/zero.sh claim X5b)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
printf 'X5b body\n' > \$(bash .git/zero.sh mr-body-path X5b)
sed -i.bak '/X5b task/d' todo.md; rm -f todo.md.bak
git add todo.md; git commit -qm "human deletes X5b line"
out=\$(bash .git/zero.sh mr X5b "\$t" 2>&1); rc=\$?
check "X5b deleted-line exit" "\$rc" "5"
check "X5b no forge calls" "\$([ -f "$TX/stub/gh.argv" ] && echo NO || echo yes)" "yes"
bash .git/zero.sh release X5b >/dev/null 2>&1 || true

# X5c: the race — mr_create's own side effect dirties \$TODO_PATH between the pre-flight and the
# lock, so step 6's own copy of the check is what catches it, not the pre-flight; the request it
# just opened is left alone.
t=\$(bash .git/zero.sh claim X5c)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
printf 'X5c body\n' > \$(bash .git/zero.sh mr-body-path X5c)
printf 'https://example.invalid/pr/5c\n' > "$TX/stub/gh-create.out"
printf '%s\n' "\$PWD/todo.md" > "$TX/stub/dirty-target"
out=\$(bash .git/zero.sh mr X5c "\$t" 2>&1); rc=\$?
check "X5c race exit" "\$rc" "5"
check "X5c box unticked" "\$(grep -c '\[ \] X5c' todo.md)" "1"
# the request it opened is left alone
check "X5c create still called" "\$(grep -c '^pr create' "$TX/stub/gh.argv")" "1"
git checkout -- todo.md
rm -f "$TX/stub/dirty-target"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x5drive.sh" || FAILED=1
# X5 PASS — a dirty coordination checkout and a deleted checkbox line both refuse before any
# push or forge call; a coordination checkout that goes dirty *during* the forge call (the race)
# is caught by step 6's own copy of the check, inside `MERGE_LOCK`, with the request it already
# opened left alone and the box still `[ ]`.

# X6 — a branch already an ancestor of `origin/<target base>` lands `[x]` with no body, no push,
# no forge call
mkorigin "$TX/x6code"; mkrepo "$TX/x6plan"; mktodo "$TX/x6plan" X6
boot "$TX/x6code" "$TX/x6plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out"
cat > "$TX/x6drive.sh" <<DRIVE
set -uo pipefail
export PATH="$TX/bin:\$PATH"
REC="$TX/x6-session"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" "1" > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x6plan"
FAILED=0; ERRORED=0
t=\$(bash .git/zero.sh claim X6)
echo already-landed > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm "X6 work"
# the work already landed on origin's main by another route (a human, a peer) — no body file
# exists at all, proving step 2 precedes step 3 outright.
git -C "\$t" push -q origin HEAD:refs/heads/main
git -C "$TX/x6code" fetch -q origin main:refs/remotes/origin/main
out=\$(bash .git/zero.sh mr X6 "\$t" 2>&1); rc=\$?
check "X6 exit" "\$rc" "0"
check "X6 stdout already-in-base" "\$(printf '%s' "\$out" | grep -c 'already in main; box landed as \[x\]')" "1"
check "X6 box symbol x" "\$(bash .git/zero.sh box-symbol-on-base X6)" "x"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x6drive.sh" || FAILED=1
check "X6 no forge calls at all" "$([ -f "$TX/stub/gh.argv" ] && echo NO || echo yes)" "yes"
# X6 PASS — a branch whose tip is already an ancestor of `origin/main` lands `[x]` straight
# from step 2, asking for no description, no push and no forge call — proven with no body file at
# all present.

# X7 — the body gate precedes the push and the forge, even with an open request already listed
mkorigin "$TX/x7code"; mkrepo "$TX/x7plan"
( cd "$TX/x7plan"; printf -- '- [ ] X7a task\n- [ ] X7b task\n' > todo.md
  for t in X7a X7b; do mktask "$t"; done; git add -A; git commit -qm todo )
boot "$TX/x7code" "$TX/x7plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out"
cat > "$TX/x7drive.sh" <<DRIVE
set -uo pipefail
export PATH="$TX/bin:\$PATH"
REC="$TX/x7-session"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" "1" > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x7plan"
FAILED=0; ERRORED=0

# X7a: no body file at all, no prior push — a first landing.
t=\$(bash .git/zero.sh claim X7a)
S=\$(git -C "\$t" symbolic-ref --short HEAD)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
printf '[{"number":1,"headRefOid":"anything","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/1"}]' \
  > "$TX/stub/gh-list.out"
out=\$(bash .git/zero.sh mr X7a "\$t" 2>&1); rc=\$?
check "X7a exit" "\$rc" "5"
check "X7a names body" "\$(printf '%s' "\$out" | grep -c 'failed at body')" "1"
# the already-open request is never even read
check "X7a no forge calls at all" "\$([ -f "$TX/stub/gh.argv" ] && echo NO || echo yes)" "yes"
check "X7a no branch on origin" "\$(git -c safe.bareRepository=all -C "$TX/x7code-origin.git" branch --list "\$S" | wc -l | tr -d ' ')" "0"
bash .git/zero.sh release X7a >/dev/null 2>&1   # one task per session: free the slot before X7b's own claim

# X7b: a real body first lands the branch at sha S1; a second commit plus a re-entry with a
# missing body never pushes, so origin still carries S1, not the newer commit.
t2=\$(bash .git/zero.sh claim X7b)
S2=\$(git -C "\$t2" symbolic-ref --short HEAD)
echo work1 > "\$t2/f"; git -C "\$t2" add -A; git -C "\$t2" commit -qm work1
git -C "\$t2" push -q -u origin HEAD
S1SHA=\$(git -C "\$t2" rev-parse HEAD)
echo work2 >> "\$t2/f"; git -C "\$t2" add -A; git -C "\$t2" commit -qm work2
out=\$(bash .git/zero.sh mr X7b "\$t2" 2>&1); rc=\$?
check "X7b re-entry exit" "\$rc" "5"
check "X7b names body" "\$(printf '%s' "\$out" | grep -c 'failed at body')" "1"
check "X7b origin still at old sha" "\$([ "\$(git -c safe.bareRepository=all -C "$TX/x7code-origin.git" rev-parse "\$S2")" = "\$S1SHA" ] && echo yes || echo NO)" "yes"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x7drive.sh" || FAILED=1
# X7 PASS — an absent or empty body file refuses at `body` before the forge is ever asked,
# even with an open request already listed for the head; on a first landing nothing is pushed, and
# on a re-entry the branch already on `origin` stays at the sha it carried before the run.

# X8 — an unpushable branch (rejected non-fast-forward) refuses at `push`, before any forge call
mkorigin "$TX/x8code"; mkrepo "$TX/x8plan"; mktodo "$TX/x8plan" X8
boot "$TX/x8code" "$TX/x8plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out"
cat > "$TX/x8drive.sh" <<DRIVE
set -uo pipefail
export PATH="$TX/bin:\$PATH"
REC="$TX/x8-session"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" "1" > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x8plan"
FAILED=0; ERRORED=0
t=\$(bash .git/zero.sh claim X8)
S=\$(git -C "\$t" symbolic-ref --short HEAD)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
printf 'X8 body\n' > \$(bash .git/zero.sh mr-body-path X8)
# a second clone pushes a DIFFERENT commit to the same branch name first.
git clone -q "$TX/x8code-origin.git" "$TX/x8second" >/dev/null 2>&1
( cd "$TX/x8second"; git config user.email t@t.t; git config user.name test
  git checkout -qb "\$S"; echo other >> f; git add -A; git commit -qm other; git push -q origin "\$S" )
out=\$(bash .git/zero.sh mr X8 "\$t" 2>&1); rc=\$?
check "X8 push-rejected exit" "\$rc" "5"
check "X8 names push" "\$(printf '%s' "\$out" | grep -c 'failed at push')" "1"
check "X8 no forge calls at all" "\$([ -f "$TX/stub/gh.argv" ] && echo NO || echo yes)" "yes"
check "X8 box unticked" "\$(grep -c '\[ \] X8' todo.md)" "1"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x8drive.sh" || FAILED=1
# X8 PASS — a rejected, non-fast-forward push refuses at `push` with git's own stderr, never
# `--force`; the forge is never called.

# X9 — a failing forge call refuses at `mr`; a failing list is never followed by a create
mkorigin "$TX/x9code"; mkrepo "$TX/x9plan"
( cd "$TX/x9plan"; printf -- '- [ ] X9a task\n- [ ] X9b task\n' > todo.md
  for t in X9a X9b; do mktask "$t"; done; git add -A; git commit -qm todo )
boot "$TX/x9code" "$TX/x9plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out" "$TX/stub/gh-list.exit" "$TX/stub/gh-create.exit"
cat > "$TX/x9drive.sh" <<DRIVE
set -uo pipefail
export PATH="$TX/bin:\$PATH"
REC="$TX/x9-session"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" "1" > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x9plan"
FAILED=0; ERRORED=0

# X9a: mr_list itself fails.
t=\$(bash .git/zero.sh claim X9a)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
printf 'X9a body\n' > \$(bash .git/zero.sh mr-body-path X9a)
echo 1 > "$TX/stub/gh-list.exit"
printf 'gh: rate limited\n' > "$TX/stub/gh-list.err"
out=\$(bash .git/zero.sh mr X9a "\$t" 2>&1); rc=\$?
check "X9a list-fail exit" "\$rc" "5"
check "X9a names mr" "\$(printf '%s' "\$out" | grep -c 'failed at mr')" "1"
check "X9a no create called" "\$(grep -c '^pr create' "$TX/stub/gh.argv" 2>/dev/null || true)" "0"
rm -f "$TX/stub/gh-list.exit" "$TX/stub/gh-list.err" "$TX/stub/gh.argv"
bash .git/zero.sh release X9a >/dev/null 2>&1   # one task per session: free the slot before X9b's own claim

# X9b: mr_list succeeds empty, mr_create fails.
t2=\$(bash .git/zero.sh claim X9b)
echo work > "\$t2/f"; git -C "\$t2" add -A; git -C "\$t2" commit -qm work
printf 'X9b body\n' > \$(bash .git/zero.sh mr-body-path X9b)
echo 1 > "$TX/stub/gh-create.exit"
printf 'gh: repo not found\n' > "$TX/stub/gh-create.err"
out=\$(bash .git/zero.sh mr X9b "\$t2" 2>&1); rc=\$?
check "X9b create-fail exit" "\$rc" "5"
check "X9b names mr" "\$(printf '%s' "\$out" | grep -c 'failed at mr')" "1"
check "X9b box unticked" "\$(grep -c '\[ \] X9b' todo.md)" "1"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x9drive.sh" || FAILED=1
rm -f "$TX/stub/gh-create.exit" "$TX/stub/gh-create.err"
# X9 PASS — a failing `mr_list` refuses at `mr` and never reaches `mr_create`; a failing
# `mr_create` (after `mr_list` answers empty) refuses at `mr` too, box left `[ ]`.

# X10 — merged verdicts read directly by `mr`: the same sha lands `[x]`, a different sha opens
# fresh
mkorigin "$TX/x10code"; mkrepo "$TX/x10plan"
( cd "$TX/x10plan"; printf -- '- [ ] X10a task\n- [ ] X10b task\n' > todo.md
  for t in X10a X10b; do mktask "$t"; done; git add -A; git commit -qm todo )
boot "$TX/x10code" "$TX/x10plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out"
cat > "$TX/x10drive.sh" <<DRIVE
set -uo pipefail
export PATH="$TX/bin:\$PATH"
REC="$TX/x10-session"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" "1" > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x10plan"
FAILED=0; ERRORED=0

# X10a: newest request merged at this branch's exact current tip -> [x], no create.
t=\$(bash .git/zero.sh claim X10a)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
head=\$(git -C "\$t" rev-parse HEAD)
printf 'X10a body\n' > \$(bash .git/zero.sh mr-body-path X10a)
printf '[{"number":3,"headRefOid":"%s","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/3"}]' "\$head" \
  > "$TX/stub/gh-list.out"
out=\$(bash .git/zero.sh mr X10a "\$t" 2>&1); rc=\$?
check "X10a exit" "\$rc" "0"
check "X10a stdout already-merged" "\$(printf '%s' "\$out" | grep -c 'already merged; box landed as \[x\]')" "1"
check "X10a box symbol x" "\$(bash .git/zero.sh box-symbol-on-base X10a)" "x"
check "X10a no create called" "\$(grep -c '^pr create' "$TX/stub/gh.argv" 2>/dev/null || true)" "0"

# X10b: newest request merged at a DIFFERENT sha (a reopened task's fresh fork) -> treated as no
# live request, mr_create runs, box lands [↑].
rm -f "$TX/stub/gh.argv"
t2=\$(bash .git/zero.sh claim X10b)
echo work > "\$t2/f"; git -C "\$t2" add -A; git -C "\$t2" commit -qm work
printf 'X10b body\n' > \$(bash .git/zero.sh mr-body-path X10b)
printf '[{"number":4,"headRefOid":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/4"}]' \
  > "$TX/stub/gh-list.out"
printf 'https://example.invalid/pr/44\n' > "$TX/stub/gh-create.out"
out=\$(bash .git/zero.sh mr X10b "\$t2" 2>&1); rc=\$?
check "X10b exit" "\$rc" "0"
check "X10b stdout new request" "\$(printf '%s' "\$out" | grep -c 'https://example.invalid/pr/44 opened')" "1"
check "X10b box symbol up-arrow" "\$(bash .git/zero.sh box-symbol-on-base X10b)" "↑"
check "X10b create called once" "\$(grep -c '^pr create' "$TX/stub/gh.argv")" "1"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x10drive.sh" || FAILED=1
# X10 PASS — a newest request merged at this branch's exact current tip lands `[x]` with no
# second request created; one merged at any other sha reads as no live request and a fresh one
# opens.

# X11 — a re-entry after the box tick fails reuses the same request, no second `pr create`
mkorigin "$TX/x11code"; mkrepo "$TX/x11plan"; mktodo "$TX/x11plan" X11
boot "$TX/x11code" "$TX/x11plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out"
cat > "$TX/x11drive.sh" <<DRIVE
set -uo pipefail
export PATH="$TX/bin:\$PATH"
REC="$TX/x11-session"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" "1" > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x11plan"
FAILED=0; ERRORED=0
t=\$(bash .git/zero.sh claim X11)
S=\$(git -C "\$t" symbolic-ref --short HEAD)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
sha=\$(git -C "\$t" rev-parse HEAD)
printf 'X11 body\n' > \$(bash .git/zero.sh mr-body-path X11)
printf 'https://example.invalid/pr/11\n' > "$TX/stub/gh-create.out"
mkdir -p .git/hooks
printf '#!/usr/bin/env bash\ngit diff --cached --name-only | grep -q "^todo.md\$" && exit 1\nexit 0\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
out=\$(bash .git/zero.sh mr X11 "\$t" 2>&1); rc=\$?
check "X11 first attempt exit" "\$rc" "5"
check "X11 names tick commit" "\$(printf '%s' "\$out" | grep -c 'tick commit')" "1"
check "X11 box still unclaimed" "\$(grep -c '\[ \] X11' todo.md)" "1"
check "X11 create called once so far" "\$(grep -c '^pr create' "$TX/stub/gh.argv")" "1"
rm -f .git/hooks/pre-commit
# the stub is static, not a real forge: the first attempt's own \`pr create\` already made pr/11
# exist, still open at this exact tip — the retry's own \`pr list\` must be told so, the same way
# a real forge would already know.
printf '[{"number":11,"headRefOid":"%s","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/11"}]' "\$sha" \
  > "$TX/stub/gh-list.out"

out2=\$(bash .git/zero.sh mr X11 "\$t" 2>&1); rc2=\$?
check "X11 retry exit" "\$rc2" "0"
check "X11 retry reuses same url" "\$(printf '%s' "\$out2" | grep -c 'https://example.invalid/pr/11 opened')" "1"
# no second create across both runs; the retry's push is a no-op
check "X11 create still just once" "\$(grep -c '^pr create' "$TX/stub/gh.argv")" "1"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x11drive.sh" || FAILED=1
# X11 PASS — a first attempt whose box tick a rejecting `pre-commit` hook fails leaves the box
# `[ ]` and the request already open; the retry, once the hook is gone, pushes a no-op, calls no
# second `mr_create`, and lands `[↑]` on the same URL — routes (a) and (e) of the re-entry table.

# X12 — two `open` requests on one head: the newest number wins outright, whichever order the
# rows arrive in or whatever state the rest carry
mkorigin "$TX/x12code"; mkrepo "$TX/x12plan"
( cd "$TX/x12plan"; printf -- '- [ ] X12a task\n- [ ] X12b task\n- [ ] X12c task\n- [ ] X12d task\n' > todo.md
  for t in X12a X12b X12c X12d; do mktask "$t"; done; git add -A; git commit -qm todo )
boot "$TX/x12code" "$TX/x12plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out"
cat > "$TX/x12drive.sh" <<DRIVE
set -uo pipefail
export PATH="$TX/bin:\$PATH"
REC="$TX/x12-session"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" "1" > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x12plan"
FAILED=0; ERRORED=0

# ascending rows (7 then 9), both open.
t=\$(bash .git/zero.sh claim X12a)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
printf 'X12a body\n' > \$(bash .git/zero.sh mr-body-path X12a)
printf '[{"number":7,"headRefOid":"aaaa","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/7"},{"number":9,"headRefOid":"bbbb","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/9"}]' \
  > "$TX/stub/gh-list.out"
out=\$(bash .git/zero.sh mr X12a "\$t" 2>&1); rc=\$?
check "X12a exit" "\$rc" "0"
check "X12a reuses 9 (ascending)" "\$(printf '%s' "\$out" | grep -c 'pr/9 opened')" "1"

# descending rows (9 then 7), both open — same winner, proving no positional bias.
t2=\$(bash .git/zero.sh claim X12b)
echo work > "\$t2/f"; git -C "\$t2" add -A; git -C "\$t2" commit -qm work
printf 'X12b body\n' > \$(bash .git/zero.sh mr-body-path X12b)
printf '[{"number":9,"headRefOid":"bbbb","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/9"},{"number":7,"headRefOid":"aaaa","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/7"}]' \
  > "$TX/stub/gh-list.out"
out2=\$(bash .git/zero.sh mr X12b "\$t2" 2>&1); rc2=\$?
check "X12b exit" "\$rc2" "0"
check "X12b reuses 9 (descending)" "\$(printf '%s' "\$out2" | grep -c 'pr/9 opened')" "1"
check "X12b no create called" "\$(grep -c '^pr create' "$TX/stub/gh.argv" 2>/dev/null || true)" "0"

# an older open row beneath a newer non-open one — the open one wins regardless of number.
t3=\$(bash .git/zero.sh claim X12c)
echo work > "\$t3/f"; git -C "\$t3" add -A; git -C "\$t3" commit -qm work
printf 'X12c body\n' > \$(bash .git/zero.sh mr-body-path X12c)
printf '[{"number":2,"headRefOid":"cccc","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/2"},{"number":9,"headRefOid":"dddd","baseRefName":"main","state":"CLOSED","url":"https://example.invalid/pr/9c"}]' \
  > "$TX/stub/gh-list.out"
out3=\$(bash .git/zero.sh mr X12c "\$t3" 2>&1); rc3=\$?
check "X12c exit" "\$rc3" "0"
check "X12c open wins over newer non-open" "\$(printf '%s' "\$out3" | grep -c 'pr/2 opened')" "1"

# an older merged row and a newer closed one, neither open — highest number decides, and (its sha
# not matching this branch's tip) is treated as no live request: a fresh one opens.
t4=\$(bash .git/zero.sh claim X12d)
echo work > "\$t4/f"; git -C "\$t4" add -A; git -C "\$t4" commit -qm work
printf 'X12d body\n' > \$(bash .git/zero.sh mr-body-path X12d)
printf '[{"number":5,"headRefOid":"eeee","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/5"},{"number":8,"headRefOid":"ffff","baseRefName":"main","state":"CLOSED","url":"https://example.invalid/pr/8"}]' \
  > "$TX/stub/gh-list.out"
printf 'https://example.invalid/pr/88\n' > "$TX/stub/gh-create.out"
out4=\$(bash .git/zero.sh mr X12d "\$t4" 2>&1); rc4=\$?
check "X12d exit" "\$rc4" "0"
check "X12d opens fresh" "\$(printf '%s' "\$out4" | grep -c 'pr/88 opened')" "1"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x12drive.sh" || FAILED=1
# X12 PASS — with two `open` requests the newest number wins outright regardless of the rows'
# order; a single `open` row wins over a newer non-`open` one; with no `open` row at all the
# highest number decides which row is judged, and that row's own state/sha still governs the
# verdict. No case creates a second request where one already stood.

# X13 — an `open` request retargeted to another base is reused unchanged and named; one still on
# the target base names neither
mkorigin "$TX/x13code"; mkrepo "$TX/x13plan"
( cd "$TX/x13plan"; printf -- '- [ ] X13a task\n- [ ] X13b task\n' > todo.md
  for t in X13a X13b; do mktask "$t"; done; git add -A; git commit -qm todo )
boot "$TX/x13code" "$TX/x13plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out"
cat > "$TX/x13drive.sh" <<DRIVE
set -uo pipefail
export PATH="$TX/bin:\$PATH"
REC="$TX/x13-session"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" "1" > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x13plan"
FAILED=0; ERRORED=0

# X13a: reviewer retargeted the open request to develop, not main.
t=\$(bash .git/zero.sh claim X13a)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
printf 'X13a body\n' > \$(bash .git/zero.sh mr-body-path X13a)
printf '[{"number":21,"headRefOid":"cccc","baseRefName":"develop","state":"OPEN","url":"https://example.invalid/pr/21"}]' \
  > "$TX/stub/gh-list.out"
out=\$(bash .git/zero.sh mr X13a "\$t" 2>&1); rc=\$?
check "X13a exit" "\$rc" "0"
check "X13a box lands up-arrow" "\$(bash .git/zero.sh box-symbol-on-base X13a)" "↑"
check "X13a names both bases" "\$(printf '%s' "\$out" | grep -c 'develop, not main')" "1"
check "X13a no create called" "\$(grep -c '^pr create' "$TX/stub/gh.argv" 2>/dev/null || true)" "0"

# X13b: an open request still on the target base — no retarget note.
rm -f "$TX/stub/gh.argv"
t2=\$(bash .git/zero.sh claim X13b)
echo work > "\$t2/f"; git -C "\$t2" add -A; git -C "\$t2" commit -qm work
printf 'X13b body\n' > \$(bash .git/zero.sh mr-body-path X13b)
printf '[{"number":22,"headRefOid":"dddd","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/22"}]' \
  > "$TX/stub/gh-list.out"
out2=\$(bash .git/zero.sh mr X13b "\$t2" 2>&1); rc2=\$?
check "X13b exit" "\$rc2" "0"
check "X13b no retarget note" "\$(printf '%s' "\$out2" | grep -c 'not main')" "0"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x13drive.sh" || FAILED=1
# X13 PASS — an `open` request a reviewer retargeted is reused unchanged, with no rival opened
# and the landing naming both the base it now points at and the target base; a request still on
# the target base is reused silently, with no retarget note.

# X14 — an id containing `/` resolves a writable body path under the coordination `.git`, and
# lands normally
mkorigin "$TX/x14code"; mkrepo "$TX/x14plan"
( cd "$TX/x14plan"; printf -- '- [ ] AREA/X14 slash task\n' > todo.md
  mktask "AREA-X14"; git add -A; git commit -qm todo )
boot "$TX/x14code" "$TX/x14plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out"
cat > "$TX/x14drive.sh" <<DRIVE
set -uo pipefail
export PATH="$TX/bin:\$PATH"
REC="$TX/x14-session"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" "1" > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x14plan"
FAILED=0; ERRORED=0
t=\$(bash .git/zero.sh claim "AREA/X14")
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
bodyfile=\$(bash .git/zero.sh mr-body-path "AREA/X14")
check "X14 body path is a real file, not a directory named AREA" "\$(case "\$bodyfile" in */AREA/*) echo NO;; *) echo yes;; esac)" "yes"
printf 'X14 body\n' > "\$bodyfile"
printf 'https://example.invalid/pr/14\n' > "$TX/stub/gh-create.out"
out=\$(bash .git/zero.sh mr "AREA/X14" "\$t" 2>&1); rc=\$?
check "X14 exit" "\$rc" "0"
check "X14 box lands up-arrow" "\$(bash .git/zero.sh box-symbol-on-base "AREA/X14")" "↑"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x14drive.sh" || FAILED=1
# X14 PASS — `mr-body-path` folds an id's `/` into `sanitize_id`'s stem rather than naming an
# unwritable directory, and the landing that follows lands `[↑]` exactly as any other id's would.

# X15 — a task line deleted mid-flight after the push refuses at `local` and names the
# request's URL
mkorigin "$TX/x15code"; mkrepo "$TX/x15plan"; mktodo "$TX/x15plan" X15
boot "$TX/x15code" "$TX/x15plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out"
cat > "$TX/x15drive.sh" <<DRIVE
set -uo pipefail
export PATH="$TX/bin:\$PATH"
REC="$TX/x15-session"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" "1" > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x15plan"
FAILED=0; ERRORED=0
t=\$(bash .git/zero.sh claim X15)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
printf 'X15 body\n' > \$(bash .git/zero.sh mr-body-path X15)
printf 'https://example.invalid/pr/15\n' > "$TX/stub/gh-create.out"
# consumed once, inside the forge call — strictly after step 1's pre-flight read the line clean.
printf '%s|X15 task\n' "\$PWD" > "$TX/stub/delete-line-target"
out=\$(bash .git/zero.sh mr X15 "\$t" 2>&1); rc=\$?
check "X15 exit" "\$rc" "5"
check "X15 names local" "\$(printf '%s' "\$out" | grep -c 'failed at local')" "1"
check "X15 names the open url" "\$(printf '%s' "\$out" | grep -c 'https://example.invalid/pr/15 is open and now belongs to nobody')" "1"
check "X15 worktree kept" "\$([ -d "\$t" ] && echo yes || echo NO)" "yes"
S=\$(git -C "\$t" symbolic-ref --short HEAD)
check "X15 target branch kept" "\$(git -C "$TX/x15code" branch --list "\$S" | wc -l | tr -d ' ')" "1"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x15drive.sh" || FAILED=1
# X15 PASS — a task line deleted from the todo strictly after the pre-flight read it clean
# (here: during the forge call) makes `tick_box` answer `missing`, and the refusal names the URL of
# the request that now belongs to nobody, keeping the target worktree and branch exactly as an
# ordinary exit 5 would.

# X16 — `mr` called by a session that does not hold the id refuses with nothing pushed,
# exit 6, not 5
mkorigin "$TX/x16code"; mkrepo "$TX/x16plan"; mktodo "$TX/x16plan" X16
boot "$TX/x16code" "$TX/x16plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out"
cat > "$TX/x16drive.sh" <<DRIVE
set -uo pipefail
export PATH="$TX/bin:\$PATH"
REC="$TX/x16-session"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" "1" > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x16plan"
FAILED=0; ERRORED=0
t=\$(bash .git/zero.sh claim X16)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
printf 'X16 body\n' > \$(bash .git/zero.sh mr-body-path X16)
printf 'https://example.invalid/pr/16\n' > "$TX/stub/gh-create.out"
cwt=\$(git worktree list --porcelain | awk -v b="refs/heads/main-task-X16" '/^worktree /{p=substr(\$0,10)} /^branch /{if(substr(\$0,8)==b){print p;exit}}')
cp "\$cwt/.owner" "$TX/x16-owner-backup"
printf '999999\nThu Jan  1 00:00:00 1970\n%s\n%s\n' "\$(sed -n 3p "\$cwt/.owner")" "\$(sed -n 4p "\$cwt/.owner")" > "\$cwt/.owner"
out=\$(bash .git/zero.sh mr X16 "\$t" 2>&1); rc=\$?
check "X16 non-owner exit" "\$rc" "6"
check "X16 says not your task" "\$(printf '%s' "\$out" | grep -c 'not your task')" "1"
check "X16 box unchanged" "\$(grep -c '\[ \] X16' todo.md)" "1"
check "X16 no forge calls" "\$([ -f "$TX/stub/gh.argv" ] && echo NO || echo yes)" "yes"
check "X16 owner worktree kept" "\$([ -d "\$t" ] && echo yes || echo NO)" "yes"
S=\$(git -C "\$t" symbolic-ref --short HEAD)
check "X16 no branch on origin" "\$(git -c safe.bareRepository=all -C "$TX/x16code-origin.git" branch --list "\$S" | wc -l | tr -d ' ')" "0"

cp "$TX/x16-owner-backup" "\$cwt/.owner"
out2=\$(bash .git/zero.sh mr X16 "\$t" 2>&1); rc2=\$?
check "X16 owner then lands" "\$rc2" "0"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x16drive.sh" || FAILED=1
# X16 PASS — a caller whose `.owner` line 1/2 name a different session is refused with exit
# **6**, before any push or forge call, changing nothing; the actual owner, restored, lands the
# same id normally afterward with exit 0.

# X17 — a fleet whose coordination and target bases carry different names: the stdout line never
# prints the branch where the request's target belongs
mkorigin "$TX/x17code"
mkdir -p "$TX/x17plan"; ( cd "$TX/x17plan"; git init -q -b plan-main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; printf -- '- [ ] X17 task\n' > todo.md
  mktask X17; git add -A; git commit -qm todo )
boot "$TX/x17code" "$TX/x17plan/todo.md"
rm -f "$TX/stub/gh.argv" "$TX/stub/gh.cwd" "$TX/stub/gh-list.out"
cat > "$TX/x17drive.sh" <<DRIVE
set -uo pipefail
export PATH="$TX/bin:\$PATH"
REC="$TX/x17-session"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" "1" > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH="1"
cd "$TX/x17plan"
FAILED=0; ERRORED=0
t=\$(bash .git/zero.sh claim X17)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
printf 'X17 body\n' > \$(bash .git/zero.sh mr-body-path X17)
printf 'https://example.invalid/pr/17\n' > "$TX/stub/gh-create.out"
out=\$(bash .git/zero.sh mr X17 "\$t" 2>&1); rc=\$?
check "X17 exit" "\$rc" "0"
check "X17 box lands on coord base plan-main" "\$(bash .git/zero.sh box-symbol-on-base X17)" "↑"
check "X17 plan-main only after 'box landed as'" "\$(printf '%s' "\$out" | sed 's/.*box landed as //' | grep -c 'plan-main')" "1"
check "X17 plan-main not before it" "\$(printf '%s' "\$out" | sed 's/box landed as.*//' | grep -c 'plan-main')" "0"
check "X17 target base main names --base" "\$(printf '%s' "\$out" | grep -c 'opened from')" "1"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TX="$TX" bash "$TX/x17drive.sh" || FAILED=1
check "X17 mr_create --base was main" "$(grep -c -- '--base main' "$TX/stub/gh.argv")" "1"
# X17 PASS — coordination base `plan-main` and target base `main` never conflate: the branch
# the box was written on (`plan-main`) appears only after `box landed as`, `mr_create` was called
# with `--base main`, and the landing succeeds exactly as a same-named-base fleet would.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
