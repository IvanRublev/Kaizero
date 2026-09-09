#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=235s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# W-001-mr-half-application-guards — MR mode's half-application guards. Two launch-time
# refusals: a target already driven by a live fleet member in one mode refuses a launch in the other
# (MR mode vs `--local-merge`), in both directions, while the same mode passes, a dead or
# old-format peer marker refuses nothing, and an unwritable target git dir only degrades the check;
# and a todo carrying an open `[↑]` box refuses a `--local-merge` launch naming both remedies, while
# a default (MR-mode) launch is unaffected — in every origin configuration, including one where
# dropping the flag is itself refused.
# Needs real claude: no — every launch runs under `KAIZERO_TEST_EMIT=1`, which skips `run_doctor`
#   entirely (the only place `command -v claude` is checked), so `claude` need not be on PATH at all
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/W-001-mr-half-application-guards
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 35s
#   (W3's race backgrounds two launches)
#
# Both refusals fire at launch, before any claude would start (`KAIZERO_TEST_EMIT=1`), same
# trick as `T-017-coordination-side-banner-and-refusals`. W1 reuses T14's fake-live-peer trick
# (`T-004-cross-fleet-exclusion`) against `register_on_target`'s own registry — extended to carry a
# fourth line, `MR_MODE` — to prove same-fleet launches now also agree on mode, in both directions,
# that a dead or older-format peer marker refuses nothing, and that an unwritable target git dir
# only degrades the check; W2 exercises the new `open_requests()` guard directly, across every
# origin configuration; W3 proves the mode comparison is atomic under two simultaneous launches and
# that a refusal leaves nothing behind; W4 is a static grep proving neither refusal ever names the
# old, now-removed flag.

# --- Setup ---
TW="$TESTROOT/W-001-mr-half-application-guards"
# a github `origin` on every fixture target, so a launch with no flag is MR mode; the
# --local-merge helpers below are the other side of the same pair.
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git remote add origin "https://github.com/acme/$(basename "$1").git" ); }
# no `origin` at all — MR mode is refused outright for this target; --local-merge is the only
# mode that ever reaches a launch here.
mkrepo_noorigin(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
# an origin on a host neither forge resolver knows — MR mode is refused outright for this target too.
mkrepo_unsupported(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git remote add origin "https://example.com/acme/$(basename "$1").git" ); }
mktodo(){ ( cd "$1"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }
mktodo_open(){ ( cd "$1"; printf -- '- [\xe2\x86\x91] G1 under review\n' > todo.md; git add todo.md; git commit -qm todo ); }
mktodo_outcomes(){ ( cd "$1"; printf -- '- [x] G1 landed\n- [\xe2\x9b\x94] G2 declined\n- [?] G3 unresolved\n' > todo.md; git add todo.md; git commit -qm todo ); }
emit(){ ( cd "$1"; rc=0; out=$(KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }
refuse(){ ( cd "$1"; rc=0; out=$(KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }
emit_mr(){ ( cd "$1"; rc=0; out=$(KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$2" 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }
refuse_mr(){ ( cd "$1"; rc=0; out=$(KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$2" 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }
# a launch that reached the KAIZERO_TEST_EMIT exit (both registries passed) names its OWN
# coordination git dir on that line — the one line a refused launch never reaches.
proceeded(){ echo "$1" | grep -qF "wrote generated scripts to $2/.git, exiting." && echo "$1" | grep -qx 'RC=0'; }

# W1 — one fleet, one mode, in both directions; a dead or older-format peer marker refuses nothing
mkrepo "$TW/w1code"; mkrepo "$TW/w1plan"; mktodo "$TW/w1plan"
W1CODE="$(cd "$TW/w1code" && pwd -P)"; W1PLAN="$(cd "$TW/w1plan" && pwd -P)"

# fake a live peer instance driving w1code from w1plan, in MR mode (line4=1)
( sleep 30 ) & peer=$!; sleep 0.3; st="$(ps -o lstart= -p "$peer" | awk '{$1=$1;print}')"
mkdir -p "$W1CODE/.git/kaizero-instance"
printf '%s\n%s\n%s\n%s\n' "$peer" "$st" "$W1PLAN@main" "1" > "$W1CODE/.git/kaizero-instance/peer"

out=$(refuse "$TW/w1code" "$TW/w1plan/todo.md")
check "W1 --local-merge refused by an MR-mode peer" "$(echo "$out" | grep -c "already driven in MR mode by instance peer")" "1"
check "W1 says one fleet one mode" "$(echo "$out" | grep -c 'one fleet, one mode')" "1"
# asserted RC=1, not merely captured
check "W1 refusal exit status" "$(echo "$out" | grep -cx 'RC=1')" "1"

out=$(emit_mr "$TW/w1code" "$TW/w1plan/todo.md")
check "W1 same mode (default) passes" "$(echo "$out" | grep -c 'Todo .*w1plan@main \. Target .*w1code@main')" "1"

# and the other direction: a local-merge peer (line4=0) refuses a default (MR-mode) launch
printf '%s\n%s\n%s\n%s\n' "$peer" "$st" "$W1PLAN@main" "0" > "$W1CODE/.git/kaizero-instance/peer"
out=$(refuse_mr "$TW/w1code" "$TW/w1plan/todo.md")
check "W1 default refused by a local-merge peer" "$(echo "$out" | grep -c "already driven in local-merge mode by instance peer")" "1"
check "W1 reverse refusal exit status" "$(echo "$out" | grep -cx 'RC=1')" "1"
out=$(emit "$TW/w1code" "$TW/w1plan/todo.md")
check "W1 same mode (--local-merge) passes" "$(echo "$out" | grep -c 'Todo .*w1plan@main \. Target .*w1code@main')" "1"

kill "$peer" 2>/dev/null; wait "$peer" 2>/dev/null

# a DEAD peer marker (mode mismatch, but pid no longer alive) is reaped, not obeyed
printf '%s\n%s\n%s\n%s\n' "$peer" "$st" "$W1PLAN@main" "1" > "$W1CODE/.git/kaizero-instance/peer"
out=$(refuse "$TW/w1code" "$TW/w1plan/todo.md")
check "W1 dead mode-mismatched peer reaped, launch proceeds" "$(proceeded "$out" "$W1PLAN" && echo yes || echo NO)" "yes"
check "W1 dead peer marker gone" "$([ -e "$W1CODE/.git/kaizero-instance/peer" ] && echo NO || echo yes)" "yes"

# a LIVE peer whose marker has only the three lines an older kaizero wrote — no
# mode line at all — is "unknown", not a mismatch, and refuses nothing regardless of this launch's mode
( sleep 30 ) & peer2=$!; sleep 0.3; st2="$(ps -o lstart= -p "$peer2" | awk '{$1=$1;print}')"
printf '%s\n%s\n%s\n' "$peer2" "$st2" "$W1PLAN@main" > "$W1CODE/.git/kaizero-instance/peer2"
out=$(refuse "$TW/w1code" "$TW/w1plan/todo.md")
check "W1 older-format (no line4) live peer refuses nothing" "$(proceeded "$out" "$W1PLAN" && echo yes || echo NO)" "yes"
out=$(refuse_mr "$TW/w1code" "$TW/w1plan/todo.md")
check "W1 older-format peer, MR-mode launch also unrefused" "$(proceeded "$out" "$W1PLAN" && echo yes || echo NO)" "yes"
kill "$peer2" 2>/dev/null; wait "$peer2" 2>/dev/null
rm -f "$W1CODE/.git/kaizero-instance/peer2"
# W1 PASS — a live peer's marker refuses a launch in the other mode against the same target in
# both directions, naming both sides as modes rather than a flag and its absence, with the exit
# status asserted as 1; each mode relaunched to match its peer passes; a dead mode-mismatched
# peer's marker is reaped rather than obeyed; a live peer marker with no mode line (an older
# kaizero) refuses nothing in either mode.

# W1b — an unwritable target git dir degrades the mode check, never the launch
mkrepo "$TW/w1bcode"; mkrepo "$TW/w1bplan"; mktodo "$TW/w1bplan"
W1BPLAN="$(cd "$TW/w1bplan" && pwd -P)"
chmod 555 "$TW/w1bcode/.git"
out=$(emit "$TW/w1bcode" "$TW/w1bplan/todo.md")
check "W1b launch still proceeds" "$(proceeded "$out" "$W1BPLAN" && echo yes || echo NO)" "yes"
check "W1b degrade reported once" "$(echo "$out" | grep -c 'registry degraded, running unlocked')" "1"
chmod 755 "$TW/w1bcode/.git"
# W1b PASS — an unwritable target git dir degrades the mode check exactly once and the launch
# still proceeds.

# W2 — an open `[↑]` box refuses a `--local-merge` launch naming both remedies; the default
# launch, a cleared todo and an outcomes-only todo are unaffected
mkrepo "$TW/w2code"; mkrepo "$TW/w2plan"; mktodo_open "$TW/w2plan"

out=$(refuse "$TW/w2code" "$TW/w2plan/todo.md")
check "W2 --local-merge refused" "$(echo "$out" | grep -c "has 1 task(s) marked '\[↑\]'")" "1"
check "W2 remedy: drop the flag" "$(echo "$out" | grep -c 'drop --local-merge to keep driving them')" "1"
check "W2 remedy: clear boxes by hand" "$(echo "$out" | grep -c 'or clear those boxes by hand')" "1"
check "W2 refusal exit status" "$(echo "$out" | grep -cx 'RC=1')" "1"

out=$(emit_mr "$TW/w2code" "$TW/w2plan/todo.md")
check "W2 default launch unaffected" "$(echo "$out" | grep -c 'Todo .*w2plan@main \. Target .*w2code@main')" "1"

# clearing the box lets the identical --local-merge launch through
mktodo "$TW/w2plan"
out=$(emit "$TW/w2code" "$TW/w2plan/todo.md")
check "W2 passes once the box is cleared" "$(echo "$out" | grep -c 'Todo .*w2plan@main \. Target .*w2code@main')" "1"

# a todo holding only [x]/[⛔]/[?] never refuses — those are outcomes, not open handoffs
mktodo_outcomes "$TW/w2plan"
out=$(emit "$TW/w2code" "$TW/w2plan/todo.md")
check "W2 outcomes-only todo never refuses" "$(echo "$out" | grep -c 'Todo .*w2plan@main \. Target .*w2code@main')" "1"
# W2 PASS — a todo with one `[↑]` box refuses a `--local-merge` launch with exit status 1,
# naming the count and both remedies; the identical todo launched by default is not refused by
# this guard; clearing the box lets the identical `--local-merge` launch through; a todo holding
# only `[x]`/`[⛔]`/`[?]` never refuses.

# W2b — the by-hand remedy is named even where dropping `--local-merge` is itself refused
# a target whose origin is on an unsupported forge host
mkrepo_unsupported "$TW/w2buns"; mkrepo "$TW/w2bplanuns"; mktodo_open "$TW/w2bplanuns"
out=$(refuse "$TW/w2buns" "$TW/w2bplanuns/todo.md")
check "W2b unsupported-host target names by-hand remedy" "$(echo "$out" | grep -c 'or clear those boxes by hand')" "1"

# a target with no origin at all
mkrepo_noorigin "$TW/w2bnoorigin"; mkrepo "$TW/w2bplannoorigin"; mktodo_open "$TW/w2bplannoorigin"
out=$(refuse "$TW/w2bnoorigin" "$TW/w2bplannoorigin/todo.md")
check "W2b no-origin target names by-hand remedy" "$(echo "$out" | grep -c 'or clear those boxes by hand')" "1"

# a same-repository layout (todo lives inside the target itself)
mkrepo "$TW/w2bsame"; mktodo_open "$TW/w2bsame"
out=$(refuse "$TW/w2bsame" "$TW/w2bsame/todo.md")
check "W2b same-repo target names by-hand remedy" "$(echo "$out" | grep -c 'or clear those boxes by hand')" "1"
# W2b PASS — the by-hand remedy is named on a target whose origin is on an unsupported forge
# host, on a target with no origin, and on a same-repository layout — configurations where
# dropping `--local-merge` is itself refused.

# W3 — the mode refusal fires before anything shared is written or created, and is atomic under
# two simultaneous opposite-mode launches
mkrepo "$TW/w3code"; mkrepo "$TW/w3plana"; mktodo "$TW/w3plana"
W3CODE="$(cd "$TW/w3code" && pwd -P)"; W3PLANA="$(cd "$TW/w3plana" && pwd -P)"

# the peer names THIS launch's own coordination point (w3plana) — the only case in which the
# mode-mismatch arm fires at all, and the one where the shared .git/zero.sh a peer might still be
# reading has to be proven untouched.
( sleep 30 ) & peer=$!; sleep 0.3; st="$(ps -o lstart= -p "$peer" | awk '{$1=$1;print}')"
mkdir -p "$W3CODE/.git/kaizero-instance"
printf '%s\n%s\n%s\n%s\n' "$peer" "$st" "$W3PLANA@main" "1" > "$W3CODE/.git/kaizero-instance/peer"

[ -e "$W3PLANA/.git/zero.sh" ] && cp "$W3PLANA/.git/zero.sh" "$TW/zero-before-b.sh" || rm -f "$TW/zero-before-b.sh"
[ -e "$W3CODE/.git/zero.sh" ] && cp "$W3CODE/.git/zero.sh" "$TW/zero-before-a.sh" || rm -f "$TW/zero-before-a.sh"

out=$(refuse "$W3CODE" "$W3PLANA/todo.md")
check "W3 refused" "$(echo "$out" | grep -c 'already driven in MR mode by instance peer')" "1"
if [ -e "$TW/zero-before-b.sh" ]; then
  check "W3 coord zero.sh unchanged" "$([ -e "$W3PLANA/.git/zero.sh" ] && cmp -s "$TW/zero-before-b.sh" "$W3PLANA/.git/zero.sh" && echo yes || echo NO)" "yes"
else
  check "W3 coord zero.sh still absent" "$([ -e "$W3PLANA/.git/zero.sh" ] && echo NO || echo yes)" "yes"
fi
if [ -e "$TW/zero-before-a.sh" ]; then
  check "W3 target zero.sh unchanged" "$([ -e "$W3CODE/.git/zero.sh" ] && cmp -s "$TW/zero-before-a.sh" "$W3CODE/.git/zero.sh" && echo yes || echo NO)" "yes"
else
  check "W3 target zero.sh still absent" "$([ -e "$W3CODE/.git/zero.sh" ] && echo NO || echo yes)" "yes"
fi
check "W3 refused instance's coord marker absent" "$(find "$W3PLANA/.git/instance" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
check "W3 refused instance's target marker absent" "$(find "$W3CODE/.git/kaizero-instance" -type f ! -name peer 2>/dev/null | wc -l | tr -d ' ')" "0"
# only the main checkout
check "W3 no new worktree left behind" "$(git -C "$W3CODE" worktree list | wc -l | tr -d ' ')" "1"
check "W3 peer's own registry entry untouched" "$(cmp -s <(printf '%s\n%s\n%s\n%s\n' "$peer" "$st" "$W3PLANA@main" "1") "$W3CODE/.git/kaizero-instance/peer" && echo yes || echo NO)" "yes"

# two launches at once, from the SAME coordination point (so the cross-fleet guard passes both
# through) but opposite modes, against a target with no live peer yet: exactly one survives
mkrepo "$TW/w3rcode"; mkrepo "$TW/w3rplan"; mktodo "$TW/w3rplan"
W3RPLAN="$(cd "$TW/w3rplan" && pwd -P)"
( cd "$TW/w3rcode"; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$W3RPLAN/todo.md" ) > "$TW/race-a.out" 2>&1 &
racea=$!
( cd "$TW/w3rcode"; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$W3RPLAN/todo.md" ) > "$TW/race-b.out" 2>&1 &
raceb=$!
wait "$racea"; rca=$?
wait "$raceb"; rcb=$?
survivors=0; refusals=0
[ "$rca" = 0 ] && survivors=$((survivors+1))
[ "$rcb" = 0 ] && survivors=$((survivors+1))
grep -q 'one fleet, one mode' "$TW/race-a.out" && refusals=$((refusals+1))
grep -q 'one fleet, one mode' "$TW/race-b.out" && refusals=$((refusals+1))
check "W3 race: exactly one survivor" "$survivors" "1"
check "W3 race: exactly one refusal" "$refusals" "1"

kill "$peer" 2>/dev/null; wait "$peer" 2>/dev/null
# W3 PASS — a refused mode-mismatch launch leaves both repositories' `.git/zero.sh` untouched,
# leaves no marker or worktree behind for the refused instance, and leaves the peer's own registry
# entry byte-for-byte untouched; of two launches fired simultaneously in opposite modes against an
# unclaimed target, exactly one proceeds and exactly one is refused.

# W4 — neither refusal names the old, now-removed flag
oldflag='--'"mr"
check "W4 no old flag anywhere in kaizero.sh" "$(grep -F -c -- "$oldflag" "$SCRIPT")" "0"
# W4 PASS — `kaizero.sh` names the old, now-removed flag nowhere.

# W5 — the dispatch closes each mode's door against the other: `merge` under MR mode, and `mr`
# under `--local-merge`, both refuse before touching anything. Local mkrepo5/mktodo5 (not
# mkrepo/mktodo — this section's fixtures take a task id, the scenario-wide helpers don't).
mkrepo5(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktodo5(){ ( cd "$1"; printf -- '- [ ] %s task\n' "$2" > todo.md; mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/$2.md"; git add -A; git commit -qm todo ); }
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1"; git config user.email t@t.t; git config user.name test )
}
mkdir -p "$TW/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TW/bin/gh"; chmod +x "$TW/bin/gh"

# w5a: MR_MODE=1 — a launch in MR mode, then `merge` refuses.
mkorigin "$TW/w5acode"; mkrepo5 "$TW/w5aplan"; mktodo5 "$TW/w5aplan" W5a
( cd "$TW/w5acode"; PATH="$TW/bin:$PATH" KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$TW/w5aplan/todo.md" >/dev/null 2>&1 )
zsh="$TW/w5aplan/.git/zero.sh"; sed -i.bak "s#^ORIGIN_URL=.*#ORIGIN_URL=$(printf '%q' "$TW/w5acode-origin.git")#" "$zsh"; rm -f "$zsh.bak"
W5A_BASE_PRE=$(git -C "$TW/w5acode" rev-parse main)
cat > "$TW/w5adrive.sh" <<DRIVE
set -uo pipefail
export PATH="$TW/bin:\$PATH"
REC="$TW/w5a.rec"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
cd "$TW/w5aplan"
FAILED=0; ERRORED=0
t=\$(bash .git/zero.sh claim W5a)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
out=\$(bash .git/zero.sh merge W5a "\$t" 2>&1); rc=\$?
check "W5a merge-under-mr exit" "\$rc" "5"
check "W5a says run MR mode" "\$(printf '%s' "\$out" | grep -c "this fleet runs MR mode; land with 'zero.sh mr' instead")" "1"
check "W5a box unchanged" "\$(grep -c '\[ \] W5a' todo.md)" "1"
check "W5a worktree kept" "\$([ -d "\$t" ] && echo yes || echo NO)" "yes"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TW="$TW" bash "$TW/w5adrive.sh" || FAILED=1
# no merge happened
check "W5a target base unchanged" "$(git -C "$TW/w5acode" rev-parse main)" "$W5A_BASE_PRE"
check "W5a no branch on origin" "$(git -c safe.bareRepository=all -C "$TW/w5acode-origin.git" branch --list 'main-task-W5a*' | wc -l | tr -d ' ')" "0"

# w5b: MR_MODE=0 (--local-merge) — a plain launch, then `mr` refuses.
mkrepo5 "$TW/w5bcode"; mkrepo5 "$TW/w5bplan"; mktodo5 "$TW/w5bplan" W5b
( cd "$TW/w5bcode"; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$TW/w5bplan/todo.md" >/dev/null 2>&1 )
W5B_BASE_PRE=$(git -C "$TW/w5bcode" rev-parse main)
cat > "$TW/w5bdrive.sh" <<DRIVE
set -uo pipefail
export PATH="$TW/bin:\$PATH"
REC="$TW/w5b.rec"; printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ 2>/dev/null | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
cd "$TW/w5bplan"
FAILED=0; ERRORED=0
t=\$(bash .git/zero.sh claim W5b)
echo work > "\$t/f"; git -C "\$t" add -A; git -C "\$t" commit -qm work
out=\$(bash .git/zero.sh mr W5b "\$t" 2>&1); rc=\$?
check "W5b mr-without-mr exit" "\$rc" "5"
check "W5b says use merge" "\$(printf '%s' "\$out" | grep -c "this fleet does not run MR mode; land with 'zero.sh merge' instead")" "1"
check "W5b box unchanged" "\$(grep -c '\[ \] W5b' todo.md)" "1"
check "W5b worktree kept" "\$([ -d "\$t" ] && echo yes || echo NO)" "yes"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TW="$TW" bash "$TW/w5bdrive.sh" || FAILED=1
# no merge happened
check "W5b target base rev unchanged" "$(git -C "$TW/w5bcode" rev-parse main)" "$W5B_BASE_PRE"
# W5 PASS — under `MR_MODE=1`, `merge` refuses with exit 5 naming `zero.sh mr` as the way to
# land, never reaching `merge_task`: the box stays `[ ]`, the worktree survives, and no branch
# reaches origin. Under `MR_MODE=0`, `mr` refuses the same way naming `zero.sh merge`, never
# reaching `mr_task`. Neither mode can be entered halfway through a landing.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
