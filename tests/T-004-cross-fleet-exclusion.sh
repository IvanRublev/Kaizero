#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=110s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-004-cross-fleet-exclusion — a target already driven from another coordination point, and the
# reverse.
# Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor tests
# `command -v claude` before any startup guard runs)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T-004-cross-fleet-exclusion
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# The mutual exclusion, from both ends: a target already driven by a live fleet refuses a
# second coordination point, one coordination point refuses driving a second target while it
# drives another, and an unwritable target git dir degrades the check rather than the launch.
# KAIZERO_TEST_EMIT=1 stops each launch right after the banner.

# Setup
TT="$TESTROOT/T-004-cross-fleet-exclusion"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktodo(){ ( cd "$1"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }
# --local-merge: none of these fixture repos carry an origin, so a two-repo case
# (SAME_REPO=0) would otherwise hit the new default-to-mr detection's "no origin" refusal before
# ever reaching the role-detection guards this scenario exists to test; the flag opts every case
# back into today's local-merge path, same-repo cases included (a harmless no-op there).
# both helpers capture RC=$rc on their last line: the launch banner (LAST_STEP printf) prints
# BEFORE either registry check runs, so a positive case must never grep the banner as its proof of
# passing — it would pass just as well on a launch the registries were about to refuse. The
# KAIZERO_TEST_EMIT exit line below prints only after both registry checks return without
# refusing, so it — plus RC=0 — is what "proceeds" means here.
emit(){ ( cd "$1"; rc=0; out=$(KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }   # $1=launch dir $2=todo arg
refuse(){ ( cd "$1"; rc=0; out=$(KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }
# a launch that reached the KAIZERO_TEST_EMIT exit (both registries passed) names its OWN
# coordination git dir on that line — the one line in the whole scenario a refused launch never
# reaches. $1=out $2=coordination repo (physical path)
proceeded(){ echo "$1" | grep -qF "wrote generated scripts to $2/.git, exiting." && echo "$1" | grep -qx 'RC=0'; }

# T14 — cross-fleet exclusion: a target already driven refuses a second coordination point, passes its own fleet, and reaps a dead peer
mkrepo "$TT/code14"; mkrepo "$TT/plan14a"; mktodo "$TT/plan14a"; mkrepo "$TT/plan14b"; mktodo "$TT/plan14b"
CODE14="$(cd "$TT/code14" && pwd -P)"; PLAN14A="$(cd "$TT/plan14a" && pwd -P)"; PLAN14B="$(cd "$TT/plan14b" && pwd -P)"

# fake a live peer instance driving code14 from plan14a (pid + start time of a real, running process)
( sleep 30 ) > "$TT/peer14.out" 2>&1 & peer=$!; sleep 0.3; st="$(ps -o lstart= -p "$peer" | awk '{$1=$1;print}')"
mkdir -p "$CODE14/.git/kaizero-instance"
printf '%s\n%s\n%s\n' "$peer" "$st" "$PLAN14A@main" > "$CODE14/.git/kaizero-instance/peer"

out=$(refuse "$CODE14" "$PLAN14B/todo.md")
check "T14 refuses other coord" "$(echo "$out" | grep -c "Target '$CODE14@main' is already driven from '$PLAN14A@main'")" "1"
check "T14 rc" "$(echo "$out" | grep RC=)" "RC=1"

out=$(emit "$CODE14" "$PLAN14A/todo.md")
check "T14 same fleet passes" "$(proceeded "$out" "$PLAN14A" && echo yes || echo NO)" "yes"

kill "$peer" 2>/dev/null
out=$(emit "$CODE14" "$PLAN14B/todo.md")
check "T14 dead peer reaped" "$(proceeded "$out" "$PLAN14B" && echo yes || echo NO)" "yes"
check "T14 peer marker gone" "$([ -e "$CODE14/.git/kaizero-instance/peer" ] && echo NO || echo yes)" "yes"

# T15 — cross-fleet exclusion, symmetric: one coordination point refuses driving a second target while it drives another
mkrepo "$TT/code15a"; mkrepo "$TT/code15b"; mkrepo "$TT/plan15"; mktodo "$TT/plan15"
CODE15A="$(cd "$TT/code15a" && pwd -P)"; CODE15B="$(cd "$TT/code15b" && pwd -P)"; PLAN15="$(cd "$TT/plan15" && pwd -P)"

( sleep 30 ) > "$TT/peer15.out" 2>&1 & peer=$!; sleep 0.3; st="$(ps -o lstart= -p "$peer" | awk '{$1=$1;print}')"
mkdir -p "$PLAN15/.git/instance"
printf '%s\n%s\n%s\n%s\n' "$peer" "$st" "zz" "$CODE15A@main" > "$PLAN15/.git/instance/peer"

out=$(refuse "$CODE15B" "$PLAN15/todo.md")
check "T15 refuses other target" "$(echo "$out" | grep -c "Coordination '$PLAN15@main' already drives '$CODE15A@main'")" "1"
check "T15 rc" "$(echo "$out" | grep RC=)" "RC=1"
kill "$peer" 2>/dev/null

# T16 — an unwritable target git dir degrades the cross-fleet check, never the launch, exactly once
mkrepo "$TT/code16"; mkrepo "$TT/plan16"; mktodo "$TT/plan16"
CODE16="$(cd "$TT/code16" && pwd -P)"
chmod 555 "$TT/code16/.git"
PLAN16="$(cd "$TT/plan16" && pwd -P)"
out=$(emit "$TT/code16" "$TT/plan16/todo.md")
check "T16 launch still proceeds" "$(proceeded "$out" "$PLAN16" && echo yes || echo NO)" "yes"
# want 1, never 0, never 3 — one notice how ever many of directory/lock/marker failed
check "T16 degrade reported once" "$(echo "$out" | grep -c 'registry degraded, running unlocked')" "1"
check "T16 degrade names target" "$(echo "$out" | grep -c "'$CODE16/.git' — target registry degraded")" "1"
chmod 755 "$TT/code16/.git"

# T17 — a refused cross-fleet launch leaves both repositories' git dirs exactly as it found them
mkrepo "$TT/code17"; mkrepo "$TT/plan17a"; mktodo "$TT/plan17a"; mkrepo "$TT/plan17b"; mktodo "$TT/plan17b"
CODE17="$(cd "$TT/code17" && pwd -P)"; PLAN17A="$(cd "$TT/plan17a" && pwd -P)"; PLAN17B="$(cd "$TT/plan17b" && pwd -P)"
# a fake, unreachable origin: enough for the launch-time origin/forge decision to pick MR mode
# without --local-merge; KAIZERO_TEST_EMIT skips run_doctor's own reachability probe.
git -C "$CODE17" remote add origin https://github.com/acme/does-not-exist.git

( sleep 30 ) > "$TT/peer17.out" 2>&1 & peer=$!; sleep 0.3; st="$(ps -o lstart= -p "$peer" | awk '{$1=$1;print}')"
mkdir -p "$CODE17/.git/kaizero-instance"
printf '%s\n%s\n%s\n' "$peer" "$st" "$PLAN17A@main" > "$CODE17/.git/kaizero-instance/peer"

# both sides' zero.sh: absent before a refused launch, absent (or byte-identical) after
# shellcheck disable=SC2015
[ -e "$PLAN17B/.git/zero.sh" ] && cp "$PLAN17B/.git/zero.sh" "$TT/zero-before-b.sh" || rm -f "$TT/zero-before-b.sh"
# shellcheck disable=SC2015
[ -e "$CODE17/.git/zero.sh" ] && cp "$CODE17/.git/zero.sh" "$TT/zero-before-a.sh" || rm -f "$TT/zero-before-a.sh"

out=$(refuse "$CODE17" "$PLAN17B/todo.md")
check "T17 refused (local-merge)" "$(echo "$out" | grep -c "Target '$CODE17@main' is already driven from '$PLAN17A@main'")" "1"

if [ -e "$TT/zero-before-b.sh" ]; then
  check "T17 coord zero.sh unchanged" "$([ -e "$PLAN17B/.git/zero.sh" ] && cmp -s "$TT/zero-before-b.sh" "$PLAN17B/.git/zero.sh" && echo yes || echo NO)" "yes"
else
  check "T17 coord zero.sh still absent" "$([ -e "$PLAN17B/.git/zero.sh" ] && echo NO || echo yes)" "yes"
fi
if [ -e "$TT/zero-before-a.sh" ]; then
  check "T17 target zero.sh unchanged" "$([ -e "$CODE17/.git/zero.sh" ] && cmp -s "$TT/zero-before-a.sh" "$CODE17/.git/zero.sh" && echo yes || echo NO)" "yes"
else
  check "T17 target zero.sh still absent" "$([ -e "$CODE17/.git/zero.sh" ] && echo NO || echo yes)" "yes"
fi
check "T17 refused instance's coord marker gone" "$(find "$PLAN17B/.git/instance" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
check "T17 refused instance's target marker gone" "$(find "$CODE17/.git/kaizero-instance" -type f ! -name peer 2>/dev/null | wc -l | tr -d ' ')" "0"

# same refusal, in MR mode: KAIZERO_TEST_EMIT stops the launch right after the registries,
# before run_doctor's network probe, so the fake origin above is all MR mode needs here.
mrrefuse(){ ( cd "$1"; rc=0; out=$(KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" "$2" 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }
mkrepo "$TT/plan17c"; mktodo "$TT/plan17c"; PLAN17C="$(cd "$TT/plan17c" && pwd -P)"
out=$(mrrefuse "$CODE17" "$PLAN17C/todo.md")
check "T17 refused (MR mode)" "$(echo "$out" | grep -c "Target '$CODE17@main' is already driven from '$PLAN17A@main'")" "1"
check "T17 MR coord zero.sh absent" "$([ -e "$PLAN17C/.git/zero.sh" ] && echo NO || echo yes)" "yes"

kill "$peer" 2>/dev/null

# T18 — a marker with no readable pid/start time is reaped like a dead peer's, on both sides
mkrepo "$TT/code18"; mkrepo "$TT/plan18a"; mktodo "$TT/plan18a"
CODE18="$(cd "$TT/code18" && pwd -P)"; PLAN18A="$(cd "$TT/plan18a" && pwd -P)"

# target-side corrupt marker: empty file
mkdir -p "$CODE18/.git/kaizero-instance"; : > "$CODE18/.git/kaizero-instance/corrupt-a"
out=$(emit "$CODE18" "$PLAN18A/todo.md")
check "T18 target-side reaped, launch proceeds" "$(proceeded "$out" "$PLAN18A" && echo yes || echo NO)" "yes"
check "T18 target-side corrupt marker gone" "$([ -e "$CODE18/.git/kaizero-instance/corrupt-a" ] && echo NO || echo yes)" "yes"

# coordination-side corrupt marker: truncated (pid line only, no start time)
mkrepo "$TT/code18b"; mkrepo "$TT/plan18b"; mktodo "$TT/plan18b"
CODE18B="$(cd "$TT/code18b" && pwd -P)"; PLAN18B="$(cd "$TT/plan18b" && pwd -P)"
mkdir -p "$PLAN18B/.git/instance"; printf '999999\n' > "$PLAN18B/.git/instance/corrupt-b"
out=$(emit "$CODE18B" "$PLAN18B/todo.md")
check "T18 coord-side reaped, launch proceeds" "$(proceeded "$out" "$PLAN18B" && echo yes || echo NO)" "yes"
check "T18 coord-side corrupt marker gone" "$([ -e "$PLAN18B/.git/instance/corrupt-b" ] && echo NO || echo yes)" "yes"

# T14 PASS — a live peer's target-side marker refuses a different coordination point (rc = 1),
# the same fleet (same coordination + target pair) still passes, and a dead peer's marker is
# reaped and the launch that reaped it proceeds.
# T15 PASS — the symmetric coordination-side refusal (rc = 1) when one coordination
# repository already drives a different target.
# T16 PASS — an unwritable target git dir degrades the check exactly once — the launch still
# proceeds — and names the target git dir on stderr rather than staying silent or reporting once
# per failed step.
# T17 PASS — a refused launch, in either direction and in both local-merge and MR mode, leaves
# neither repository's .git/zero.sh touched and leaves no marker behind for the refused instance.
# T18 PASS — an unreadable (empty or truncated) marker is reaped exactly like a dead peer's, on
# both the target-side and coordination-side registry, and the launch that reaped it proceeds.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
