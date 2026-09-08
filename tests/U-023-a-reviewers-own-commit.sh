#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=85s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-023-a-reviewers-own-commit — a reviewer's own commit on the branch refuses the re-entry claim
# outright (exit 8), naming the branch, both tips and the by-hand repair; the land gate's own
# exit-5 refusal stays reachable for a commit that lands mid-task instead; the repaired re-entry
# fast-forwards and reuses the one open request; and the cross-slice absence checks.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-023-a-reviewers-own-commit
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# What a reviewer's own commit on the branch does to a re-entry: the reattach fetches it from
# origin and fast-forwards the local branch to it before work resumes, so the session's own commit
# lands on top and the plain push mr_task issues fast-forwards, the request reused rather than
# opened twice. The cross-slice absence checks close the slice: MR_MODE's consultation sites, the
# target branch's two deletion paths, no URL file, no force/amend/rebase, and the coordination
# repository untouched. Two fixture repositories, plan (coordination, holds the todo) and code
# (target) — plus a local bare `origin` for the target, which has no host, so KAIZERO_FORGE is
# set for the whole scenario, the escape hatch it exists for.

### Setup
TU="$TESTROOT/U-023-a-reviewers-own-commit"; mkdir -p "$TU/bin" "$TU/stub"
# MR mode is the default, so every fixture target needs an `origin` a forge resolves
# from or the launch refuses before the case's own subject is reached. A github URL, never fetched
# (TEST_EMIT skips the doctor; the real-doctor cases use `mkorigin` instead).
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git remote add origin "https://github.com/acme/$(basename "$1").git" ); }

# target repo cloned from a local bare origin — real, fetchable, no host. $1 = target dir.
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1"; git config user.email t@t.t; git config user.name test )
}

# stub claude: prints its argv (captured to see the banner precede it in the launch log) and exits.
printf '#!/usr/bin/env bash\nprintf "ARGV: %%s\\n" "$*"\nexit 0\n' > "$TU/bin/claude"; chmod +x "$TU/bin/claude"

# stub gh/glab: record argv+cwd, one failure marker per verb ($TU/stub/<prog>-<verb>) — and,
# for `auth status`, one PER HOSTNAME too ($TU/stub/<prog>-auth-status-<host>, host from
# --hostname, blank when the fixture's origin has none) — so a case can fail one host's login
# without touching another's. Exit 0 by default (auth status passes, matching what check 6 and
# the mid-run re-check both need).
# `list`/`create` gain two more per-verb files, read if present: `<prog>-<verb>.out`
# (cat'd to stdout before anything else — the canned JSON/URL a case wants mr_list/mr_create to
# reshape) and `<prog>-<verb>.rc` (its content, read as the exit code, instead of the marker
# logic below — so a case can return 0 with empty stdout, or non-zero with real stdout, neither
# of which the marker-only mechanism above can express).
#
# check 5 calls `<verb> --help` on the resolved forge and greps its output for
# each flag mr_list/mr_create pass — so `--help` answers with the real default flag list per
# prog+verb, unless `<prog>-<verb>-help.txt` exists, which is cat'd verbatim instead.
for prog in gh glab; do
case "$prog" in
  gh)   listflags="--head --state --limit --json"; createflags="--head --base --title --body-file" ;;
  glab) listflags="--source-branch --all --output --per-page --order --sort"
        createflags="--source-branch --target-branch --title --description --yes" ;;
esac
cat > "$TU/bin/$prog" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TU/stub/$prog.argv"
printf '%s\n' "\$PWD" >> "$TU/stub/$prog.cwd"
verb=""
is_help=0
for a in "\$@"; do [ "\$a" = --help ] && is_help=1; done
case "\$1 \${2:-}" in
  "auth status") verb=auth-status ;;
  "pr create"|"mr create") verb=create ;;
  "pr list"|"mr list") verb=list ;;
esac
if [ "\$is_help" = 1 ] && [ -n "\$verb" ] && [ "\$verb" != auth-status ]; then
  helpfile="$TU/stub/$prog-\$verb-help.txt"
  if [ -f "\$helpfile" ]; then cat "\$helpfile"; exit 0; fi
  if [ "\$verb" = list ]; then printf '%s\n' $listflags; else printf '%s\n' $createflags; fi
  exit 0
fi
if [ "\$verb" = auth-status ]; then
  host=""; prev=""
  for a in "\$@"; do [ "\$prev" = --hostname ] && host="\$a"; prev="\$a"; done
  marker="$TU/stub/${prog}-auth-status-\$host"
  outfile=""; rcfile=""
else
  marker="$TU/stub/${prog}-\$verb"
  outfile="$TU/stub/${prog}-\$verb.out"
  rcfile="$TU/stub/${prog}-\$verb.rc"
fi
[ -n "\$outfile" ] && [ -f "\$outfile" ] && cat "\$outfile"
if [ -n "\$rcfile" ] && [ -f "\$rcfile" ]; then read -r rc < "\$rcfile"; exit "\${rc:-0}"; fi
if [ -n "\$verb" ] && [ -f "\$marker" ]; then cat "\$marker" >&2; exit 1; fi
exit 0
STUB
chmod +x "$TU/bin/$prog"
done

# closed PATH sets — never the ambient $PATH, so a "missing" case is really missing regardless
# of what happens to be installed on the machine running this file, and a "present" case is
# always the stub, never a real forge CLI. $1 names the variant dir, the rest are the tools it
# gets ("claude"/"gh"/"glab" copy the stubs above; anything else symlinks the real binary — git,
# flock, timeout, jq are the only ones any case needs beyond /usr/bin:/bin's own coreutils).
mkpath(){
  local d="$TU/path-$1"; shift; mkdir -p "$d"
  for t in "$@"; do
    case "$t" in
      claude|gh|glab) cp "$TU/bin/$t" "$d/$t" ;;
      *)              p=$(command -v "$t") || { echo "REFUSING: '$t' not found — cannot build $d" >&2; exit 1; }
                    ln -sf "$p" "$d/$t" ;;
    esac
  done
  printf '%s:/usr/bin:/bin' "$d"
}
ALLPATH="$(mkpath all claude flock git timeout gh glab jq)"           # everything present

export PATH="$ALLPATH" KAIZERO_FORGE=gh   # scenario-wide default; unset per-case for selection tests

### U45 — a reviewer's own commit on the branch refuses the RE-ENTRY CLAIM outright (exit 8); the land gate's own exit-5 refusal stays reachable for a commit landing mid-task; the take-back repair lets a re-entry through, reusing the one open request
mkorigin "$TU/u45code"; mkrepo "$TU/u45plan"
( cd "$TU/u45plan"; printf -- '- [ ] u45a fix widget\n' > todo.md; mkdir -p tasks
  printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/u45a.md; git add -A; git commit -qm todo )
( cd "$TU/u45code"; PATH="$TU/bin:$PATH" KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$TU/u45plan/todo.md" >/dev/null 2>&1 )
zsh="$TU/u45plan/.git/zero.sh"; url=$(printf '%q' "$TU/u45code-origin.git")
sed -i.bak "s#^ORIGIN_URL=.*#ORIGIN_URL=$url#" "$zsh"; rm -f "$zsh.bak"
printf 'https://example.invalid/pr/45\n' > "$TU/stub/gh-create.out"

cat > "$TU/u45drive1.sh" <<'DRIVE'
set -uo pipefail
FAILED=0; ERRORED=0   # this subprocess's own check() state — never inherited, see test-setup.sh
own_session "$TU/u45.rec"
export PATH="$TU/bin:$PATH"
cd "$TU/u45plan"
twt=$(bash .git/zero.sh claim u45a)
S=$(git -C "$twt" symbolic-ref --short HEAD); echo "$S" > "$TU/u45-branch"
echo hi >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "first change" >/dev/null
bodyfile=$(bash .git/zero.sh mr-body-path u45a); printf 'U45 request body\n' > "$bodyfile"
out=$(bash .git/zero.sh mr u45a "$twt"); rcm=$?
check "U45 first landing exit" "$rcm" "0"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
export TU
bash "$TU/u45drive1.sh" || FAILED=1
S=$(cat "$TU/u45-branch")

# a reviewer's own commit lands on the branch, pushed straight to origin — never through zero.sh.
zap "$TU/u45reviewer"
git clone -q "$TU/u45code-origin.git" "$TU/u45reviewer"
( cd "$TU/u45reviewer"; git config user.email r@r.r; git config user.name reviewer
  git checkout -q "$S"; echo "reviewer edit" >> f; git commit -qam "reviewer tightened the check"
  git push -q origin "$S" )
REVIEWER_TIP=$(git -c safe.bareRepository=all -C "$TU/u45code-origin.git" rev-parse "$S")
REVIEWER_TIP_SHORT=$(git -c safe.bareRepository=all -C "$TU/u45code-origin.git" rev-parse --short "$S")
LOCAL_TIP_SHORT=$(git -C "$TU/u45code" rev-parse --short "$S")

# the box comes back for another round (changes requested) — the branch itself is left alone.
sed -i.bak "s/- \[\xe2\x86\x91\] u45a/- [ ] u45a/" "$TU/u45plan/todo.md"; rm -f "$TU/u45plan/todo.md.bak"
git -C "$TU/u45plan" add todo.md; git -C "$TU/u45plan" commit -qm "reopen u45a"

# ---- arm A: the re-entry CLAIM refuses outright, before any session starts -------------------
BEFORE_WT=$(git -C "$TU/u45code" worktree list)
cat > "$TU/u45drive2.sh" <<'DRIVE'
set -uo pipefail
FAILED=0; ERRORED=0
own_session "$TU/u45.rec2"
export PATH="$TU/bin:$PATH"
cd "$TU/u45plan"
out=$(bash .git/zero.sh claim u45a 2>&1 >"$TU/u45-claim-stdout"); rcm=$?
check "U45 re-entry claim refused, exit" "$rcm" "8"
check "U45 stdout empty (no worktree path)" "$([ -s "$TU/u45-claim-stdout" ] && echo NO || echo yes)" "yes"
printf '%s' "$out" > "$TU/u45-claim-stderr"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
bash "$TU/u45drive2.sh" || FAILED=1
ERR2=$(cat "$TU/u45-claim-stderr")
check "U45 stderr names the branch" "$([ "$(printf '%s' "$ERR2" | grep -c "$S")" -ge 1 ] && echo yes || echo no)" "yes"
check "U45 stderr names local short tip" "$([ "$(printf '%s' "$ERR2" | grep -c "$LOCAL_TIP_SHORT")" -ge 1 ] && echo yes || echo no)" "yes"
check "U45 stderr names origin short tip" "$([ "$(printf '%s' "$ERR2" | grep -c "$REVIEWER_TIP_SHORT")" -ge 1 ] && echo yes || echo no)" "yes"
check "U45 stderr names the repair" "$([ "$(printf '%s' "$ERR2" | grep -cE "branch -f $S origin/$S|branch -D $S")" -ge 1 ] && echo yes || echo no)" "yes"
check "U45 no --force anywhere in the refusal" "$(printf '%s' "$ERR2" | grep -c -- '--force')" "0"
check "U45 nothing created (worktree list unchanged)" "$([ "$BEFORE_WT" = "$(git -C "$TU/u45code" worktree list)" ] && echo yes || echo NO)" "yes"
check "U45 branch on origin still has reviewer's commit" "$(git -c safe.bareRepository=all -C "$TU/u45code-origin.git" log --format=%s "$S" | grep -c 'reviewer tightened')" "1"
# the refusal opened no second request
check "U45 gh pr create called exactly once so far" "$(grep -c '^pr create' "$TU/stub/gh.argv" 2>/dev/null || true)" "1"

# ---- arm B (backstop): a claim that already passed, then a reviewer's commit lands mid-task ---
mkorigin "$TU/u45bcode"; mkrepo "$TU/u45bplan"
( cd "$TU/u45bplan"; printf -- '- [ ] u45b fix widget\n' > todo.md; mkdir -p tasks
  printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/u45b.md; git add -A; git commit -qm todo )
( cd "$TU/u45bcode"; PATH="$TU/bin:$PATH" KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$TU/u45bplan/todo.md" >/dev/null 2>&1 )
zshb="$TU/u45bplan/.git/zero.sh"; urlb=$(printf '%q' "$TU/u45bcode-origin.git")
sed -i.bak "s#^ORIGIN_URL=.*#ORIGIN_URL=$urlb#" "$zshb"; rm -f "$zshb.bak"
printf 'https://example.invalid/pr/45b\n' > "$TU/stub/gh-create.out"
# one continuous session spans both the claim and the later `mr` call — ownership is a per-PID
# lease (find_owner requires the recorded pid still alive), so splitting claim and land across two
# process invocations would refuse the second as "not the owner". The script backgrounds itself,
# signals readiness after the claim, waits for the outer shell's go-ahead once the reviewer has
# raced it, then runs `mr` in that same still-live process.
rm -f "$TU/u45b-ready" "$TU/u45b-go"
cat > "$TU/u45bdrive.sh" <<'DRIVE'
set -uo pipefail
FAILED=0; ERRORED=0
own_session "$TU/u45b.rec"
export PATH="$TU/bin:$PATH"
cd "$TU/u45bplan"
twt=$(bash .git/zero.sh claim u45b)
echo "$twt" > "$TU/u45b-twt"
Sb=$(git -C "$twt" symbolic-ref --short HEAD); echo "$Sb" > "$TU/u45b-branch"
echo hi >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "u45b change" >/dev/null
touch "$TU/u45b-ready"
while [ ! -e "$TU/u45b-go" ]; do sleep 0.2; done
bodyfile=$(bash .git/zero.sh mr-body-path u45b); printf 'U45b request body\n' > "$bodyfile"
out=$(bash .git/zero.sh mr u45b "$twt" 2>&1); rcm=$?
check "U45b land gate refused, exit" "$rcm" "5"
check "U45b stderr carries git's own rejection text" "$([ "$(printf '%s' "$out" | grep -cE '\[rejected\].*\(fetch first\)|! \[rejected\]')" -ge 1 ] && echo yes || echo no)" "yes"
check "U45b no --force anywhere" "$(printf '%s' "$out" | grep -c -- '--force')" "0"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
export TU
bash "$TU/u45bdrive.sh" > "$TESTROOT/u45bdrive.out" 2>&1 &
U45BPID=$!
while [ ! -e "$TU/u45b-ready" ]; do sleep 0.2; done
SB=$(cat "$TU/u45b-branch")

# a reviewer commits straight to origin AFTER the claim above already handed the worktree out,
# BEFORE this session's own Hand off — the claim itself could not have seen this.
zap "$TU/u45breviewer"
git clone -q "$TU/u45bcode-origin.git" "$TU/u45breviewer"
( cd "$TU/u45breviewer"; git config user.email r@r.r; git config user.name reviewer
  # the session's own local branch has never been pushed yet (mr hasn't run) — the reviewer's
  # commit is the FIRST thing to reach origin under this name, forked from the same base the
  # session's own branch forked from, so the session's later push meets a divergent tip, not a
  # missing ref.
  git checkout -q -b "$SB" main; echo "reviewer raced this one" >> f; git commit -qam "reviewer raced the session"
  git push -q origin "$SB" )

touch "$TU/u45b-go"
wait "$U45BPID" || FAILED=1
cat "$TESTROOT/u45bdrive.out"
u45bsym=$(bash "$TU/u45bplan/.git/zero.sh" box-symbol-on-base u45b 2>/dev/null)
# want a blank/space box, not ↑
check "U45b box still not landed (never ticked up)" "$([ "$u45bsym" != "↑" ] && echo yes || echo no)" "yes"

# ---- arm C: the README repair, then a re-entry that fast-forwards and reuses the request ------
git -C "$TU/u45code" fetch origin "$S"
git -C "$TU/u45code" branch -f "$S" "origin/$S"

# mr_list's stub answers empty by default (no open rows) — drive1's own first landing relied on
# that to take the fresh-create path. The reuse this arm proves needs the request drive1 already
# opened to show up as an open row now, same idiom X-001 uses.
printf '[{"number":45,"headRefOid":"anything","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/45"}]' \
  > "$TU/stub/gh-list.out"

cat > "$TU/u45drive3.sh" <<'DRIVE'
set -uo pipefail
FAILED=0; ERRORED=0
own_session "$TU/u45.rec3"
export PATH="$TU/bin:$PATH"
cd "$TU/u45plan"
twt=$(bash .git/zero.sh claim u45a); rcc=$?
check "U45 repaired re-entry claim exit" "$rcc" "0"
check "U45 worktree carries reviewer's commit" "$(git -C "$twt" log --format=%s | grep -c 'reviewer tightened')" "1"
echo "$twt" > "$TU/u45-twt3"
echo more >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "second change" >/dev/null
bodyfile=$(bash .git/zero.sh mr-body-path u45a); printf 'U45 request body\n' > "$bodyfile"
out=$(bash .git/zero.sh mr u45a "$twt" 2>&1); rcm=$?
check "U45 repaired re-entry push fast-forwards, exit" "$rcm" "0"
check "U45 no push-refusal message" "$(printf '%s' "$out" | grep -c 'land gate failed at forge: push')" "0"
check "U45 no force in the command" "$(printf '%s' "$out" | grep -c -- '--force')" "0"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
bash "$TU/u45drive3.sh" || FAILED=1

check "U45 branch on origin still has reviewer's commit" "$(git -c safe.bareRepository=all -C "$TU/u45code-origin.git" log --format=%s "$S" | grep -c 'reviewer tightened')" "1"
check "U45 branch on origin now has the second change atop it" "$(git -c safe.bareRepository=all -C "$TU/u45code-origin.git" log -1 --format=%s "$S" | grep -c 'second change')" "1"
check "U45 gh pr create called exactly once total (reused)" "$(grep -c '^pr create' "$TU/stub/gh.argv" 2>/dev/null || true)" "1"
rm -f "$TU/stub/gh-create.out"
# U45 PASS — the re-entry's own claim refuses outright with exit 8, naming the branch, both short
# tips and the repair command, before any session starts, any worktree is created or any forge
# call is made — origin's tip (the reviewer's commit) is untouched and no second request is
# opened. The land gate's own exit-5 refusal stays reachable for the race the claim cannot see —
# a reviewer's commit landing on origin after a claim already handed out a worktree, before that
# session's own Hand off — carrying git's [rejected]/(fetch first) text, no --force, box never
# ticked. Once the take-back procedure's own repair (git fetch + git branch -f onto origin's tip)
# has run, the next claim proceeds, the worktree carries the reviewer's commit, the session's own
# commit lands on top, mr_task's plain push fast-forwards, and gh pr create was called exactly
# once across the whole case — the same request reused, never a second one.

### U46 — cross-slice absence checks: `MR_MODE`'s consultation sites, the target branch's two deletion paths, no URL file, no force/amend/rebase, the coordination repository untouched
mrmodesites=$(grep -cE '"\$MR_MODE"|MR_MODE=1|MR_MODE=0|MR_MODE=%q' "$REAL_SCRIPT" || true)
# sync_branch_from_origin's own guard is gone; acquire_task gains one new guard for its own
# origin-branch lookup in its place
check "U46 MR_MODE code+comment sites" "$mrmodesites" "23"
check "U46 sync_branch_from_origin named nowhere" "$(grep -c 'sync_branch_from_origin' "$REAL_SCRIPT" || true)" "0"
funcbody(){ awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p{print} p && /^}/ {exit}' "$REAL_SCRIPT"; }
for fn in merge_task merge_two_repos merge_same_repo print_report print_fleet_total; do
  n=$(funcbody "$fn" | grep -c MR_MODE || true)
  check "U46 $fn never reads MR_MODE" "$n" "0"
done

# a task branch is deleted on exactly three paths against $TARGET_ROOT — teardown_target's
# ancestry-checked branch -D (the unmerged, still-under-review case, reached via mr_task's own
# success path too), sync-mrs' sha-matched merged case, and mr_task's own already-landed-at-
# claim-time shortcut ($sym = x, the branch already an ancestor of $TB — nothing to review, so
# mr_task deletes it directly rather than leaving it for the sync). None of these three
# is the fetch-and-fast-forward reattach this ticket removed.
targetDeletes=$(grep -c 'git -C "\$TARGET_ROOT" branch -D' "$REAL_SCRIPT" || true)
check "U46 target branch deleted on exactly 3 paths" "$targetDeletes" "3"
mrDeletes=$(funcbody mr_task | grep -c 'branch -[dD] .*\$s\b\|branch -[dD] .*branch2' || true)
check "U46 mr_task's own direct delete is the already-landed [x] shortcut only" "$mrDeletes" "1"

# no file anywhere accumulates request URLs — they live only on mr_task's stdout line and
# sync-mrs' own, never collected into a counter-style file the way todos-seconds/todos-done are.
urlFiles=$(grep -c 'GITDIR.*url\|url.*GITDIR\|"\$COORD_GITDIR/.*url' "$REAL_SCRIPT" || true)
check "U46 no counter-style file collects request URLs" "$urlFiles" "0"

# the coordination repository is never pushed or pulled, in this mode any more than any other.
coordNetwork=$(grep -cE 'git -C "\$COORD_ROOT" (push|pull|fetch)' "$REAL_SCRIPT" || true)
check "U46 coordination repository never pushed/pulled/fetched" "$coordNetwork" "0"

# no push in this mode carries --force/--force-with-lease, and no commit is amended after a push.
check "U46 no --force/--force-with-lease anywhere in the script" "$(grep -c -- '--force-with-lease\|push.*--force[^-]' "$REAL_SCRIPT" || true)" "0"
check "U46 no commit --amend anywhere in the script" "$(grep -c 'commit --amend' "$REAL_SCRIPT" || true)" "0"
# the one `rebase` in the script aborts a stray rebase state a human left behind (repair_wt's
# worktree recovery) — it never starts one; that is the only form allowed.
check "U46 no rebase started, only a stray one aborted (total)" "$(grep -c 'git .*rebase' "$REAL_SCRIPT" || true)" "1"
check "U46 no rebase started, only a stray one aborted (--abort)" "$(grep -c 'rebase --abort' "$REAL_SCRIPT" || true)" "1"
# U46 PASS — MR_MODE is read or written in exactly the sites this slice's docs list (flag parse,
# TB's value, the bake, the banner and doctor-call sites, the two launch refusals, claim_task's
# pre-claim fetch, acquire_task's own base-refresh guard and its post-acquire_target
# origin-branch-lookup guard (BUG 048 — sync_branch_from_origin's own guard is gone, this is its
# replacement), run_loop's MR-mode block, wait_for_dependency_clear's three behaviours, sync_mrs'
# own guard) plus explanatory comments, and never inside merge_task, merge_two_repos,
# merge_same_repo, print_report or print_fleet_total; the target branch is deleted on exactly the
# three paths the docs name — teardown_target's ancestry-checked delete, sync_mrs' sha-matched
# merged case, and mr_task's own already-landed-at-claim-time shortcut — never a fourth; no file
# collects request URLs; the coordination repository is never pushed, pulled or fetched; and no
# push carries --force/--force-with-lease, no commit is amended after a push, and the script's
# one rebase call only ever aborts one, never starts one.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
