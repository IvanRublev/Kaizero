#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=235s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCENARIO_DIR/test-setup.sh"

# G-001-token-accounting — token accounting.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/G-001-token-accounting
# Wall-clock budget: its longest Run command is `timeout 90` — allow that command at least 90s
#
# The token figures come from the session transcripts the Stop hook records, so a stub claude
# that fabricates a transcript and then fires the real hook exercises the whole path with no API
# calls and no real claude. MAX_LOOPS=3 is deliberate: the report prints between runs (the
# MAX_LOOPS break comes before it), so three runs give two reports — the second proves figures
# accumulate across a context restart. Covers what a naive summer gets wrong: one API request
# writes one transcript line per content block, all repeating the same usage, and each usage
# repeats all four field names inside iterations[] plus the cache_creation ephemeral leaves that
# already sum into the parent.

TG="$TESTROOT/G-001-token-accounting"; mkdir -p "$TG/repo" "$TG/bin" "$TG/tx"
cat > "$TG/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
# stub claude: no API calls. Fabricates ONE session transcript per run, then fires the real
# Stop hook (path pulled out of the --settings JSON kaizero passed us) with the payload
# shape claude sends, so transcript_path recording is exercised for real.
n=$(( $(cat "$TG_TX/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$TG_TX/count"
t="$TG_TX/t$n.jsonl"
case "${TG_MODE:-ok}" in
  missing) : ;;                                              # record a path with no file
  bad)     printf '{"message":{"usage":{"outp\n' > "$t" ;;   # truncated / invalid JSON
  *) if [ "$n" = 1 ]; then
       # req_A on 3 content-block lines with IDENTICAL usage (must count once), each carrying
       # the usage.iterations[] copy and the cache_creation ephemeral leaves (148+100 = 248).
       u='"input_tokens":10,"cache_creation_input_tokens":248,"cache_read_input_tokens":1000,"output_tokens":20,"cache_creation":{"ephemeral_5m_input_tokens":148,"ephemeral_1h_input_tokens":100},"iterations":[{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":1000,"cache_creation_input_tokens":248}]'
       for i in 1 2 3; do printf '{"requestId":"req_A","type":"assistant","message":{"usage":{%s}}}\n' "$u"; done > "$t"
       printf '{"requestId":"req_B","type":"assistant","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":500,"output_tokens":7}}}\n' >> "$t"
     else
       printf '{"requestId":"req_C","type":"assistant","message":{"usage":{"input_tokens":100,"cache_creation_input_tokens":300,"cache_read_input_tokens":400,"output_tokens":200}}}\n' > "$t"
     fi ;;
esac
hook=""
for a in "$@"; do case "$a" in *compact-exit-hook.sh*) hook="$(printf '%s' "$a" | sed -n 's/.*"command":"\([^"]*\)".*/\1/p')";; esac; done
[ -n "$hook" ] && printf '{"session_id":"stub%s","transcript_path":"%s"}' "$n" "$t" | "$hook"
exit 0
EOF
chmod +x "$TG/bin/claude"
cd "$TG/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] G1 x\n' > todo.md; git add -A; git commit -qm init
# $1 = stub mode, $2 = log file. Fresh transcript dir per run.
# BUG 057: no decoy needed any more — the stub below IS the real claude session kaizero.sh
# launched, with KAIZERO_SESSION_RECORD/KAIZERO_SESSION_EPOCH already naming its own
# launch in its own env, inherited unchanged by the real compact-exit-hook.sh it pipes into.
# term_owner validates and really SIGTERMs it (via the descendant sweep off the recorded pid),
# so kaizero.sh's own wait sees it end, restarts it for real, and blocks synchronously
# through all three loops to its own closing report — no detached run or log-polling needed either.
grun() { zap "$TG/tx"; mkdir -p "$TG/tx"; : > "$2"
  PATH="$TG/bin:$PATH" TG_TX="$TG/tx" TG_MODE="$1" timeout 90 env KAIZERO_MAX_LOOPS=3 bash "$SCRIPT" --local-merge todo.md -t x > "$2" 2>&1 || true; }

# G1.1 — dedupe, no double-count, accumulation across restarts
cd "$TG/repo"
grun ok "$TG/ok.log"
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
inst="$(sed -n 's/.*Execution stats (instance \([A-Za-z0-9]*\) \. .*/\1/p' "$TG/ok.log" | head -1)"
# a report between runs 1|2 and 2|3, plus the closing one
check "G1.1 heading" "$(grep -c 'Execution stats' "$TG/ok.log")" "3"
strip_box(){ sed -E 's/^\| ?//; s/ *\|$//'; }
report1="$(grep -A1 'Tokens:' "$TG/ok.log" | sed -n '1,2p' | strip_box | tr '\n' '|')"
report2="$(grep -A1 'Tokens:' "$TG/ok.log" | sed -n '4,5p' | strip_box | tr '\n' '|')"
# req_A's three identical lines counted once (10+5 in, 20+7 out), iterations[] not added on top,
# cache write is 248 not 496 (leaves not added to parent). Total 15+27+248+1500 = 1790 -> 1.7k
check "G1.1 report 1" "$report1" "Tokens: 1.7k Total|In 15 . Out 27 . Cache write 248 . Cache read 1.5k|"
# run 2's transcript added to run 1's, not replacing it (2790 -> 2.7k)
check "G1.1 report 2" "$report2" "Tokens: 2.7k Total|In 115 . Out 227 . Cache write 548 . Cache read 1.9k|"
# the transcript list is namespaced transcripts-main-<instance>, so parallel instances can never
# read each other's figures
check "G1.1 per-instance" "$([ -f "$GC/transcripts-main-$inst" ] && echo yes || echo NO)" "yes"
# G1.1 PASS — heading = 3, and the first two reports match exactly (see comments above).

# G1.2 — degradation: never lie, never fail the run
cd "$TG/repo"
grun missing "$TG/missing.log"; grun bad "$TG/bad.log"
# one per report, plus the fleet TOTAL
check "G1.2 missing file" "$(grep -c 'Tokens: n/a' "$TG/missing.log")" "4"
check "G1.2 invalid json" "$(grep -c 'Tokens: n/a' "$TG/bad.log")" "4"
# one per report; TOTAL omits the row, summed wall times are not a duration
check "G1.2 timing kept" "$(grep -c 'Kaizero run loop:' "$TG/bad.log")" "3"
# G1.2 PASS — both runs print Tokens: n/a in every report and in the fleet TOTAL, and still
# print the timing rows: a deleted transcript or a truncated/invalid line degrades to n/a and
# the run completes normally instead of printing a wrong number.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
