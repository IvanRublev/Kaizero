#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=350s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCENARIO_DIR/test-setup.sh"

# D-001-a-branch-take-back-from-origin — a claim treats origin as the source of truth for a
# task's own branch: no local branch but origin has one is tracked, not forked fresh; a diverged
# (or behind) local copy refuses the claim outright with exit 8, naming the branch, both tips and
# the repair — nothing moved, nothing created; a local copy ahead of origin is left alone; origin
# unreachable (base reachable, branch lookup failing) refuses the claim outright, nothing
# created; and a Hand off tears down the target worktree, taking any untracked file with it,
# while keeping the branch for a take-back.
# Needs real claude: no — each run_claim driver writes its own BUG 057 session record so
# ensure_owner resolves it as the owner, no claude-named ancestor needed
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/D-001-a-branch-take-back-from-origin
# Wall-clock budget: its longest Run command is `timeout 40` — allow that command at least 40s
#
# Five real, fetchable, no-host bare origins (mkorigin), one per case (D1-D5), each with its own
# coordination (mkrepo+mktodo) and target repository — KAIZERO_FORGE=gh for the whole
# scenario, the escape hatch a hostless origin needs. claim runs through ensure_owner, so every
# call goes through a fresh run_claim helper: a driver script that writes a BUG 057 session
# record naming itself before calling zero.sh, so find_owner resolves that fresh process as the
# owner rather than reading anything from the suite's own real claude session.

TD="$TESTROOT/D-001-a-branch-take-back-from-origin"; mkdir -p "$TD/bin"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1"; git config user.email t@t.t; git config user.name test )
}
printf '#!/usr/bin/env bash\n[ "$1 $2" = "auth status" ] && exit 0\nexit 0\n' > "$TD/bin/gh"; chmod +x "$TD/bin/gh"
export PATH="$TD/bin:$PATH" KAIZERO_FORGE=gh

# bakes .git/zero.sh in the coordination dir ($2), ORIGIN_URL patched to the target's own bare
# origin (TEST_EMIT skips the doctor, so the bake never resolves it from a real remote lookup).
bake(){
  ( cd "$1"; KAIZERO_TEST_EMIT=1 bash "$SCRIPT" "$2/todo.md" >/dev/null 2>&1 )
  local zsh="$2/.git/zero.sh" url; url=$(printf '%q' "$1-origin.git")
  sed -i.bak "s#^ORIGIN_URL=.*#ORIGIN_URL=$url#" "$zsh"; rm -f "$zsh.bak"
}

# run a claim as its own disposable driver process, writing a BUG 057 session record naming
# itself so ensure_owner has a valid owner to resolve — no ancestor process named claude needed.
run_claim(){
  local plandir=$1 id=$2 errfile=$3 drv
  drv="$TD/drv-$id-$RANDOM.sh"
  cat > "$drv" <<'DRV'
REC="$0.rec"
printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
DRV
  printf 'cd "%s"\nbash .git/zero.sh claim %s\n' "$plandir" "$id" >> "$drv"
  bash "$drv" 2>"$errfile"
}

# D1 — no local branch but origin has it: the claim tracks origin's tip, not a fresh fork off base
mkorigin "$TD/d1code"; mkrepo "$TD/d1plan"
( cd "$TD/d1plan"; printf -- '- [ ] d1a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d1a.md; git add -A; git commit -qm todo )
bake "$TD/d1code" "$TD/d1plan"

# a prior session, or another machine, pushed the branch straight to origin — d1code never saw it.
git clone -q "$TD/d1code-origin.git" "$TD/d1prior"
( cd "$TD/d1prior"; git config user.email t@t.t; git config user.name test
  git checkout -qb d1a-fix-widget; echo prior >> f; git commit -qam "prior work"; git push -q origin d1a-fix-widget )
check "D1 pre-check: no local branch in target" "$(git -C "$TD/d1code" branch --list d1a-fix-widget | wc -l | tr -d ' ')" "0"

twt=$(run_claim "$TD/d1plan" d1a "$TD/d1.err"); rc=$?
check "D1 claim exit" "$rc" "0"
check "D1 target worktree tip == origin's tip" "$([ "$(git -C "$twt" rev-parse HEAD 2>/dev/null)" = "$(git -c safe.bareRepository=all -C "$TD/d1code-origin.git" rev-parse d1a-fix-widget)" ] && echo yes || echo NO)" "yes"
check "D1 prior commit present (not a fresh fork)" "$(git -C "$twt" log --format=%s 2>/dev/null | grep -c 'prior work')" "1"
# D1 PASS — acquire_task's required branch lookup finds d1a-fix-widget on origin though no local
# copy exists; make_target_wt's track mode checks the worktree out directly at
# refs/remotes/origin/d1a-fix-widget, the exact ref that lookup's own fetch resolved — never
# --track/upstream resolution — so the worktree's tip is origin's tip, carrying the prior work,
# never a divergent fresh fork off $TB.

# D2 — a diverged local branch refuses the claim outright, nothing moved, nothing created
mkorigin "$TD/d2code"; mkrepo "$TD/d2plan"
( cd "$TD/d2plan"; printf -- '- [ ] d2a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d2a.md; git add -A; git commit -qm todo )
bake "$TD/d2code" "$TD/d2plan"

twt=$(run_claim "$TD/d2plan" d2a "$TD/d2a.err")   # first claim: fresh fork off base
echo local-only >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "local-only commit" >/dev/null
OLD_TIP=$(git -C "$twt" rev-parse --short HEAD)
OLD_TIP_FULL=$(git -C "$twt" rev-parse HEAD)
git -C "$TD/d2code" worktree remove --force "$twt"   # simulate: the session died before it ever pushed

# another machine's session pushed a DIFFERENT commit under the same branch name straight to origin
git clone -q "$TD/d2code-origin.git" "$TD/d2other"
( cd "$TD/d2other"; git config user.email o@o.o; git config user.name other
  git checkout -qb d2a-fix-widget; echo other-work >> f; git commit -qam "other machine's work"; git push -q origin d2a-fix-widget )
remote_tip=$(git -c safe.bareRepository=all -C "$TD/d2code-origin.git" rev-parse d2a-fix-widget)
remote_tip_short=$(git -c safe.bareRepository=all -C "$TD/d2code-origin.git" rev-parse --short d2a-fix-widget)

BEFORE_REFS=$(git -C "$TD/d2code" for-each-ref refs/heads/)
twt2=$(run_claim "$TD/d2plan" d2a "$TD/d2.err"); rc=$?
AFTER_REFS=$(git -C "$TD/d2code" for-each-ref refs/heads/)
check "D2 second claim exit" "$rc" "8"
check "D2 stdout empty" "$([ -z "$twt2" ] && echo yes || echo NO)" "yes"
_v="$(grep -c 'd2a-fix-widget' "$TD/d2.err")"; check "D2 stderr names the branch" "$([ "$_v" -ge 1 ] && echo yes || echo no)" "yes"
_v="$(grep -c "$OLD_TIP" "$TD/d2.err")"; check "D2 stderr names local short tip" "$([ "$_v" -ge 1 ] && echo yes || echo no)" "yes"
_v="$(grep -c "$remote_tip_short" "$TD/d2.err")"; check "D2 stderr names origin short tip" "$([ "$_v" -ge 1 ] && echo yes || echo no)" "yes"
_v="$(grep -cE 'branch -f d2a-fix-widget origin/d2a-fix-widget|branch -D d2a-fix-widget' "$TD/d2.err")"; check "D2 stderr names a repair command" "$([ "$_v" -ge 1 ] && echo yes || echo no)" "yes"
check "D2 local branch tip unchanged" "$([ "$(git -C "$TD/d2code" rev-parse d2a-fix-widget)" = "$OLD_TIP_FULL" ] && echo yes || echo NO)" "yes"
check "D2 no worktree created" "$([ "$BEFORE_REFS" = "$AFTER_REFS" ] && echo yes || echo NO)" "yes"
# D2 PASS — neither tip is an ancestor of the other; the claim refuses with exit 8 before
# creating anything, its stderr names the branch, both short tips and the repair commands, and
# the local ref is left exactly where it was — never fast-forwarded, reset, merged or rebased.

# D3 — a local branch ahead of origin is left alone, no reset, no message
mkorigin "$TD/d3code"; mkrepo "$TD/d3plan"
( cd "$TD/d3plan"; printf -- '- [ ] d3a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d3a.md; git add -A; git commit -qm todo )
bake "$TD/d3code" "$TD/d3plan"

twt=$(run_claim "$TD/d3plan" d3a "$TD/d3a.err")
echo first >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "first change" >/dev/null
git -C "$twt" push -q origin "HEAD:refs/heads/d3a-fix-widget"   # origin now knows this tip
echo second >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "second change" >/dev/null   # never pushed
LOCAL_TIP=$(git -C "$twt" rev-parse HEAD)
git -C "$TD/d3code" worktree remove --force "$twt"   # simulate: the session died before the second push

twt2=$(run_claim "$TD/d3plan" d3a "$TD/d3.err"); rc=$?
check "D3 second claim exit" "$rc" "0"
check "D3 no diverge/reset message printed" "$(grep -c 'diverged from origin' "$TD/d3.err")" "0"
check "D3 twt2 tip unchanged (still ahead of origin)" "$([ "$(git -C "$twt2" rev-parse HEAD)" = "$LOCAL_TIP" ] && echo yes || echo NO)" "yes"
# D3 PASS — origin's tip is an ancestor of the local tip, so acquire_task's lookup leaves the
# branch untouched (compares tips, moves nothing) and the claim proceeds; the next push (not
# exercised here) would fast-forward origin as usual.

# D4 — origin unreachable at the claim refuses outright, nothing created
mkorigin "$TD/d4code"; mkrepo "$TD/d4plan"
( cd "$TD/d4plan"; printf -- '- [ ] d4a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d4a.md; git add -A; git commit -qm todo )
bake "$TD/d4code" "$TD/d4plan"
git -C "$TD/d4code" remote set-url origin "$TD/d4code-origin.git.unreachable"   # fetch fails fast, no network hang

out=$(run_claim "$TD/d4plan" d4a "$TD/d4.err"); rc=$?
errtxt=$(cat "$TD/d4.err")
check "D4 claim exit refused" "$([ "$rc" -ne 0 ] && echo yes || echo NO)" "yes"
check "D4 refusal message" "$(printf '%s' "$errtxt" | grep -c 'acquire d4a: origin unreachable — claim refused, nothing created')" "1"
check "D4 no worktree created" "$(git -C "$TD/d4code" worktree list | grep -c 'tt-d4a-fix-widget')" "0"
check "D4 no local branch created" "$(git -C "$TD/d4code" branch --list 'd4a-*' | wc -l | tr -d ' ')" "0"
# D4 PASS — the required branch fetch's own failure (a genuinely unreachable origin, not "no such
# branch") refuses the claim before any worktree, branch or .owner is created — the same
# refusal, the outage park then holds the fleet on, until origin answers again.

# D5 — a Hand off tears down the target worktree, keeps the branch for a later take-back
mkorigin "$TD/d5code"; mkrepo "$TD/d5plan"
( cd "$TD/d5plan"; printf -- '- [ ] d5a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d5a.md; git add -A; git commit -qm todo )
bake "$TD/d5code" "$TD/d5plan"
printf '#!/usr/bin/env bash\ncase "$1 $2" in\n"auth status") exit 0 ;;\n"pr list") exit 0 ;;\n"pr create") echo https://example.invalid/pr/5 ;;\nesac\nexit 0\n' > "$TD/bin/gh"; chmod +x "$TD/bin/gh"

drv5="$TD/drv5.sh"
cat > "$drv5" <<'DRV'
REC="$0.rec"
printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
FAILED=0; ERRORED=0
DRV
cat >> "$drv5" <<DRV
cd "$TD/d5plan"
twt=\$(bash .git/zero.sh claim d5a)
echo "\$twt" > "$TD/d5-twt"
echo change >> "\$twt/f"; git -C "\$twt" add -A; git -C "\$twt" commit -qm "d5 change" >/dev/null
echo untracked-content > "\$twt/d5-untracked.txt"   # never survives the Hand off's teardown
bodyfile=\$(bash .git/zero.sh mr-body-path d5a); printf 'D5 request body\n' > "\$bodyfile"
out=\$(bash .git/zero.sh mr d5a "\$twt" 2>"$TD/d5.err"); rcm=\$?
check "D5 mr exit" "\$rcm" "0"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRV
bash "$drv5" || FAILED=1
TWT5=$(cat "$TD/d5-twt")
BR5=$(git -C "$TD/d5code" for-each-ref --format='%(refname:short)' 'refs/heads/d5a-*')
check "D5 target worktree removed" "$([ ! -d "$TWT5" ] && echo yes || echo NO)" "yes"
check "D5 worktree list has no entry for it" "$(git -C "$TD/d5code" worktree list | grep -c "$BR5")" "0"
check "D5 target branch still exists (kept)" "$(git -C "$TD/d5code" branch --list "$BR5" | wc -l | tr -d ' ')" "1"
_v="$(grep -c 'd5-untracked.txt' "$TD/d5.err")"; check "D5 untracked file named as removed with worktree" "$([ "$_v" -ge 1 ] && echo yes || echo no)" "yes"
check "D5 message never says left-as-is" "$(grep -c 'left as-is' "$TD/d5.err")" "0"
check "D5 untracked file actually gone" "$([ ! -e "$TWT5/d5-untracked.txt" ] && echo yes || echo NO)" "yes"
# D5 PASS — mr_task's success path calls teardown_target: the target worktree is gone from git
# worktree list immediately after the Hand off, but its branch survives (not yet an ancestor of
# $TB) — exactly what a take-back's next claim reattaches to; its untracked file is named as
# removed with the worktree (never "left as-is") and is in fact gone.

# D6 — branch lookup unreachable while the base itself is reachable: same refusal, no fork
mkorigin "$TD/d6code"; mkrepo "$TD/d6plan"
( cd "$TD/d6plan"; printf -- '- [ ] d6a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d6a.md; git add -A; git commit -qm todo )
bake "$TD/d6code" "$TD/d6plan"

# a git shim ahead of the real one on PATH: passes every call through except ls-remote --heads
# (origin_branches_for_id's own probe), which it fails — the base fetch (a plain fetch, not
# ls-remote) still succeeds, isolating the branch-lookup-only failure from a wholly unreachable origin.
REALGIT="$(type -P git)"
mkdir -p "$TD/d6bin"
cat > "$TD/d6bin/git" <<EOF
#!/usr/bin/env bash
case " \$* " in *" ls-remote --heads "*) exit 128 ;; esac
exec "$REALGIT" "\$@"
EOF
chmod +x "$TD/d6bin/git"
drv6="$TD/drv6.sh"
cat > "$drv6" <<'DRV'
REC="$0.rec"
printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
DRV
printf 'export PATH="%s:$PATH"\ncd "%s"\nbash .git/zero.sh claim d6a\n' "$TD/d6bin" "$TD/d6plan" >> "$drv6"
out=$(bash "$drv6" 2>"$TD/d6.err"); rc=$?
check "D6 claim exit refused (base reachable, lookup not)" "$rc" "1"
check "D6 refusal message" "$(grep -c 'acquire d6a: origin unreachable — claim refused, nothing created' "$TD/d6.err")" "1"
check "D6 base was fetched (reachable)" "$(git -C "$TD/d6code" rev-parse -q --verify refs/remotes/origin/main >/dev/null 2>&1 && echo yes || echo NO)" "yes"
check "D6 no worktree created" "$(git -C "$TD/d6code" worktree list | grep -c 'tt-d6a-fix-widget')" "0"
# D6 PASS — the base refresh (a plain fetch, unaffected by the shim) succeeds while
# origin_branches_for_id's own ls-remote --heads fails: the claim still refuses with the same
# "origin unreachable" message, proving the two lookups are distinguished by their own exit
# status, not by one shared network probe.

# D7 — behind origin with a dirty existing worktree (tracked + untracked change): refused, nothing touched
mkorigin "$TD/d7code"; mkrepo "$TD/d7plan"
( cd "$TD/d7plan"; printf -- '- [ ] d7a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d7a.md; git add -A; git commit -qm todo )
bake "$TD/d7code" "$TD/d7plan"

twt=$(run_claim "$TD/d7plan" d7a "$TD/d7a.err")   # first claim: fresh fork off base, worktree stays mounted
echo untracked-in-d7 > "$twt/d7-untracked.txt"
echo dirty-tracked >> "$twt/f"   # uncommitted change to a tracked file, never committed

# origin gets a commit this local branch never saw — origin now ahead of local
git clone -q "$TD/d7code-origin.git" "$TD/d7other"
( cd "$TD/d7other"; git config user.email o@o.o; git config user.name other
  git checkout -qb d7a-fix-widget; echo other-work >> f; git commit -qam "other machine's work"; git push -q origin d7a-fix-widget )
BEFORE_TIP=$(git -C "$TD/d7code" rev-parse d7a-fix-widget)
BEFORE_TRACKED=$(cat "$twt/f")

twt2=$(run_claim "$TD/d7plan" d7a "$TD/d7.err"); rc=$?
check "D7 claim exit" "$rc" "8"
check "D7 branch tip unchanged" "$([ "$(git -C "$TD/d7code" rev-parse d7a-fix-widget)" = "$BEFORE_TIP" ] && echo yes || echo NO)" "yes"
check "D7 tracked file contents unchanged" "$([ "$(cat "$twt/f")" = "$BEFORE_TRACKED" ] && echo yes || echo NO)" "yes"
check "D7 untracked file still present" "$([ -f "$twt/d7-untracked.txt" ] && echo yes || echo NO)" "yes"
check "D7 existing worktree still mounted" "$([ -d "$twt" ] && echo yes || echo NO)" "yes"
# D7 PASS — the existing target worktree's dirty tracked change and untracked file are exactly
# as they were, the branch was not fast-forwarded, reset or moved, and the worktree stays
# mounted — the refusal never touches a file it did not create.

# D8 — the target worktree checked out on some other (foreign) branch is untouched by a claim
mkorigin "$TD/d8code"; mkrepo "$TD/d8plan"
( cd "$TD/d8plan"; printf -- '- [ ] d8a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d8a.md; git add -A; git commit -qm todo )
bake "$TD/d8code" "$TD/d8plan"

( cd "$TD/d8code"; git checkout -qb some-operator-branch; echo operator-work >> f; git commit -qam "operator's own work" )
FOREIGN_TIP=$(git -C "$TD/d8code" rev-parse some-operator-branch)

twt=$(run_claim "$TD/d8plan" d8a "$TD/d8.err"); rc=$?
# D8 claim exit: whatever the claim decides — not asserted
echo "D8 claim exit (informational, not asserted) : $rc"
check "D8 foreign branch tip unchanged" "$([ "$(git -C "$TD/d8code" rev-parse some-operator-branch)" = "$FOREIGN_TIP" ] && echo yes || echo NO)" "yes"
check "D8 foreign branch commit still present" "$(git -C "$TD/d8code" log --format=%s some-operator-branch | grep -c "operator's own work")" "1"
echo "D8 foreign branch's working file unchanged : $(git -C "$TD/d8code" show some-operator-branch:f)"
# D8 PASS — a claim, whatever it decides for d8a, never touches some-operator-branch's tip,
# history or file contents — the operator's own foreign checkout is not this claim's concern.

# D9 — a refused claim repeats identically and does not wedge the fleet: a second unchecked task
# in the same target still claims fine
mkorigin "$TD/d9code"; mkrepo "$TD/d9plan"
( cd "$TD/d9plan"; printf -- '- [ ] d9a fix widget\n- [ ] d9b fix gadget\n' > todo.md; mkdir -p tasks
  printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d9a.md; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d9b.md
  git add -A; git commit -qm todo )
bake "$TD/d9code" "$TD/d9plan"

twt=$(run_claim "$TD/d9plan" d9a "$TD/d9a.err")
echo local-only >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "local-only commit" >/dev/null
git -C "$TD/d9code" worktree remove --force "$twt"
git clone -q "$TD/d9code-origin.git" "$TD/d9other"
( cd "$TD/d9other"; git config user.email o@o.o; git config user.name other
  git checkout -qb d9a-fix-widget; echo other-work >> f; git commit -qam "other machine's work"; git push -q origin d9a-fix-widget )

out1=$(run_claim "$TD/d9plan" d9a "$TD/d9-1.err"); rc1=$?
out2=$(run_claim "$TD/d9plan" d9a "$TD/d9-2.err"); rc2=$?
check "D9 first refusal exit" "$rc1" "8"
# want 8, identical repeat
check "D9 second refusal exit" "$rc2" "8"
check "D9 refusal messages identical" "$([ "$(cat "$TD/d9-1.err")" = "$(cat "$TD/d9-2.err")" ] && echo yes || echo NO)" "yes"
out3=$(run_claim "$TD/d9plan" d9b "$TD/d9b.err"); rc3=$?
# the refused task never wedges the round
check "D9 second unchecked task still claims fine" "$rc3" "0"
# D9 PASS — a repeated refused claim on the same task gives the exact same exit code and message
# both times (nothing about the refusal is stateful or one-shot), and a different unchecked task
# in the same pass claims normally — the refusal costs one task, never the round. Structurally:
# neither held_todos nor no_claim_signature (kaizero.sh:1699, 4600) reads anything the exit-8
# path writes — that path returns before claim_owner/set_current ever run (see the Atomicity
# check) — so the pre-existing no-claim-mark/signature park the shell already uses for every
# other refusal code (1/3/4/6/7) applies here unchanged: a session that walks the whole list and
# claims nothing calls no-claim-mark and the shell waits on the signature rather than
# busy-relaunching, exactly as it does today when nothing is claimable for any other reason.

# D10 — the narrow-clone variant: a target cloned --single-branch or --depth 1 still tracks an
# origin-only branch
mkdir -p "$TD/d10-seed"; ( cd "$TD/d10-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init )
git clone -q --bare "$TD/d10-seed" "$TD/d10a-origin.git"
git clone -q --single-branch --branch main "$TD/d10a-origin.git" "$TD/d10acode"
( cd "$TD/d10acode"; git config user.email t@t.t; git config user.name test )
git clone -q --bare "$TD/d10-seed" "$TD/d10b-origin.git"
git clone -q --depth 1 "$TD/d10b-origin.git" "$TD/d10bcode"
( cd "$TD/d10bcode"; git config user.email t@t.t; git config user.name test )

for v in a b; do
  mkrepo "$TD/d10${v}plan"
  ( cd "$TD/d10${v}plan"; printf -- '- [ ] d10%s fix widget\n' "$v" > todo.md; mkdir -p tasks
    printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/d10$v.md"; git add -A; git commit -qm todo )
  bake "$TD/d10${v}code" "$TD/d10${v}plan"
  git clone -q "$TD/d10${v}-origin.git" "$TD/d10${v}prior"
  ( cd "$TD/d10${v}prior"; git config user.email o@o.o; git config user.name other
    git checkout -qb "d10${v}-fix-widget"; echo prior >> f; git commit -qam "prior work"; git push -q origin "d10${v}-fix-widget" )
done
twta=$(run_claim "$TD/d10aplan" d10a "$TD/d10a.err"); rca=$?
twtb=$(run_claim "$TD/d10bplan" d10b "$TD/d10b.err"); rcb=$?
check "D10 single-branch clone claim exit" "$rca" "0"
check "D10 single-branch worktree tip == origin's" "$([ "$(git -C "$twta" rev-parse HEAD 2>/dev/null)" = "$(git -c safe.bareRepository=all -C "$TD/d10a-origin.git" rev-parse d10a-fix-widget)" ] && echo yes || echo NO)" "yes"
check "D10 depth-1 clone claim exit" "$rcb" "0"
check "D10 depth-1 worktree tip == origin's" "$([ "$(git -C "$twtb" rev-parse HEAD 2>/dev/null)" = "$(git -c safe.bareRepository=all -C "$TD/d10b-origin.git" rev-parse d10b-fix-widget)" ] && echo yes || echo NO)" "yes"
# D10 PASS — neither a --single-branch nor a --depth 1 clone needs its own fetch refspec
# configured for the claim to work: the worktree is created from the ref the claim's own fetch
# resolved, never from the clone's own upstream-tracking config.

# D11 — the claim's refusal appears in a captured run log, not only the session's own transcript
mkorigin "$TD/d11code"; mkrepo "$TD/d11plan"
( cd "$TD/d11plan"; printf -- '- [ ] d11a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d11a.md; git add -A; git commit -qm todo )
bake "$TD/d11code" "$TD/d11plan"

twt=$(run_claim "$TD/d11plan" d11a "$TD/d11a.err")
echo local-only >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "local-only commit" >/dev/null
git -C "$TD/d11code" worktree remove --force "$twt"
git clone -q "$TD/d11code-origin.git" "$TD/d11other"
( cd "$TD/d11other"; git config user.email o@o.o; git config user.name other
  git checkout -qb d11a-fix-widget; echo other-work >> f; git commit -qam "other machine's work"; git push -q origin d11a-fix-widget )

drv="$TD/d11drv.sh"
cat > "$drv" <<'DRV'
REC="$0.rec"
printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
DRV
printf 'cd "%s"\nbash .git/zero.sh claim d11a\n' "$TD/d11plan" >> "$drv"
bash "$drv" > "$TD/run.log" 2>&1
_v="$(grep -cE 'd11a-fix-widget.*cannot fast-forward|cannot fast-forward.*d11a-fix-widget' "$TD/run.log")"
check "D11 refusal appears in the captured run log" "$([ "$_v" -ge 1 ] && echo yes || echo no)" "yes"
# D11 PASS — the refusal, naming the branch and its repair, lands in run.log — a
# kaizero … > run.log 2>&1 capture, not the session's own transcript — is where an operator
# actually sees why the task stopped being claimable.

# D12 — a task whose branch exists nowhere on origin still forks fresh off origin/<base>, as today
mkorigin "$TD/d12code"; mkrepo "$TD/d12plan"
( cd "$TD/d12plan"; printf -- '- [ ] d12a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d12a.md; git add -A; git commit -qm todo )
bake "$TD/d12code" "$TD/d12plan"
BASE_TIP=$(git -C "$TD/d12code" rev-parse main)

twt=$(run_claim "$TD/d12plan" d12a "$TD/d12a.err"); rc=$?
check "D12 claim exit" "$rc" "0"
check "D12 worktree forked off base" "$([ "$(git -C "$twt" merge-base HEAD "$BASE_TIP")" = "$BASE_TIP" ] && echo yes || echo NO)" "yes"
check "D12 branch created locally only" "$(git -C "$TD/d12code" branch --list d12a-fix-widget | wc -l | tr -d ' ')" "1"
check "D12 nothing on origin" "$(git -c safe.bareRepository=all -C "$TD/d12code-origin.git" branch --list d12a-fix-widget | wc -l | tr -d ' ')" "0"
# D12 PASS — with no candidate on origin, origin_branches_for_id returns empty and
# acquire_target's own default (fork off $TB) stands unchanged — the origin lookup this ticket
# adds overrides only the case where origin actually has the branch.

# D13 — origin no longer has the branch (deleted on merge) while a stale
# refs/remotes/origin/<branch> and unpushed local commits survive: the claim leaves it alone
mkorigin "$TD/d13code"; mkrepo "$TD/d13plan"
( cd "$TD/d13plan"; printf -- '- [ ] d13a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d13a.md; git add -A; git commit -qm todo )
bake "$TD/d13code" "$TD/d13plan"

twt=$(run_claim "$TD/d13plan" d13a "$TD/d13a.err")
echo first >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "first change" >/dev/null
git -C "$twt" push -q origin "HEAD:refs/heads/d13a-fix-widget"
git -C "$TD/d13code" fetch -q origin d13a-fix-widget   # populate the stale remote-tracking ref
echo second >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "second, unpushed change" >/dev/null   # never pushed
LOCAL_TIP=$(git -C "$twt" rev-parse HEAD)
git -c safe.bareRepository=all -C "$TD/d13code-origin.git" branch -D d13a-fix-widget   # the forge deleted it on merge
git -C "$TD/d13code" worktree remove --force "$twt"

twt2=$(run_claim "$TD/d13plan" d13a "$TD/d13.err"); rc=$?
check "D13 claim exit" "$rc" "0"
check "D13 no sync line printed" "$(grep -c 'sync' "$TD/d13.err")" "0"
check "D13 local branch tip unchanged" "$([ "$(git -C "$TD/d13code" rev-parse d13a-fix-widget)" = "$LOCAL_TIP" ] && echo yes || echo NO)" "yes"
# D13 PASS — origin_branches_for_id finds nothing on origin (the forge already deleted it), so a
# stale local refs/remotes/origin/<branch> decides nothing: the local branch, unpushed commit
# included, is left exactly where it was and the claim proceeds on it unchanged.

# D14 — a re-opened [x] task whose branch is still on origin, already merged into base, forks
# fresh instead of adopting it
mkorigin "$TD/d14code"; mkrepo "$TD/d14plan"
( cd "$TD/d14plan"; printf -- '- [ ] d14a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d14a.md; git add -A; git commit -qm todo )
bake "$TD/d14code" "$TD/d14plan"
BASE_TIP=$(git -C "$TD/d14code" rev-parse main)

# a branch on origin whose work is already an ancestor of base (contained, e.g. a fast-forward
# merge already landed) — never adopted, since it is finished work.
git clone -q "$TD/d14code-origin.git" "$TD/d14other"
( cd "$TD/d14other"; git config user.email o@o.o; git config user.name other
  git checkout -qb d14a-fix-widget; git push -q origin d14a-fix-widget:refs/heads/d14a-fix-widget )

twt=$(run_claim "$TD/d14plan" d14a "$TD/d14.err"); rc=$?
check "D14 claim exit" "$rc" "0"
check "D14 worktree HEAD is base's tip" "$([ "$(git -C "$twt" rev-parse HEAD)" = "$BASE_TIP" ] && echo yes || echo NO)" "yes"
# D14 PASS — origin has a branch under this id, but its tip is already an ancestor of $TB —
# finished work — so it is ignored and the claim forks fresh off base, exactly as an uncheck-and-
# reclaim of a [x] task does locally.

# D15 — README's clean-slate recipe (uncheck [x], delete the local branch) hands out a worktree
# at origin's base tip in MR mode
mkorigin "$TD/d15code"; mkrepo "$TD/d15plan"
( cd "$TD/d15plan"; printf -- '- [ ] d15a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d15a.md; git add -A; git commit -qm todo )
bake "$TD/d15code" "$TD/d15plan"

twt=$(run_claim "$TD/d15plan" d15a "$TD/d15a.err")
echo change >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "landed work" >/dev/null
git -C "$twt" push -q origin "HEAD:refs/heads/d15a-fix-widget"
git -C "$twt" push -q origin "HEAD:refs/heads/main"   # simulate the Hand off's merge: base itself advances too
BASE_TIP=$(git -C "$twt" rev-parse HEAD)
git -C "$TD/d15code" worktree remove --force "$twt"
git -C "$TD/d15code" branch -D d15a-fix-widget   # the clean-slate recipe's own step

twt2=$(run_claim "$TD/d15plan" d15a "$TD/d15.err"); rc=$?
check "D15 claim exit" "$rc" "0"
# origin's copy is finished work, never adopted
check "D15 worktree at base's tip" "$([ "$(git -C "$twt2" rev-parse HEAD)" = "$BASE_TIP" ] && echo yes || echo NO)" "yes"
# D15 PASS — even though origin still has the branch, its work is contained in $TB (the Hand off
# already merged it, hypothetically — same shape as D14), so deleting the local branch really
# does start over, exactly as the README promises. This also stands in for the "Reproduction
# check, repair half"'s branch -D alternative: D1 (no local branch, origin has an unmerged one)
# already proves that half — deleting the local branch and reclaiming tracks origin's tip rather
# than forking, the same outcome U-023's U45 arm C proves for the branch -f form.

# D16 — after the Todo List title of a handed-off task is edited, the next claim's worktree
# still starts at that task's branch tip on origin
mkorigin "$TD/d16code"; mkrepo "$TD/d16plan"
( cd "$TD/d16plan"; printf -- '- [ ] d16a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d16a.md; git add -A; git commit -qm todo )
bake "$TD/d16code" "$TD/d16plan"

git clone -q "$TD/d16code-origin.git" "$TD/d16prior"
( cd "$TD/d16prior"; git config user.email o@o.o; git config user.name other
  git checkout -qb d16a-fix-widget; echo prior >> f; git commit -qam "prior work"; git push -q origin d16a-fix-widget )
( cd "$TD/d16plan"; sed -i.bak 's/fix widget/rename the widget entirely/' todo.md; rm -f todo.md.bak
  git add todo.md; git commit -qm "title edit" )

twt=$(run_claim "$TD/d16plan" d16a "$TD/d16.err"); rc=$?
check "D16 claim exit" "$rc" "0"
check "D16 worktree tip == origin's (prior work carried)" "$(git -C "$twt" log --format=%s | grep -c 'prior work')" "1"
check "D16 exactly one branch for this id" "$(git -C "$TD/d16code" for-each-ref --format='%(refname:short)' 'refs/heads/d16a-*' | wc -l | tr -d ' ')" "1"
# D16 PASS — the branch is found by the id prefix rule (origin_branches_for_id), not by a slug
# re-derived from the (now different) title, so an edited title still finds the branch the fleet
# pushed instead of forking a second one beside it under the freshly re-derived slug.

# D17 — ambiguity refuses the claim, nothing created: a local id collision, and two origin
# branches tying for the same id
# D17a: local id collision — Todo carries "7 1 add cache" and "7-1 add cache"; claiming "7" must
# refuse (target_branches_for_id's own longest-id-wins tie-break, unaffected by this ticket).
mkorigin "$TD/d17acode"; mkrepo "$TD/d17aplan"
( cd "$TD/d17aplan"; printf -- '- [ ] 7 1 add cache\n- [ ] 7-1 add cache\n' > todo.md; mkdir -p tasks
  printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/7.md; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/7-1.md
  git add -A; git commit -qm todo )
bake "$TD/d17acode" "$TD/d17aplan"
( cd "$TD/d17acode"; git branch 7-1-add-cache main )   # a pre-existing branch already claimed by the longer id
CACHE_TIP=$(git -C "$TD/d17acode" rev-parse 7-1-add-cache)

out=$(run_claim "$TD/d17aplan" 7 "$TD/d17a.err"); rc=$?
check "D17a claim of '7' refused" "$([ "$rc" -ne 0 ] && echo yes || echo NO)" "yes"
check "D17a nothing created for '7'" "$(git -C "$TD/d17acode" branch --list '7-add-cache' | wc -l | tr -d ' ')" "0"
check "D17a 7-1's branch untouched" "$([ "$(git -C "$TD/d17acode" rev-parse 7-1-add-cache)" = "$CACHE_TIP" ] && echo yes || echo NO)" "yes"

# D17b: origin-side ambiguity — two branches on origin both matching the same id prefix after
# the tie-break, neither claimed by a longer id.
mkorigin "$TD/d17bcode"; mkrepo "$TD/d17bplan"
( cd "$TD/d17bplan"; printf -- '- [ ] d17b fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d17b.md; git add -A; git commit -qm todo )
bake "$TD/d17bcode" "$TD/d17bplan"
git clone -q "$TD/d17bcode-origin.git" "$TD/d17bother"
( cd "$TD/d17bother"; git config user.email o@o.o; git config user.name other
  git checkout -qb d17b-fix-widget-alpha; git commit -q --allow-empty -m alpha; git push -q origin d17b-fix-widget-alpha
  git checkout -qb d17b-fix-widget-beta main; git commit -q --allow-empty -m beta; git push -q origin d17b-fix-widget-beta )

out2=$(run_claim "$TD/d17bplan" d17b "$TD/d17b.err"); rc2=$?
check "D17b origin-ambiguous claim refused" "$([ "$rc2" -ne 0 ] && echo yes || echo NO)" "yes"
alpha_c="$(grep -c 'd17b-fix-widget-alpha' "$TD/d17b.err")"; beta_c="$(grep -c 'd17b-fix-widget-beta' "$TD/d17b.err")"
check "D17b message names alpha candidate" "$([ "$alpha_c" -ge 1 ] && echo yes || echo no)" "yes"
check "D17b message names beta candidate" "$([ "$beta_c" -ge 1 ] && echo yes || echo no)" "yes"
check "D17b nothing created" "$(git -C "$TD/d17bcode" branch --list 'd17b-fix-widget' | wc -l | tr -d ' ')" "0"
# D17 PASS — a local naming collision (pre-existing target_branches_for_id behaviour, unaffected
# by this ticket) and an origin-side tie (this ticket's own origin_branches_for_id ambiguity
# guard) both refuse the claim outright, naming the candidates, creating nothing.

# D18 — origin reachable but the base itself renamed away: reported as a missing base, never as
# an unreachable origin
mkorigin "$TD/d18code"; mkrepo "$TD/d18plan"
( cd "$TD/d18plan"; printf -- '- [ ] d18a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d18a.md; git add -A; git commit -qm todo )
bake "$TD/d18code" "$TD/d18plan"
git -c safe.bareRepository=all -C "$TD/d18code-origin.git" branch -m main trunk   # the base is gone from origin

out=$(run_claim "$TD/d18plan" d18a "$TD/d18.err"); rc=$?
check "D18 claim exit" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "D18 message names the missing base" "$(grep -c "'main' is not on origin" "$TD/d18.err")" "1"
check "D18 message is not origin-unreachable" "$(grep -c 'origin unreachable' "$TD/d18.err")" "0"
# D18 PASS — network_reachable's own exit code (2 = base absent, distinguished from a network
# cause) drives the doctor's own "base is not on origin" wording, never the generic unreachable
# message — a permanently missing base and an outage are told apart by exit status, never by
# matching git's prose.

# D19 — the reproduction, variant and no-origin-branch outcomes are identical under a non-C and
# the C locale
for loc in de_DE.UTF-8 C; do
  mkorigin "$TD/d19-${loc}code"; mkrepo "$TD/d19-${loc}plan"
  ( cd "$TD/d19-${loc}plan"; printf -- '- [ ] d19%s fix widget\n' "$loc" > todo.md; mkdir -p tasks
    printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/d19$loc.md"; git add -A; git commit -qm todo )
  bake "$TD/d19-${loc}code" "$TD/d19-${loc}plan"
  git clone -q "$TD/d19-${loc}code-origin.git" "$TD/d19-${loc}other"
  ( cd "$TD/d19-${loc}other"; git config user.email o@o.o; git config user.name other
    git checkout -qb "d19${loc}-fix-widget"; echo other >> f; git commit -qam other; git push -q origin "d19${loc}-fix-widget" )
  out=$(LC_ALL="$loc" run_claim "$TD/d19-${loc}plan" "d19$loc" "$TD/d19-$loc.err"); rc=$?
  # tracks origin
  check "D19 [$loc] claim exit" "$rc" "0"
done
# D19 PASS — the outcome (tracking origin's tip, exit 0) is identical under LC_ALL=de_DE.UTF-8
# and LC_ALL=C: no decision on this path reads git's own (locale-dependent) prose, per the
# already-ticked absence check.

# D20 — three concurrent claims on three tasks in one target all succeed while origin advances
mkorigin "$TD/d20code"; mkrepo "$TD/d20plan"
( cd "$TD/d20plan"; printf -- '- [ ] d20a t\n- [ ] d20b t\n- [ ] d20c t\n' > todo.md; mkdir -p tasks
  for t in d20a d20b d20c; do printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/$t.md"; done
  git add -A; git commit -qm todo )
bake "$TD/d20code" "$TD/d20plan"
git clone -q "$TD/d20code-origin.git" "$TD/d20advance"
( cd "$TD/d20advance"; git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m "base advances"; git push -q origin main )

fails=0
for id in d20a d20b d20c; do
  run_claim "$TD/d20plan" "$id" "$TD/d20-$id.err" > "$TD/d20-$id.out" &
done
wait
for id in d20a d20b d20c; do
  grep -q 'unreachable' "$TD/d20-$id.err" 2>/dev/null && fails=$((fails+1))
  [ -s "$TD/d20-$id.out" ] || fails=$((fails+1))
done
check "D20 all three concurrent claims succeeded, none reported unreachable" "$fails" "0"
# D20 PASS — three peers claiming three different tasks in the same target concurrently all
# succeed with no round reporting origin unreachable; a peer's own concurrent refresh of
# refs/remotes/origin/<base> is never mistaken for an outage.

# D21 — a hung branch lookup for one task never blocks a concurrent claim of a different task,
# and returns not-claimed at once for the same task
mkorigin "$TD/d21code"; mkrepo "$TD/d21plan"
( cd "$TD/d21plan"; printf -- '- [ ] d21a t\n- [ ] d21b t\n' > todo.md; mkdir -p tasks
  printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d21a.md; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d21b.md
  git add -A; git commit -qm todo )
bake "$TD/d21code" "$TD/d21plan"

REALGIT="$(type -P git)"
mkdir -p "$TD/d21bin"
cat > "$TD/d21bin/git" <<EOF
#!/usr/bin/env bash
case " \$* " in *"ls-remote --heads origin"*)
  if [ -f "$TD/d21-hang" ]; then sleep 5; fi ;;
esac
exec "$REALGIT" "\$@"
EOF
chmod +x "$TD/d21bin/git"
touch "$TD/d21-hang"

drv_a="$TD/d21drv-a.sh"
cat > "$drv_a" <<'DRV'
REC="$0.rec"
printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
DRV
printf 'export PATH="%s:$PATH"\ncd "%s"\nbash .git/zero.sh claim d21a\n' "$TD/d21bin" "$TD/d21plan" >> "$drv_a"
bash "$drv_a" > "$TD/d21a.out" 2> "$TD/d21a.err" &
D21A_PID=$!
sleep 1   # let d21a's lookup enter its hang

START=$(date +%s)
twtb=$(run_claim "$TD/d21plan" d21b "$TD/d21b.err"); rcb=$?
ELAPSED=$(( $(date +%s) - START ))
check "D21 concurrent DIFFERENT task claims fine" "$rcb" "0"
# want yes, <4s
check "D21 concurrent DIFFERENT task did not wait" "$([ "$ELAPSED" -lt 4 ] && echo yes || echo NO)" "yes"

# same-task concurrent claim, while d21a is still hung inside its own reclaim lock
outc=$(run_claim "$TD/d21plan" d21a "$TD/d21c.err"); rcc=$?
check "D21 concurrent SAME task returns not-claimed at once" "$([ "$rcc" -ne 0 ] && echo yes || echo NO)" "yes"
rm -f "$TD/d21-hang"
wait "$D21A_PID"
# D21 PASS — the origin-branch lookup runs under the per-task reclaim lock and nothing wider: a
# task hung inside it costs only itself — a different task's claim proceeds immediately, and a
# second claim of the same task fails fast on the reclaim lock's own -n (non-blocking) flag,
# never waiting on the hung lookup either.

# D22 — once an outage clears, the next claim succeeds instead of continuing to refuse
mkorigin "$TD/d22code"; mkrepo "$TD/d22plan"
( cd "$TD/d22plan"; printf -- '- [ ] d22a t\n- [ ] d22b t\n- [ ] d22c t\n' > todo.md; mkdir -p tasks
  for t in d22a d22b d22c; do printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/$t.md"; done
  git add -A; git commit -qm todo )
bake "$TD/d22code" "$TD/d22plan"
REAL_URL=$(git -C "$TD/d22code" remote get-url origin)
# the git remote itself is what origin_branches_for_id/network_reachable read (-C "$TARGET_ROOT"
# ls-remote/fetch of "origin") — ORIGIN_URL inside the emitted zero.sh is a forge-call detail
# (mr-body-path/pr-create), never consulted by either lookup, so patching it alone leaves the
# real fetch/ls-remote untouched and the outage never happens; D4/D6 use this same
# `remote set-url` approach for exactly that reason.
git -C "$TD/d22code" remote set-url origin "$TD/d22code-origin.git.unreachable"

out1=$(run_claim "$TD/d22plan" d22a "$TD/d22-during.err"); rc1=$?
check "D22 during outage: claim refused" "$([ "$rc1" -ne 0 ] && echo yes || echo NO)" "yes"

git -C "$TD/d22code" remote set-url origin "$REAL_URL"   # outage clears
out2=$(run_claim "$TD/d22plan" d22a "$TD/d22-after.err"); rc2=$?
check "D22 after recovery: claim succeeds" "$rc2" "0"
# D22 PASS — once origin answers again, the very next claim on the same unchecked task succeeds
# — the refusal was never a permanent mark on the task, only a reflection of the outage that
# caused it; a fleet run backed by the same claim primitive resumes on its own next pass, never
# stuck parked once the outage it was parked on has cleared.

# D23 — a refused claim is the only unchecked task left: the run falls into its ordinary
# no-claim wait, never re-claims in a tight loop and never exits as though the list were done
# Unlike D1-D22, this drives the real fleet loop (bash "$SCRIPT", no KAIZERO_TEST_EMIT) with
# a real claude stub that itself issues the claim, since "the run's ordinary no-claim handling"
# is kaizero.sh's own run_loop/wait_for_dependency_clear, unreachable through run_claim's
# disposable per-call driver.
mkorigin "$TD/d23code"; mkrepo "$TD/d23plan"
( cd "$TD/d23plan"; printf -- '- [ ] d23a fix widget\n' > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/d23a.md; git add -A; git commit -qm todo )
bake "$TD/d23code" "$TD/d23plan"

# make the branch diverge, exactly as D2 does, so every claim on it refuses with 8
twt=$(run_claim "$TD/d23plan" d23a "$TD/d23a.err")
echo local-only >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "local-only commit" >/dev/null
git -C "$TD/d23code" worktree remove --force "$twt"
git clone -q "$TD/d23code-origin.git" "$TD/d23other"
( cd "$TD/d23other"; git config user.email o@o.o; git config user.name other
  git checkout -qb d23a-fix-widget; echo other-work >> f; git commit -qam "other machine's work"; git push -q origin d23a-fix-widget )

# a fuller gh stub, answering --help too: unlike every earlier case's zero.sh claim (never
# reaching the doctor), this drives the real fleet loop, whose startup runs the full run_doctor
# mr (MR mode is the launch default here) including check 5's flag-surface probe — a bare
# auth status-only stub the file's earlier cases left behind fails that probe and refuses the
# launch before a single session runs.
cat > "$TD/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
is_help=0
for a in "$@"; do [ "$a" = --help ] && is_help=1; done
if [ "$1 ${2:-}" = "pr list" ] && [ "${3:-}" = "--json" ] && [ $# -eq 3 ]; then
  printf '%s\n' 'number headRefOid baseRefName state url' >&2
  exit 1
fi
case "$1 ${2:-}" in
  "auth status") [ "$is_help" = 1 ] && { printf '%s\n' --hostname; exit 0; }; exit 0 ;;
  "pr list") [ "$is_help" = 1 ] && { printf '%s\n' --repo --head --state --limit --json; exit 0; }; exit 0 ;;
  "pr create") [ "$is_help" = 1 ] && { printf '%s\n' --repo --head --base --title --body-file; exit 0; }; exit 0 ;;
esac
exit 0
GHSTUB
chmod +x "$TD/bin/gh"

cat > "$TD/bin/claude" <<'EOF'
#!/usr/bin/env bash
# run_doctor's own preflight (kaizero.sh: command -v claude / claude -v) must not count as a
# session launch — it runs once per kaizero.sh invocation, before the loop below ever starts.
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$D23_LAUNCHED"
date +%s >> "$D23_TIMES"
cd "$D23_CODE"
bash .git/zero.sh claim d23a >/dev/null 2>"$D23_LAST_ERR" || bash .git/zero.sh no-claim-mark
exit 0
EOF
chmod +x "$TD/bin/claude"
: > "$TD/d23-launched"; : > "$TD/d23-times"

( cd "$TD/d23code"
  PATH="$TD/bin:$PATH" D23_LAUNCHED="$TD/d23-launched" D23_TIMES="$TD/d23-times" \
    D23_CODE="$TD/d23plan" D23_LAST_ERR="$TD/d23-last.err" \
    KAIZERO_MAX_LOOPS=2 KAIZERO_DEPENDENCY_WAIT=6s \
    timeout 40 bash "$SCRIPT" "$TD/d23plan/todo.md" > "$TD/d23-run.log" 2>&1 )
rc=$?
check "D23 run exit" "$rc" "0"
# a second pass with the same, still-only, refused task still runs a session, no tight loop and
# no premature stop
check "D23 sessions launched" "$(wc -l < "$TD/d23-launched" | tr -d ' ')" "2"
t1=$(sed -n '1p' "$TD/d23-times"); t2=$(sed -n '2p' "$TD/d23-times")
# the dependency-wait ceiling, not an instant relaunch
check "D23 real wait between passes" "$([ -n "$t1" ] && [ -n "$t2" ] && [ $((t2 - t1)) -ge 5 ] && echo yes || echo NO)" "yes"
_v="$(grep -c 'now blocked' "$TD/d23-run.log")"; check "D23 ordinary no-claim wait line" "$([ "$_v" -ge 1 ] && echo yes || echo no)" "yes"
check "D23 last claim still refused (8)" "$(grep -c 'cannot fast-forward' "$TD/d23-last.err")" "1"
# never marked done, list never read as finished
check "D23 box still unchecked" "$(grep -c '\- \[ \] d23a' "$TD/d23plan/todo.md")" "1"
# D23 PASS — the exit-8 refusal is invisible to held_todos/no_claim_signature (see D9's own
# structural note), so a claude session that walks the list, gets refused and calls
# no-claim-mark before ending its turn drives the shell into the exact same
# wait_for_dependency_clear park any other no-claim reason uses: the second pass waits out
# KAIZERO_DEPENDENCY_WAIT (>=5s between launches, not an instant relaunch), prints its "now
# blocked" line, still relaunches a session rather than treating "nothing claimable this pass"
# as "the list is done", and the box is exactly where the refusal left it throughout.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
