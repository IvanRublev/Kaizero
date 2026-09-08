#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=910s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCENARIO_DIR/test-setup.sh"

# H-001-session-display-name — claude session display name. --name carries "(<id>) <nickname> ·
# <activity>" as one argv element, stable across restarts, unique among live peers, and freed
# again on exit or crash.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/H-001-session-display-name
# Wall-clock budget: its longest Run command is `timeout 90` — allow that command at least 90s
#
# Each instance names its claude session (<instance id>) <nickname> · <student activity> via
# --name, so parallel terminals are told apart without reading hex. The name must reach claude
# as ONE argv element, and must be the SAME on every context restart (the id and the activity
# are derived from the id; the nickname is picked once at launch and stored on the liveness
# marker). The nickname must differ from every peer live in this repo. The stub claude echoes
# its argv, so no real claude is needed.

TH="$TESTROOT/H-001-session-display-name"; mkdir -p "$TH/repo" "$TH/bin"
cat > "$TH/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
printf 'ARGV:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'
exit 0
EOF
chmod +x "$TH/bin/claude"
cd "$TH/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] H1 x\n' > todo.md; git add -A; git commit -qm init
# the ten activities, verbatim (kaizero.sh dojo_student)
ACT=('drilling the fork-implement-merge kata' 'hauling snow buckets uphill' \
     'claiming a track before stepping on it' 'reading the whole Task before striking' \
     'starting over on fresh snow' 'carving checkbox after checkbox into ice' 'hunting the next box on the list' \
     'practicing one clean strike per Task' "leaving a peer's branch untouched" \
     'walking back to the merge gate')
# claude's own output goes to fd 4, which falls back to stdout only when stdin is not a terminal
# — run with stdin off the tty so the stub's ARGV line lands in the capture file.
notty() { "$@" < /dev/null; }
# the fifteen nicknames, verbatim (kaizero.sh pick_nickname)
NICKS=(ash bob cleo dax elk finn gus hana ivo jun kit lux moss nix opal)
GCH="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
# a fabricated LIVE peer holding nickname $1 (pid/start of this shell, so liveness keeps it)
mkpeer() { mkdir -p "$GCH/instance"
  printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ | awk '{$1=$1;print}')" "$1" > "$GCH/instance/fake-$2"; }
nick_of() { sed -E 's/.*\) (.*) · .*/\1/'; }   # nickname out of a `[--name] [...]` line

# H1 — name construction, unsplit argv, restart stability
cd "$TH/repo"
notty env PATH="$TH/bin:$PATH" KAIZERO_MAX_LOOPS=3 \
  timeout 90 bash "$SCRIPT" --local-merge todo.md -t x > "$TH/run.log" 2>&1 || true
ID=$(grep -m1 -oE 'instance [0-9A-Za-z]+' "$TH/run.log" | awk '{print $2}')
NICK=$(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/run.log" | nick_of)
WANT="($ID) $NICK · ${ACT[$(( 16#${ID:0:2} % 10 ))]}"
echo "computed H1 want name : $WANT"
# the pty (script -q) prepends a stray EOF control byte to the line following its own detach,
# with no guaranteed newline before it — a legitimate pty artifact, not a kaizero.sh defect —
# so anchoring on ^ARGV: can miss a real launch; ARGV: unanchored is exact enough (claude's stub
# only ever emits it at the start of its own line).
check "H1 launches" "$(grep -c 'ARGV:' "$TH/run.log")" "3"
check "H1 named+unsplit" "$(grep -c -F -- "[--name] [$WANT]" "$TH/run.log")" "3"
check "H1 nick in list" "$(printf '%s\n' "${NICKS[@]}" | grep -qxF "$NICK" && echo yes || echo NO)" "yes"
check "H1 header nick" "$(grep -qF "Execution stats (instance $ID . $NICK)" "$TH/run.log" && echo yes || echo NO)" "yes"
# marker gone on exit
check "H1 name released" "$(ls "$GCH/instance" 2>/dev/null | wc -l | tr -d ' ')" "0"
# H1 PASS — launches = 3 and named+unsplit = 3: --name carries the parenthesised,
# space-containing name as a single argv element, the activity is the one the id selects by
# 16#<first two chars> % 10, the nickname sits between id and activity, and all three restarts
# used the same name. nick in list = yes (one of the fifteen, lowercase), header nick = yes —
# the execution-stats header reads (instance <id> · <nick>) with the same nickname the session
# name carries, so a report and a terminal title can be matched by word — and name released = 0
# — the exiting instance unlinked its marker, so its nickname is free again.

# H2 — a decimal ($$-shaped) id picks an activity, not an error
# the $$ fallback id is decimal digits — valid hex, so the same derivation applies with no
# branch. Drive the real function on such an id.
eval "$(sed -n '/^dojo_student()/,/^}/p' "$REAL_SCRIPT")"
h2a="$(dojo_student 48584)"; h2b="$(dojo_student 90210)"
echo "computed H2 activities : '$h2a' '$h2b'"
check "H2 decimal id (both non-empty, no error)" "$([ -n "$h2a" ] && [ -n "$h2b" ] && echo yes || echo NO)" "yes"
# only the first two chars select
check "H2 deterministic" "$([ "$(dojo_student a1b2c3d4)" = "$(dojo_student a1ffffff)" ] && echo yes || echo NO)" "yes"
# 16#a1 % 10 = 1, 16#b2 % 10 = 8
check "H2 a1 vs b2" "$([ "$(dojo_student a1b2c3d4)" != "$(dojo_student b2b2c3d4)" ] && echo differ || echo same)" "differ"
# H2 PASS — both decimal ids render an activity with no arithmetic error, deterministic = yes
# (only the first two chars select), and a1 vs b2 = differ.

# H3 — two instances launched at the same moment draw different nicknames
cd "$TH/repo"; zap "$GCH/instance"
notty env PATH="$TH/bin:$PATH" KAIZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" --local-merge todo.md -t x > "$TH/a.log" 2>&1 &
notty env PATH="$TH/bin:$PATH" KAIZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" --local-merge todo.md -t x > "$TH/b.log" 2>&1 &
wait
NA=$(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/a.log" | nick_of)
NB=$(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/b.log" | nick_of)
echo "computed H3 nicks : '$NA' '$NB'"
check "H3 differ" "$([ -n "$NA" ] && [ "$NA" != "$NB" ] && echo yes || echo NO)" "yes"
# H3 PASS — differ = yes: the scan-then-claim ran under instance.lock, so the second instance
# saw the first's line 3 and picked another word.

# H4 — the free set is what the live markers leave; suffix past fifteen; a crashed peer frees its name
cd "$TH/repo"
zap "$GCH/instance" && { i=0; for n in "${NICKS[@]}"; do [ "$n" = moss ] || mkpeer "$n" $((i++)); done; }
notty env PATH="$TH/bin:$PATH" KAIZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" --local-merge todo.md -t x > "$TH/c.log" 2>&1 || true
check "H4 fourteen held" "$(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/c.log" | nick_of)" "moss"
zap "$GCH/instance" && { i=0; for n in "${NICKS[@]}"; do mkpeer "$n" $((i++)); done; }
notty env PATH="$TH/bin:$PATH" KAIZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" --local-merge todo.md -t x > "$TH/d.log" 2>&1 || true
d4nick="$(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/d.log" | nick_of)"
check "H4 all fifteen (ascending suffix 1 present)" "$(echo "$d4nick" | grep -qE ' 1$' && echo yes || echo NO)" "yes"
zap "$GCH/instance" && { i=0; for n in "${NICKS[@]}"; do mkpeer "$n" $((i++)); mkpeer "$n 1" $((i++)); done; }
notty env PATH="$TH/bin:$PATH" KAIZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" --local-merge todo.md -t x > "$TH/e.log" 2>&1 || true
e4nick="$(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/e.log" | nick_of)"
check "H4 both levels (ascending suffix 2 present)" "$(echo "$e4nick" | grep -qE ' 2$' && echo yes || echo NO)" "yes"
# crashed peer: a marker whose pid is dead still names moss — the startup GC unlinks it first
zap "$GCH/instance" && mkdir -p "$GCH/instance" && printf '999999\ndead\nmoss\n' > "$GCH/instance/crashed"
i=0; for n in "${NICKS[@]}"; do [ "$n" = moss ] || mkpeer "$n" $((i++)); done
notty env PATH="$TH/bin:$PATH" KAIZERO_MAX_LOOPS=1 timeout 90 bash "$SCRIPT" --local-merge todo.md -t x > "$TH/f.log" 2>&1 || true
check "H4 crashed freed" "$(grep -m1 -oE '\[--name\] \[[^]]*\]' "$TH/f.log" | nick_of)" "moss"
zap "$GCH/instance"
# H4 PASS — fourteen held = moss (the one free word), all fifteen is a "<name> 1" form and both
# levels a "<name> 2" form (ascending suffix, random within the level), and crashed freed = moss
# — the dead peer's marker was GC'd before the pick, so its name came back.

# H5 — degradation: an unreadable registry still names the session
cd "$TH/repo"
eval "$(sed -n '/^pick_nickname()/,/^}/p' "$REAL_SCRIPT")"
h5name="$( ( set -euo pipefail; INSTANCE_DIR="$TH/gone/instance"; INSTANCE_ID=zz; pick_nickname ) )"
h5rc=$?
echo "computed H5 fallback name : '$h5name'"
check "H5 name printed, rc=0" "$([ -n "$h5name" ] && [ "$h5rc" = 0 ] && echo yes || echo NO)" "yes"
# H5 PASS — a name from the full fifteen is printed and rc=0: a missing registry costs
# uniqueness, never the launch. ($TH/gone is never created — nothing is written.)

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
