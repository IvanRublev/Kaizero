#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# Q-001-context-rot-guard — the context-rot guard's threshold table. The Stop hook's own table
# resolves a restart signal from a fixture transcript: [1m] and each bare family id at 200000, a
# word-suffix tier and unlisted ids at the 160000 default, >= at the exact threshold, and row
# order deciding overlapping rows.
# - Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor
#   tests `command -v claude` before any startup guard runs)
# - Tools beyond the shared prerequisites: none
# - Folder under $TESTROOT: $TESTROOT/Q-001-context-rot-guard
# - Wall-clock budget: seconds — no Run command of this scenario wraps itself in timeout
# - Cross-references named in the body below: Scenario M's M4 cases (tests/M-001-one-task-per-session.sh)
#
# The Stop hook computes its own restart signal from CONTEXT_THRESHOLDS against a session
# transcript — no third-party hook, no state file. Every case here drives the hook directly with
# a static JSONL fixture, carrying no KAIZERO_INSTANCE, so the guard is the only branch that
# can fire (a Kaizero session ends every turn regardless — that is M4's subject, not this one's).

TQ="$TESTROOT/Q-001-context-rot-guard"; mkdir -p "$TQ/repo"
cd "$TQ/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] Q1 x\n' > todo.md; git add -A; git commit -qm init
KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1   # writes the real emitted hook, no claude needed
HOOK="$TQ/repo/.git/compact-exit-hook.sh"

# BUG 057: the old channel drove the hook under a decoy `claude` ancestor and read the guard's
# verdict off that decoy's own exit status (143 = it got SIGTERMed). The gate now sits above every
# branch that can signal and refuses without KAIZERO_INSTANCE, so that channel is gone with the
# ancestor walk it depended on. The new one: set the marker, hand the hook a session record naming
# a disposable stub, and read the verdict off whether the STUB is still alive afterwards (0 = left
# running = no restart; 143 = SIGTERMed = the guard fired) — same two return values every existing
# call site already asserts against, so no call site below needs to change.
run_hook(){ local hook="$1" payload="$2"
  bash -c 'sleep 60 & wait' > "$TQ/stub-$$.out" 2>&1 &
  local stub=$!
  local rec="$TQ/rec-$stub" st
  st="$(ps -o lstart= -p "$stub" 2>/dev/null | awk '{$1=$1;print}')"
  printf '%s\n%s\n%s\n' "$stub" "$st" 1 > "$rec"
  KAIZERO_INSTANCE=Q001 KAIZERO_SESSION_RECORD="$rec" KAIZERO_SESSION_EPOCH=1 \
    KAIZERO_EXIT_REASON="$TQ/reason-$stub" \
    bash -c 'printf "%s" "$2" | bash "$1" >/dev/null 2>&1' _ "$hook" "$payload"
  # terminator.sh validates synchronously then dispatches TERM in its own background job — poll
  # for the stub's death rather than a fixed sleep calibrated to the old synchronous term_owner.
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
# same driver, stderr redirected to $3 instead of discarded — the empty-stderr assertion (Q10)
# needs to observe it, which run_hook's own >/dev/null 2>&1 cannot.
run_hook_stderr(){ local hook="$1" payload="$2" errfile="$3"
  bash -c 'sleep 60 & wait' > "$TQ/stub-$$.out" 2>&1 &
  local stub=$!
  local rec="$TQ/rec-$stub" st
  st="$(ps -o lstart= -p "$stub" 2>/dev/null | awk '{$1=$1;print}')"
  printf '%s\n%s\n%s\n' "$stub" "$st" 1 > "$rec"
  KAIZERO_INSTANCE=Q001 KAIZERO_SESSION_RECORD="$rec" KAIZERO_SESSION_EPOCH=1 \
    KAIZERO_EXIT_REASON="$TQ/reason-$stub" \
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

# Q1 — over/under the resolved threshold, >= not >
TP="$TQ/over.jsonl";  rec r1 claude-opus-5 9000 250000 1000 500 > "$TP"      # 260000
check "Q1 over" "$(run_as_claude "$(path "$TP")")" "143"   # 260000 >= claude-opus-5's 200000
TP="$TQ/under.jsonl"; rec r1 claude-opus-5 9000 100000 1000 500 > "$TP"      # 110000
check "Q1 under" "$(run_as_claude "$(path "$TP")")" "0"    # 110000 < 200000
TP="$TQ/exact.jsonl"; rec r1 claude-opus-5 9000 190000 1000 500 > "$TP"      # exactly 200000
check "Q1 exact" "$(run_as_claude "$(path "$TP")")" "143"  # total == threshold restarts too
# Q1 PASS — over = 143, under = 0, exact = 143.

# Q2 — latest record wins (both orders), usage.iterations[] is not double-counted
TP="$TQ/two-a.jsonl"; { rec r1 claude-opus-5 9000 250000 1000 500; echo; rec r2 claude-opus-5 9000 100000 1000 500; } > "$TP"
check "Q2 over-then-under" "$(run_as_claude "$(path "$TP")")" "0"     # the LAST record, 110000, wins
TP="$TQ/two-b.jsonl"; { rec r1 claude-opus-5 9000 100000 1000 500; echo; rec r2 claude-opus-5 9000 250000 1000 500; } > "$TP"
check "Q2 under-then-over" "$(run_as_claude "$(path "$TP")")" "143"   # the LAST record, 260000, wins
# parent total 110000 (want 0); nested iterations carry 900000s that would flip this to 143 if
# num()'s first-match-per-line stopped matching the parent field instead.
TP="$TQ/iter.jsonl"
printf '{"type":"assistant","requestId":"r1","message":{"model":"claude-opus-5","usage":{"input_tokens":9000,"cache_read_input_tokens":100000,"cache_creation_input_tokens":1000,"output_tokens":500,"iterations":[{"input_tokens":900000,"cache_read_input_tokens":900000,"cache_creation_input_tokens":900000,"output_tokens":900000}]}}}\n' > "$TP"
check "Q2 iterations" "$(run_as_claude "$(path "$TP")")" "0"          # parent total only, nested iterations ignored
# Q2 PASS — over-then-under = 0, under-then-over = 143, iterations = 0.

# Q3 — each matching rule
# [1m] resolves 200000 through the table's FIRST row, whatever the family (here: none of the 4).
TP="$TQ/marker.jsonl"; rec r1 "claude-opus-4-8[1m]" 9000 250000 1000 500 > "$TP"
check "Q3 marker" "$(run_as_claude "$(path "$TP")")" "143"

# bare family ids -> 200000
for fam in claude-opus-5 claude-sonnet-5 claude-fable-5 claude-mythos-5; do
  TP="$TQ/fam-$fam.jsonl"; rec r1 "$fam" 9000 250000 1000 500 > "$TP"
  check "Q3 bare $fam" "$(run_as_claude "$(path "$TP")")" "143"
done

# version/date suffix keeps the family row, prefixed too (unanchored pattern)
for id in claude-fable-5-20260115-v1:0 us.anthropic.claude-fable-5-20260115-v1:0; do
  TP="$TQ/ver-$(printf '%s' "$id" | tr -c 'A-Za-z0-9' -).jsonl"; rec r1 "$id" 9000 250000 1000 500 > "$TP"
  check "Q3 versioned $id" "$(run_as_claude "$(path "$TP")")" "143"
done

# a WORD suffix ("-mini") is a different tier, not the family row: falls to the 160000 default.
# Pinned at a total BETWEEN 160000 and 200000 — a broken ENVIRON hand-off (-v instead) would
# corrupt \[1m\] into the character class [1m], matching the bare "m" in "mini" and wrongly
# resolving this to the marker's 200000, flipping this from 143 to 0.
TP="$TQ/mini.jsonl"; rec r1 claude-fable-5-mini 9000 170000 1000 500 > "$TP"   # 180000
check "Q3 fable-5-mini" "$(run_as_claude "$(path "$TP")")" "143"   # default 160000, not the marker's 200000
TP="$TQ/haiku.jsonl"; rec r1 claude-haiku-4-5 9000 250000 1000 500 > "$TP"     # 260000
check "Q3 haiku-4-5" "$(run_as_claude "$(path "$TP")")" "143"      # default, unlisted family

# no Opus 4.x / Sonnet 4.x row: bare vs [1m]-marked differ, both at the SAME between-value total
# so the two thresholds (160000 default vs 200000 marker) are distinguishable.
TP="$TQ/opus48-bare.jsonl";   rec r1 claude-opus-4-8        9000 170000 1000 500 > "$TP"   # 180000
check "Q3 opus-4-8 bare" "$(run_as_claude "$(path "$TP")")" "143"    # default 160000, no Opus 4.x row
TP="$TQ/opus48-marked.jsonl"; rec r1 "claude-opus-4-8[1m]"   9000 170000 1000 500 > "$TP"   # 180000
check "Q3 opus-4-8 marked" "$(run_as_claude "$(path "$TP")")" "0"    # 180000 < the marker's 200000
# Q3 PASS — every check above reports its want value.

# Q4 — the table ships exactly five rows
N=$(sed -n "/^CONTEXT_THRESHOLDS='\$/,/^'\$/p" "$REAL_SCRIPT" | sed '1d;$d' | grep -c .)
check "Q4 row count" "$N" "5"   # marker + fable-5 + mythos-5 + opus-5 + sonnet-5
# Q4 PASS — row count = 5.

# Q5 — row order decides between two rows that both match
# a genuinely overlapping second row: claude-fable-5-2026 matches the versioned id used in
# Q3, so ABOVE the family row it wins (160000), BELOW it the family row (200000) still wins
# first — edited on a COPY of the emitted hook, never on kaizero.sh or via a runtime override.
sed '/claude-fable-5(/i\
  claude-fable-5-2026                                   160000' "$HOOK" > "$TQ/hook-above.sh"
sed '/claude-fable-5(/a\
  claude-fable-5-2026                                   160000' "$HOOK" > "$TQ/hook-below.sh"
TP="$TQ/order.jsonl"; rec r1 claude-fable-5-20260115-v1:0 9000 170000 1000 500 > "$TP"   # 180000
check "Q5 row above" "$(run_hook "$TQ/hook-above.sh" "$(path "$TP")")" "143"   # the inserted 160000 row wins
check "Q5 row below" "$(run_hook "$TQ/hook-below.sh" "$(path "$TP")")" "0"     # the family row, 200000, is still first
# Q5 PASS — row above = 143, row below = 0.

# Q6 — the marker row resolves THROUGH the table, not a hardcoded branch
# only the marker row's line (the one literal \[1m\]) has its 200000 rewritten to 300000 —
# every other row also reads "200000" so the sed address must anchor on the marker text itself.
sed '/\\\[1m\\\]/s/200000/300000/' "$HOOK" > "$TQ/hook-marker-edit.sh"
TP="$TQ/marker-edit.jsonl"; rec r1 "claude-opus-4-8[1m]" 9000 250000 1000 500 > "$TP"   # 260000
check "Q6 unedited table" "$(run_as_claude "$(path "$TP")")" "143"   # unedited marker row is 200000
check "Q6 edited marker" "$(run_hook "$TQ/hook-marker-edit.sh" "$(path "$TP")")" "0"    # edited marker row is 300000
# Q6 PASS — unedited table = 143, edited marker = 0.

# Q PASS — Q1 through Q6 all report PASS. Together with M4's marker set/marker unset cases
# (this scenario runs everything with the marker unset, where the guard is the only kill path)
# they prove the guard sits above the hook's turn-end branch and fires without it.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
