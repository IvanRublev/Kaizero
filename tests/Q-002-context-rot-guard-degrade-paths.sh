#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# Q-002-context-rot-guard-degrade-paths — the context-rot guard's edge behavior: the 256 KiB
# read cap degrading to a row miss past it, every degraded input (missing/unreadable/usage-free
# transcript) leaving the session running, and the emitted hook staying byte-identical across two
# instances of the same kaizero.sh.
# - Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor
#   tests `command -v claude` before any startup guard runs)
# - Tools beyond the shared prerequisites: none
# - Folder under $TESTROOT: $TESTROOT/Q-002-context-rot-guard-degrade-paths
# - Wall-clock budget: seconds — no Run command of this scenario wraps itself in timeout
# - Cross-references named in the body below: Scenario M's M4 cases (tests/M-001-one-task-per-session.sh)
#
# The Stop hook computes its own restart signal from CONTEXT_THRESHOLDS against a session
# transcript — no third-party hook, no state file. Every case here drives the hook directly with
# a static JSONL fixture, carrying a KAIZERO_INSTANCE (every real kaizero.sh launch always
# sets one, kaizero.sh:1003 — uuidgen, falling back to $$, never empty), so the guard is
# exercised exactly as it would be for a real session; the marker-gate itself (BUG 057,
# kaizero.sh:1315-1321) is out of scope here — that is M4's subject, not this one's.

TQ="$TESTROOT/Q-002-context-rot-guard-degrade-paths"; mkdir -p "$TQ/repo"
cd "$TQ/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] Q1 x\n' > todo.md; git add -A; git commit -qm init
KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1   # writes the real emitted hook, no claude needed
HOOK="$TQ/repo/.git/compact-exit-hook.sh"

# fires the emitted hook with $2 as its stdin payload, against the given hook file, with a
# nonempty instance marker set — matches every real kaizero.sh launch (kaizero.sh:1003
# always generates one), so the marker-gate at kaizero.sh:1321 passes and the guard below it
# actually runs, instead of being blocked before it's ever reached.
# BUG 057: ensure_owner/term_owner need a valid KAIZERO_SESSION_RECORD, not a `claude`-named
# ancestor — a disposable `sleep` stub stands in as the session the hook may or may not TERM;
# still alive after the hook returns means no restart fired, killed means it did.
run_hook(){ local hook="$1" payload="$2"
  bash -c 'sleep 60 & wait' > "$TQ/stub-$$.out" 2>&1 &
  local stub=$!
  local rec="$TQ/rec-$stub" st
  st="$(ps -o lstart= -p "$stub" 2>/dev/null | awk '{$1=$1;print}')"
  printf '%s\n%s\n%s\n' "$stub" "$st" 1 > "$rec"
  env KAIZERO_INSTANCE=Q002TEST KAIZERO_SESSION_RECORD="$rec" KAIZERO_SESSION_EPOCH=1 \
    bash -c 'printf "%s" "$2" | bash "$1" >/dev/null 2>&1' _ "$hook" "$payload"
  i=0; while kill -0 "$stub" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$stub" 2>/dev/null; then
    kill -KILL "$stub" 2>/dev/null; wait "$stub" 2>/dev/null
    echo 0
  else
    wait "$stub" 2>/dev/null
    echo 143
  fi
}
run_as_claude(){ run_hook "$HOOK" "$1"; }
# same driver, stderr redirected to $3 instead of discarded — the empty-stderr assertion (Q8)
# needs to observe it, which run_hook's own >/dev/null 2>&1 cannot.
run_hook_stderr(){ local hook="$1" payload="$2" errfile="$3"
  bash -c 'sleep 60 & wait' > "$TQ/stub-$$.out" 2>&1 &
  local stub=$!
  local rec="$TQ/rec-$stub" st
  st="$(ps -o lstart= -p "$stub" 2>/dev/null | awk '{$1=$1;print}')"
  printf '%s\n%s\n%s\n' "$stub" "$st" 1 > "$rec"
  env KAIZERO_INSTANCE=Q002TEST KAIZERO_SESSION_RECORD="$rec" KAIZERO_SESSION_EPOCH=1 \
    bash -c 'printf "%s" "$2" | bash "$1" >/dev/null 2>"$3"' _ "$hook" "$payload" "$errfile"
  i=0; while kill -0 "$stub" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$stub" 2>/dev/null; then
    kill -KILL "$stub" 2>/dev/null; wait "$stub" 2>/dev/null
    echo 0
  else
    wait "$stub" 2>/dev/null
    echo 143
  fi
}
path(){ printf '{"transcript_path":"%s"}' "$1"; }   # the Stop hook payload shape

# one transcript line: requestId model input cache_read cache_creation output
rec(){ printf '{"type":"assistant","requestId":"%s","message":{"model":"%s","usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"output_tokens":%s}}}' "$1" "$2" "$3" "$4" "$5" "$6"; }

# Q7 — the 256 KiB cap: a record just under it resolves model, padded past it does not
mkpad(){ yes x | tr -d '\n' | head -c "$1"; }   # bash's ${var//pat/rep} is O(n^2) at this size
rec_pad(){ printf '{"type":"assistant","requestId":"r1","message":{"model":"claude-opus-5","content":"%s","usage":{"input_tokens":9000,"cache_read_input_tokens":170000,"cache_creation_input_tokens":1000,"output_tokens":500}}}' "$1"; }   # 180000 total, between the two thresholds

under_line="$(rec_pad "$(mkpad 100)")"
model_offset=$(awk 'match($0,/"model":/){print RSTART-1; exit}' <<< "$under_line")
TP="$TQ/cap-under.jsonl"; printf '%s' "$under_line" > "$TP"
check "Q7 under cap" "$(run_as_claude "$(path "$TP")")" "0"   # whole record read, resolves claude-opus-5's family row (200000), 180000 < 200000

over_line="$(rec_pad "$(mkpad $((262144 + model_offset + 1000)))")"
TP="$TQ/cap-over.jsonl"; printf '%s' "$over_line" > "$TP"
check "Q7 over cap" "$(run_as_claude "$(path "$TP")")" "143"   # model cropped away by the tail -c cut, default 160000 applies, 180000 >= 160000
# Q7 PASS — under cap = 0, over cap = 143. The token report is unaffected by this cap —
# read_tokens_total's own body carries no tail -c:
check "Q7 token report uncapped" "$(awk '/^read_tokens_total\(\)/{f=1} f{print} f&&/^}/{exit}' "$SCRIPT" | grep -c 'tail -c')" "0"   # the cap belongs to the guard alone

# Q8 — degrade, never lie: every bad input leaves the session running
check "Q8 missing file" "$(run_as_claude "$(path "$TQ/does-not-exist.jsonl")")" "0"
TP="$TQ/no-usage.jsonl"; printf '{"type":"assistant","requestId":"r1","message":{"model":"claude-opus-5"}}\n' > "$TP"
check "Q8 no usage" "$(run_as_claude "$(path "$TP")")" "0"
TP="$TQ/zero-usage.jsonl"; rec r1 claude-opus-5 0 0 0 0 > "$TP"
check "Q8 zero usage" "$(run_as_claude "$(path "$TP")")" "0"
check "Q8 no path key" "$(run_as_claude '{}')" "0"
TP="$TQ/unreadable.jsonl"; rec r1 claude-opus-5 9000 250000 1000 500 > "$TP"; chmod 000 "$TP"
ERR="$TQ/unreadable.err"
check "Q8 unreadable exit" "$(run_hook_stderr "$HOOK" "$(path "$TP")" "$ERR")" "0"
check "Q8 unreadable stderr" "$(wc -c < "$ERR" | tr -d ' ')" "0"   # tail's OWN 2>/dev/null swallows Permission denied
chmod 644 "$TP"
# Q8 PASS — every want-0 check above passes; unreadable stderr = 0.

# Q9 — the emitted hook is byte-identical across two instances of the same kaizero.sh
cd "$TQ/repo"
KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1; cp "$HOOK" "$TQ/hook-1.sh"
KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1; cp "$HOOK" "$TQ/hook-2.sh"
check "Q9 byte-identical" "$(cmp -s "$TQ/hook-1.sh" "$TQ/hook-2.sh" && echo yes || echo NO)" "yes"
# Q9 PASS — byte-identical = yes.

# Q PASS — Q7 through Q9 all report PASS. Run with a nonempty instance marker, matching every
# real kaizero.sh launch, they prove the guard's own cap/degrade-path logic is correct once
# past the marker-gate. Together with M4's marker set/marker unset cases (which cover the gate
# itself, not the guard) they show the two mechanisms compose the way BUG 057 intends: no
# unverified invocation of the hook can signal anything, guard included.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
