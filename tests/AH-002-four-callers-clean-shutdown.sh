#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=300s
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# AH-002-four-callers-clean-shutdown — drives all four shutdown paths (on_term, on_hup,
# arm_watchdog, term_owner) end to end through a real kaizero.sh launch, proving: claude
# receives a real, deliverable SIGTERM (never SIGHUP as a side effect of the wrapper's pty
# tearing down first — BUG-058k's original bug), an obedient claude's own TERM-triggered cleanup
# runs and its output survives untouched (no forced screen wipe), a TERM-ignoring claude is still
# escalated to SIGKILL within the shared grace period on the two paths (on_term/on_hup) that used
# to never escalate at all, and a KILL-escalated (or crashed) session's on-screen output is left
# exactly as it was — not reset — since that state is what's useful for debugging afterward.
# Needs real claude: no — python3 stubs stand in (real sigaction, not a shell `trap`, per BUG-058k's
# own note that a non-interactive shell cannot un-ignore an already-SIG_IGN'd signal inherited
# through the wrapper's `trap "" TERM; exec script ...` layer).
# Tools beyond the shared prerequisites: python3, script (already required elsewhere).
# Folder under $TESTROOT: $TESTROOT/AH-002-four-callers-clean-shutdown

TJ="$TESTROOT/AH-002-four-callers-clean-shutdown"; mkdir -p "$TJ/repo" "$TJ/bin"
cd "$TJ/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] J1 x\n' > todo.md; git add -A; git commit -qm init

# an obedient stub: real SIGTERM handler prints a "cleaned up" marker and exits 0; a SIGHUP
# handler (should never fire post-fix — HUP would only reach claude if something tore the pty
# down as a side effect of killing the wrapper first, the exact original bug) prints a distinct
# "NO cleanup" marker and exits 1, so the log tells us unambiguously which signal actually landed.
write_obedient(){ printf '#!/usr/bin/env python3\nimport sys, signal, time\nif len(sys.argv) > 1 and sys.argv[1] == "-v":\n    print("stub-claude 0.0.0"); sys.exit(0)\ndef on_term(s, f):\n    print("[claude] got TERM, cleaned up modes", flush=True)\n    sys.exit(0)\ndef on_hup(s, f):\n    print("[claude] got HUP, NO cleanup", flush=True)\n    sys.exit(1)\nsignal.signal(signal.SIGTERM, on_term)\nsignal.signal(signal.SIGHUP, on_hup)\nprint("[claude] started, modes ON", flush=True)\nopen("%s", "w").close()\ntime.sleep(1000)\n' "$1" > "$TJ/bin/claude"; chmod +x "$TJ/bin/claude"; }
# a deaf stub: ignores TERM for real (Python-level SIG_IGN, not a shell trap), for the
# escalation/no-reset cases.
write_deaf(){ printf '#!/usr/bin/env python3\nimport sys, signal, time\nif len(sys.argv) > 1 and sys.argv[1] == "-v":\n    print("stub-claude 0.0.0"); sys.exit(0)\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nprint("[claude] started, modes ON", flush=True)\nopen("%s", "w").close()\nprint("[claude] stub deaf", flush=True)\ntime.sleep(1000)\n' "$1" > "$TJ/bin/claude"; chmod +x "$TJ/bin/claude"; }

# J1 — on_term: obedient stub, TERM sent to the wrapper itself
cd "$TJ/repo"; rm -f "$TJ/j1.ready"
write_obedient "$TJ/j1.ready"
PATH="$TJ/bin:$PATH" env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TJ/j1.log" 2>&1 &
WPID=$!
i=0; while [ ! -f "$TJ/j1.ready" ] && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
kill -TERM "$WPID" 2>/dev/null
i=0; while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
kill -0 "$WPID" 2>/dev/null && kill -KILL "$WPID" 2>/dev/null
wait "$WPID" 2>/dev/null
check "J1 on_term: clean TERM handled" "$(grep -c 'got TERM, cleaned up modes' "$TJ/j1.log")" "1"
check "J1 on_term: never got HUP" "$(grep -c 'got HUP' "$TJ/j1.log")" "0"
# J1 PASS — clean TERM handled = 1, never got HUP = 0.

# J2 — on_hup: obedient stub, HUP sent to the wrapper itself (kaizero.sh's own `trap on_hup HUP`)
cd "$TJ/repo"; rm -f "$TJ/j2.ready"
write_obedient "$TJ/j2.ready"
PATH="$TJ/bin:$PATH" env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TJ/j2.log" 2>&1 &
WPID=$!
i=0; while [ ! -f "$TJ/j2.ready" ] && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
kill -HUP "$WPID" 2>/dev/null
i=0; while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
kill -0 "$WPID" 2>/dev/null && kill -KILL "$WPID" 2>/dev/null
wait "$WPID" 2>/dev/null
# on_hup drives terminator.sh the same as on_term — claude itself still gets a real TERM, never HUP
check "J2 on_hup: claude got real TERM, not HUP" "$(grep -c 'got TERM, cleaned up modes' "$TJ/j2.log")" "1"
check "J2 on_hup: never got HUP" "$(grep -c 'got HUP' "$TJ/j2.log")" "0"
# J2 PASS — claude got real TERM, not HUP = 1, never got HUP = 0.

# J3 — on_hup escalation: a deaf claude driven through on_hup is still KILLed once the shared
# grace period elapses (BUG-058k: on_hup used to send a single HUP-triggered TERM with no
# escalation at all)
cd "$TJ/repo"; rm -f "$TJ/j3.ready"
write_deaf "$TJ/j3.ready"
PATH="$TJ/bin:$PATH" env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TJ/j3.log" 2>&1 &
WPID=$!
i=0; while [ ! -f "$TJ/j3.ready" ] && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
kill -HUP "$WPID" 2>/dev/null
# a TERM-obedient stub would already be gone by here; the deaf one must still be alive
sleep 2
check "J3 deaf survives HUP-triggered TERM" "$(pgrep -f "$TJ/bin/claude" | wc -l | tr -d ' ')" "1"
i=0; while pgrep -f "$TJ/bin/claude" >/dev/null 2>&1 && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done
check "J3 deaf killed within grace" "$(pgrep -f "$TJ/bin/claude" | wc -l | tr -d ' ')" "0"
i=0; while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i+1)); done
kill -0 "$WPID" 2>/dev/null && kill -KILL "$WPID" 2>/dev/null
wait "$WPID" 2>/dev/null
# J3 PASS — deaf survives HUP-triggered TERM = 1, deaf killed within grace = 0.

# J4 — arm_watchdog: obedient stub, no progress for KAIZERO_WATCHDOG seconds — the watchdog's
# own TERM (not an outside signal) reaches claude for real, and cleans up
cd "$TJ/repo"; rm -f "$TJ/j4.ready"
write_obedient "$TJ/j4.ready"
PATH="$TJ/bin:$PATH" KAIZERO_WATCHDOG=5 timeout 90 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TJ/j4.log" 2>&1
check "J4 arm_watchdog: clean TERM handled" "$(grep -c 'got TERM, cleaned up modes' "$TJ/j4.log")" "1"
check "J4 arm_watchdog: never got HUP" "$(grep -c 'got HUP' "$TJ/j4.log")" "0"
# J4 PASS — clean TERM handled = 1, never got HUP = 0.

# J5 — term_owner (the Stop hook): obedient WRAPPER/CHILD pair, same driver shape as
# tests/AE-001-term-owner-escalation.sh's run_term_owner, proving the real signal reaching the
# child is TERM, never HUP.
cd "$TJ/repo"
KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
HOOK="$TJ/repo/.git/compact-exit-hook.sh"
write_obedient "$TJ/j5.ready"   # reuses the same python3 stub body as the CHILD command below
bash -c 'python3 "'"$TJ"'/bin/claude" & echo $! > "'"$TJ"'/j5child.pid"; wait' > "$TJ/j5wrapper.out" 2>&1 &
J5WRAP=$!
i=0; while [ ! -s "$TJ/j5child.pid" ] && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i+1)); done
i=0; while [ ! -f "$TJ/j5.ready" ] && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i+1)); done
st="$(ps -o lstart= -p "$J5WRAP" 2>/dev/null | awk '{$1=$1;print}')"
rec="$TJ/j5.rec"; printf '%s\n%s\n%s\n' "$J5WRAP" "$st" 1 > "$rec"
safe="$TJ/j5.safe"; printf 'x\n' > "$safe"
reason="$TJ/j5.reason"
KAIZERO_INSTANCE=AH002J5 KAIZERO_SESSION_RECORD="$rec" KAIZERO_SESSION_EPOCH=1 \
  KAIZERO_SAFE_TO_EXIT="$safe" KAIZERO_EXIT_REASON="$reason" \
  bash -c 'printf "%s" "{}" | bash "$1" >/dev/null 2>&1' _ "$HOOK" > "$TJ/j5hook.out" 2>&1
i=0; while kill -0 "$J5WRAP" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i+1)); done
check "J5 term_owner: clean TERM handled" "$(grep -c 'got TERM, cleaned up modes' "$TJ/j5wrapper.out")" "1"
check "J5 term_owner: never got HUP" "$(grep -c 'got HUP' "$TJ/j5wrapper.out")" "0"
kill -KILL "$J5WRAP" 2>/dev/null; wait "$J5WRAP" 2>/dev/null
# J5 PASS — clean TERM handled = 1, never got HUP = 0.

# J6 — an external supervisor's group-wide SIGTERM (kaizero.sh, the wrapper, and claude all
# share one process group — BUG 039p rejected splitting them into separate groups) still reaches
# claude directly and lets it clean up, because the wrapper's own `trap "" TERM; exec script ...`
# layer ignores that same group-wide TERM instead of dying and tearing the pty down first. Uses
# `set -m` in a dedicated launcher subshell so the backgrounded kaizero.sh gets its own
# process group, distinct from this scenario script's own — otherwise the group-wide TERM below
# would also reach the test harness itself.
cd "$TJ/repo"; rm -f "$TJ/j6.ready"
write_obedient "$TJ/j6.ready"
cat > "$TJ/j6launcher.sh" <<'LEOF'
#!/usr/bin/env bash
set -m
SCRIPT="$1"; TJ="$2"
cd "$TJ/repo"
PATH="$TJ/bin:$PATH" env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TJ/j6.log" 2>&1 &
echo $! > "$TJ/j6wpid"
wait
LEOF
chmod +x "$TJ/j6launcher.sh"
bash "$TJ/j6launcher.sh" "$SCRIPT" "$TJ" > "$TJ/j6launcher.out" 2>&1 &
J6LAUNCHER=$!
i=0; while [ ! -f "$TJ/j6.ready" ] && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
J6WPID="$(cat "$TJ/j6wpid" 2>/dev/null)"
J6PGID="$(ps -o pgid= -p "$J6WPID" 2>/dev/null | tr -d ' ')"
kill -TERM "-$J6PGID" 2>/dev/null
i=0; while kill -0 "$J6WPID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
kill -0 "$J6WPID" 2>/dev/null && kill -KILL "-$J6PGID" 2>/dev/null
wait "$J6LAUNCHER" 2>/dev/null
check "J6 group-wide TERM: claude cleaned up" "$(grep -c 'got TERM, cleaned up modes' "$TJ/j6.log")" "1"
check "J6 group-wide TERM: never got HUP" "$(grep -c 'got HUP' "$TJ/j6.log")" "0"

# J7 — a session KILLed after ignoring its TERM leaves its on-screen output exactly as it was —
# not wiped — since that state is what's useful for debugging afterward (BUG-058d's removed
# \033c/RESET_NEEDED reset must not run for this case, same as any other).
cd "$TJ/repo"; rm -f "$TJ/j7.ready"
write_deaf "$TJ/j7.ready"
PATH="$TJ/bin:$PATH" env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TJ/j7.log" 2>&1 &
WPID=$!
i=0; while [ ! -f "$TJ/j7.ready" ] && [ "$i" -lt 175 ]; do sleep 0.2; i=$((i+1)); done
kill -TERM "$WPID" 2>/dev/null
i=0; while pgrep -f "$TJ/bin/claude" >/dev/null 2>&1 && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done
i=0; while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i+1)); done
kill -0 "$WPID" 2>/dev/null && kill -KILL "$WPID" 2>/dev/null
wait "$WPID" 2>/dev/null
# the deaf stub's own "started, modes ON" line is still present in the captured output — nothing
# cleared the screen/log after the KILL escalation
check "J7 pre-KILL output survives (not wiped)" "$(grep -c 'started, modes ON' "$TJ/j7.log")" "1"
# no reset escape sequence appears anywhere in the output
check "J7 no RIS reset byte emitted" "$(grep -c $'\033c' "$TJ/j7.log")" "0"
# J7 PASS — pre-KILL output survives = 1, no RIS reset byte emitted = 0.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
