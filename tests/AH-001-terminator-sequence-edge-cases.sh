#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# AH-001-terminator-sequence-edge-cases — BUG-058k: terminator.sh is the ONE shared sequence
# on_term/on_hup/arm_watchdog/term_owner all invoke identically (same args shape, same file, no
# per-caller copy) — proven elsewhere in this suite (AA-001/AE-001/AF-001/K-001/N-001 each drive
# a different caller through it). Because the sequence itself does not know or care which of the
# four called it, the edge cases below — mid-wait record disappearance, reparented-descendant
# sweep, EXIT-trap-under-failure, and real-SIGTERM-vs-SIGHUP delivery — are properties of
# terminator.sh itself and are proven once here by invoking it directly (the same emitted file,
# the same args every caller passes), rather than four times through four different launch
# harnesses that would only re-exercise the identical shared code path.
# Needs real claude: no.
# Tools beyond the shared prerequisites: none.
# Folder under $TESTROOT: $TESTROOT/AH-001-terminator-sequence-edge-cases

TH="$TESTROOT/AH-001-terminator-sequence-edge-cases"; mkdir -p "$TH/repo"
cd "$TH/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] H1 x\n' > todo.md; git add -A; git commit -qm init
KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1   # writes the real emitted terminator.sh, no claude needed
TERMINATOR="$TH/repo/.git/terminator.sh"
check "setup terminator.sh emitted" "$([ -x "$TERMINATOR" ] && echo yes || echo no)" "yes"

# H1 — a session record that disappears mid-wait because a restart overwrote it with a DIFFERENT
# session's identity (the Task's own example, and AE-001's AE3 driver pattern for term_owner) is
# left alone: no KILL sent, the stale (deaf) wrapper survives, and the bystander it now names is
# never touched since its epoch still doesn't match either.
cd "$TH/repo"
bash -c 'trap "" TERM; sleep 1000' > "$TH/h1victim.out" 2>&1 & H1VICTIM=$!
bash -c 'trap "" TERM; sleep 1000' > "$TH/h1bystander.out" 2>&1 & H1BYSTANDER=$!
vst="$(ps -o lstart= -p "$H1VICTIM" 2>/dev/null | awk '{$1=$1;print}')"
rec="$TH/h1.rec"; printf '%s\n%s\n%s\n' "$H1VICTIM" "$vst" 1 > "$rec"
reason="$TH/h1.reason"
"$TERMINATOR" "$rec" 1 "$reason" > "$TH/h1.out" 2>&1 &
TPID=$!
# overwrite the record with the bystander's identity (a different epoch) shortly after dispatch,
# well inside WATCHDOG_GRACE=10, before the recheck — exactly as a real restart would
sleep 1
bst="$(ps -o lstart= -p "$H1BYSTANDER" 2>/dev/null | awk '{$1=$1;print}')"
printf '%s\n%s\n%s\n' "$H1BYSTANDER" "$bst" 2 > "$rec"
wait "$TPID" 2>/dev/null
sleep 1
# left alone: the deaf victim survives (no KILL follows a superseded record)
check "H1 victim survives superseded record" "$(kill -0 "$H1VICTIM" 2>/dev/null && echo yes || echo no)" "yes"
# the new record names it, but its epoch (2) never matched WANT_EPOCH=1 either
check "H1 bystander untouched" "$(kill -0 "$H1BYSTANDER" 2>/dev/null && echo yes || echo no)" "yes"
check "H1 status mentions superseded" "$(grep -c 'superseded' "$reason" 2>/dev/null)" "1"
kill -KILL "$H1VICTIM" "$H1BYSTANDER" 2>/dev/null; wait "$H1VICTIM" "$H1BYSTANDER" 2>/dev/null
# H1 PASS — victim survives superseded record = yes, bystander untouched = yes, status mentions superseded = 1.

# H2 — a descendant that outlives claude's own TERM-honored exit (reparented away from it before
# any recheck) still gets KILLed via the pre-TERM snapshot/post-KILL sweep — this is the property
# arm_watchdog already has today (per the Task) and the fix must carry to the shared sequence for
# every caller, since they all now go through the very same sweep.
cd "$TH/repo"
GRANDCHILD_MARK="$TH/h2.grandchild.pid"
# WRAPPER is a python3 stub: on TERM it exits immediately WITHOUT waiting on its own child, so the
# child (GRANDCHILD, a plain sleep) is reparented to init the instant WRAPPER dies — exactly the
# race the pre-TERM snapshot exists to survive.
cat > "$TH/h2wrapper.py" <<PYEOF
import sys, signal, subprocess, time
def on_term(s, f):
    sys.exit(0)
signal.signal(signal.SIGTERM, on_term)
p = subprocess.Popen(["sleep", "1000"])
with open("$GRANDCHILD_MARK", "w") as f:
    f.write(str(p.pid))
time.sleep(1000)
PYEOF
python3 "$TH/h2wrapper.py" > "$TH/h2wrapper.out" 2>&1 & H2WRAP=$!
i=0; while [ ! -s "$GRANDCHILD_MARK" ] && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i+1)); done
GRANDCHILD="$(cat "$GRANDCHILD_MARK")"
st="$(ps -o lstart= -p "$H2WRAP" 2>/dev/null | awk '{$1=$1;print}')"
rec="$TH/h2.rec"; printf '%s\n%s\n%s\n' "$H2WRAP" "$st" 1 > "$rec"
reason="$TH/h2.reason"
"$TERMINATOR" "$rec" 1 "$reason" > "$TH/h2.out" 2>&1
i=0; while kill -0 "$H2WRAP" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
# WRAPPER honored TERM immediately, well before WATCHDOG_GRACE elapses
check "H2 wrapper gone fast" "$(kill -0 "$H2WRAP" 2>/dev/null && echo no || echo yes)" "yes"
i=0; while kill -0 "$GRANDCHILD" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i+1)); done
# the reparented grandchild is still reached and killed via the pre-TERM snapshot, not by a
# re-walk from the (by then dead) wrapper pid
check "H2 reparented descendant killed" "$(kill -0 "$GRANDCHILD" 2>/dev/null && echo no || echo yes)" "yes"
kill -KILL "$GRANDCHILD" "$H2WRAP" 2>/dev/null; wait "$H2WRAP" 2>/dev/null
# H2 PASS — wrapper gone fast = yes, reparented descendant killed = yes.

# H3 — a step inside the sequence failing partway through still results in a final write to the
# exit-reason file (the EXIT trap's own job), rather than leaving nothing written at all.
cd "$TH/repo"
FAULTY="$TH/terminator-faulty.sh"
# copy the real emitted sequence and inject an unrecoverable failure (an unbound variable
# reference under the script's own `set -u`) immediately after the pre-TERM snapshot/status
# write, before the sequence would otherwise reach SEQUENCE_DONE=1 — proving the EXIT trap (not
# the normal end-of-sequence path) is what produces the final write.
awk '{print} /append_status "TERM sent"/ && !done { print "  : \"${AH001_UNBOUND_INJECTED_FAULT?}\""; done=1 }' "$TERMINATOR" > "$FAULTY"
chmod +x "$FAULTY"
check "H3 fault actually injected" "$(grep -c AH001_UNBOUND_INJECTED_FAULT "$FAULTY")" "1"
bash -c 'trap "" TERM; sleep 1000' > "$TH/h3wrapper.out" 2>&1 & H3WRAP=$!
st="$(ps -o lstart= -p "$H3WRAP" 2>/dev/null | awk '{$1=$1;print}')"
rec="$TH/h3.rec"; printf '%s\n%s\n%s\n' "$H3WRAP" "$st" 1 > "$rec"
reason="$TH/h3.reason"
"$FAULTY" "$rec" 1 "$reason" > "$TH/h3.out" 2>&1
i=0; while ! grep -q 'sequence aborted early' "$reason" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done
# the EXIT trap's own record, not silence
check "H3 abort recorded" "$(grep -c 'sequence aborted early' "$reason" 2>/dev/null)" "1"
# the EXIT trap only records — it must not itself have sent a further KILL/TERM (the wrapper may
# still be running, now with a record of the early failure rather than a guarantee of cleanup)
check "H3 wrapper left as-is (no trap-driven kill)" "$(kill -0 "$H3WRAP" 2>/dev/null && echo yes || echo no)" "yes"
kill -KILL "$H3WRAP" 2>/dev/null; wait "$H3WRAP" 2>/dev/null
# H3 PASS — fault actually injected = 1, abort recorded = 1, wrapper left as-is = yes.

# H4 — terminator.sh's TERM step delivers a real, deliverable SIGTERM to the target descendant
# (never SIGHUP, and never via a path that could deliver SIGHUP as a side effect of tearing down
# a wrapper/pty first) — the exact signal-identity property BUG-058k's own repro exists to prove,
# generalized: every one of the four callers reduces to this exact call shape (RECORD_FILE
# WANT_EPOCH EXIT_REASON_FILE), so proving it once here covers all four; which caller triggers it
# is separately proven by AA-001/AE-001/AF-001/K-001/N-001, none of which contain their own
# kill_tree copy (see this Task's own absence checks).
cd "$TH/repo"
cat > "$TH/h4child.py" <<PYEOF
import sys, signal, time
def on_term(s, f):
    with open("$TH/h4.sig", "w") as f2:
        f2.write("TERM")
    sys.exit(0)
def on_hup(s, f):
    with open("$TH/h4.sig", "w") as f2:
        f2.write("HUP")
    sys.exit(1)
signal.signal(signal.SIGTERM, on_term)
signal.signal(signal.SIGHUP, on_hup)
print("ready", flush=True)
time.sleep(1000)
PYEOF
# WRAPPER/CHILD pair, same shape as AE-001's run_term_owner driver: WRAPPER backgrounds CHILD (the
# process terminator.sh's descendant-walk actually reaches) and exits the moment CHILD does.
bash -c 'python3 "'"$TH"'/h4child.py" & echo $! > "'"$TH"'/h4child.pid"; wait' > "$TH/h4wrapper.out" 2>&1 & H4WRAP=$!
i=0; while [ ! -s "$TH/h4child.pid" ] && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i+1)); done
H4CHILD="$(cat "$TH/h4child.pid")"
i=0; while ! grep -q ready "$TH/h4wrapper.out" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i+1)); done
st="$(ps -o lstart= -p "$H4WRAP" 2>/dev/null | awk '{$1=$1;print}')"
rec="$TH/h4.rec"; printf '%s\n%s\n%s\n' "$H4WRAP" "$st" 1 > "$rec"
reason="$TH/h4.reason"
"$TERMINATOR" "$rec" 1 "$reason" > "$TH/h4.out" 2>&1
i=0; while kill -0 "$H4WRAP" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
check "H4 signal delivered was TERM" "$(cat "$TH/h4.sig" 2>/dev/null)" "TERM"
check "H4 wrapper reaped" "$(kill -0 "$H4WRAP" 2>/dev/null && echo no || echo yes)" "yes"
kill -KILL "$H4CHILD" "$H4WRAP" 2>/dev/null; wait "$H4WRAP" 2>/dev/null
# H4 PASS — signal delivered was TERM = TERM, wrapper reaped = yes.

# AH PASS — H1 through H4 all report PASS.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
