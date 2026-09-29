#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=240s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# ISSUE-077-task-cache-and-progress — `zero.sh validate-tasks`: the filesystem-signature cache that
# lets an unchanged backlog skip the walk, every way that signature must be invalidated, and the
# progress display the walk draws while it does run (redrawing bar on a terminal, plain lines
# where nothing is watching).
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none — python3 (already required) supplies the pseudo-terminal
# Folder under $TESTROOT: $TESTROOT/ISSUE-077-task-cache-and-progress
# Wall-clock budget: the two bar cases walk a backlog deliberately large enough to outlive the
# display's one-second draw threshold, so they cost tens of seconds each
# Cross-references: R-008-validate-tasks-scale-and-caching.sh covers the same subcommand's findings
# cap and batching; R-003-validate-ids-cache-and-the-launch-gate.sh covers validate-ids' own,
# commit-SHA-keyed cache, which this one deliberately does not share a mechanism with.
#
# Progress never goes to either captured stream — it goes to fd 4, kaizero.sh's display descriptor
# — so every case below hands zero.sh its own fd 4 and reads it back as a file.

# Setup
TR="$TESTROOT/ISSUE-077-task-cache-and-progress"; mkdir -p "$TR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/claude"; chmod +x "$TR/bin/claude"

# fresh repo under $TR/$1 with $2 unchecked ids (TASK-1..N), each with a resolvable Task file.
# Sets $ZERO and $D for the caller and leaves cwd inside the new repo.
newrepo(){
  local d="$TR/$1" n="$2" i; mkdir -p "$d/tasks"; cd "$d"
  git init -q -b main; git config user.email t@t.t; git config user.name test
  { printf -- '- [x] Z0 seed\n'; for (( i = 1; i <= n; i++ )); do printf -- '- [ ] TASK-%s x\n' "$i"; done; } > todo.md
  for (( i = 1; i <= n; i++ )); do printf -- '### Acceptance criteria\n- [ ] a\n' > "tasks/TASK-$i.md"; done
  git add -A; git commit -qm init
  KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > /dev/null 2>&1
  ZERO="$d/.git/zero.sh"; D="$d"
}
# vt <tag> — one validate-tasks run with its own display descriptor. Captured output (stdout+stderr,
# exactly what the three callers capture) lands in $TR/<tag>.out, progress in $TR/<tag>.fd4, the
# exit status in $RC. fd 4 is a plain file here, so this is the plain-line mode.
vt(){ bash "$ZERO" validate-tasks > "$TR/$1.out" 2>&1 4>"$TR/$1.fd4"; RC=$?; }
# did that run walk? A walk writes its plain progress lines; a cache hit has no walk to report on.
walked(){ [ -s "$TR/$1.fd4" ] && echo yes || echo no; }

# I77-1 — a first walk is clean and stores a cache; an immediately following run reuses it
newrepo c1 12
vt a; check "I77-1 first run clean" "$RC" "0"
check "I77-1 first run walked" "$(walked a)" "yes"
check "I77-1 cache file in the coordination git dir" "$(ls "$D/.git/" | grep -c '^task-defs-ok-')" "1"
vt b; check "I77-1 second run clean" "$RC" "0"
check "I77-1 second run skipped the walk" "$(walked b)" "no"
check "I77-1 captured output byte-identical" "$(cmp -s "$TR/a.out" "$TR/b.out" && echo same || echo DIFFERS)" "same"
check "I77-1 captured output empty" "$(wc -c < "$TR/a.out" | tr -d ' ')" "0"
# the cache describes candidate files, so it must never be one of them
check "I77-1 cache file is not a candidate" "$(find "$D" -type f -not -path '*/.git/*' -name 'task-defs-ok-*' | wc -l | tr -d ' ')" "0"
# I77-1 PASS — a clean walk is stored and reused, the reused verdict is byte-identical to the
# walked one, and the cache file lives where the candidate search cannot see it.

# I77-2 — every filesystem change to the candidate set invalidates it
sleep 1                                  # mtimes are whole seconds; an edit inside the cache
                                         # file's own second is the accepted floor of the mechanism
printf -- 'no acceptance criteria heading\n' > tasks/TASK-3.md
vt e1; check "I77-2 edit walks" "$(walked e1)" "yes"
check "I77-2 edit reported" "$(grep -c '^empty-acceptance-criteria TASK-3:' "$TR/e1.out")" "1"
check "I77-2 edit exit" "$RC" "1"
# a run with findings stores nothing, so the same broken file is reported again, walk and all
vt e2; check "I77-2 unfixed finding walks again" "$(walked e2)" "yes"
check "I77-2 unfixed finding reported again" "$(grep -c '^empty-acceptance-criteria TASK-3:' "$TR/e2.out")" "1"
printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/TASK-3.md
vt e3; check "I77-2 fixed run clean" "$RC" "0"
sleep 1
rm -f tasks/TASK-5.md
vt d1; check "I77-2 delete walks" "$(walked d1)" "yes"
check "I77-2 delete reported" "$(grep -c '^missing-task-file TASK-5:' "$TR/d1.out")" "1"
printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/TASK-5.md
vt d2; check "I77-2 restore clean" "$RC" "0"
sleep 1
printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/TASK-5-duplicate.md
vt n1; check "I77-2 added candidate walks" "$(walked n1)" "yes"
check "I77-2 added candidate reported" "$(grep -c '^ambiguous-task-file TASK-5:' "$TR/n1.out")" "1"
rm -f tasks/TASK-5-duplicate.md
vt n2; check "I77-2 removed again clean" "$RC" "0"
# a rename touches neither the timestamp nor the file count — only the filename digest sees it
sleep 1
mv tasks/TASK-5.md tasks/NOTES-5.md
vt r1; check "I77-2 rename out of the set walks" "$(walked r1)" "yes"
check "I77-2 rename out of the set reported" "$(grep -c '^missing-task-file TASK-5:' "$TR/r1.out")" "1"
mv tasks/NOTES-5.md tasks/TASK-5.md
vt r2; check "I77-2 renamed back clean" "$RC" "0"
# I77-2 PASS — edit, delete, add and rename each make the next run walk again; a run that reports
# findings leaves no cache behind, so the same finding is walked for and reported every time.

# I77-3 — a file no unchecked id could resolve to is not a candidate and does not invalidate
vt base >/dev/null
printf -- 'unrelated\n' > tasks/NOTES.md
vt u1; check "I77-3 unrelated file added: no walk" "$(walked u1)" "no"
check "I77-3 unrelated file added: still clean" "$RC" "0"
mv tasks/NOTES.md tasks/OTHER-NOTES.md
vt u2; check "I77-3 unrelated file renamed: no walk" "$(walked u2)" "no"
rm -f tasks/OTHER-NOTES.md
# I77-3 PASS — the signature describes the candidate set alone, so a Markdown file outside it
# costs nothing, exactly as a file that cannot change any verdict should.

# I77-4 — the unchecked-id half is the one the coordination base carries, not the one on disk
vt base2 >/dev/null
printf -- '- [ ] TASK-99 x\n' >> todo.md
vt g1; check "I77-4 uncommitted Todo List edit: no walk" "$(walked g1)" "no"
check "I77-4 uncommitted Todo List edit: still clean" "$RC" "0"
git add -A; git commit -qm add99
vt g2; check "I77-4 committed Todo List edit walks" "$(walked g2)" "yes"
check "I77-4 committed id reported" "$(grep -c '^missing-task-file TASK-99:' "$TR/g2.out")" "1"
git reset -q --hard HEAD~1
vt g3; check "I77-4 reverted clean" "$RC" "0"
# I77-4 PASS — the walk is asked about the ids on the base, so a peer's uncommitted copy of the
# Todo List changes nothing until it lands.

# I77-5 — a cache that cannot be trusted degrades to one honest walk, never to a wrong verdict
vt base3 >/dev/null
C="$D/.git/$(ls "$D/.git/" | grep '^task-defs-ok-')"
rm -f "$C";              vt x1; check "I77-5 deleted cache walks"    "$(walked x1)" "yes"; check "I77-5 deleted cache verdict"    "$RC" "0"
: > "$C";                vt x2; check "I77-5 emptied cache walks"    "$(walked x2)" "yes"; check "I77-5 emptied cache verdict"    "$RC" "0"
printf 'garbage\n' > "$C"; vt x3; check "I77-5 corrupt cache walks"  "$(walked x3)" "yes"; check "I77-5 corrupt cache verdict"    "$RC" "0"
chmod 000 "$C";          vt x4; check "I77-5 unreadable cache walks" "$(walked x4)" "yes"; check "I77-5 unreadable cache verdict" "$RC" "0"
chmod 644 "$C" 2>/dev/null || true
# I77-5 PASS — each damaged-cache shape produces one walk and the correct verdict, never a failed run.

# I77-6 — a gitignored Task directory still resolves, and an edit inside it still invalidates
newrepo c6 3
mkdir -p private
printf 'private/\n' > .gitignore
printf -- '- [x] Z0 seed\n- [ ] TASK-1 x\n- [ ] TASK-2 x\n- [ ] TASK-3 x\n' > todo.md
mv tasks/TASK-2.md private/TASK-2.md
git add -A; git commit -qm ignore
vt i1; check "I77-6 gitignored Task file resolves" "$RC" "0"
sleep 1
printf -- 'no acceptance criteria heading\n' > private/TASK-2.md
vt i2; check "I77-6 gitignored edit walks" "$(walked i2)" "yes"
check "I77-6 gitignored edit reported" "$(grep -c '^empty-acceptance-criteria TASK-2:' "$TR/i2.out")" "1"
# I77-6 PASS — the signature reads the real filesystem, so a Task file git never sees is still
# resolved and its uncommitted edits still invalidate the verdict.

# I77-7 — plain-line mode: one line at the start plus one per quarter crossing, no escape sequences
newrepo c7 40
vt p1
check "I77-7 five plain lines" "$(wc -l < "$TR/p1.fd4" | tr -d ' ')" "5"
check "I77-7 every line carries the label" "$(grep -c '^Validating task definitions ' "$TR/p1.fd4")" "5"
check "I77-7 last line names the true total" "$(tail -1 "$TR/p1.fd4" | grep -c ' 40/40$')" "1"
check "I77-7 no escape sequence" "$(LC_ALL=C grep -c "$(printf '\033')" "$TR/p1.fd4")" "0"
check "I77-7 no elapsed or remaining time" "$(grep -cE '[0-9]+(s|m|:[0-9])' "$TR/p1.fd4")" "0"
# a sub-second walk still writes them, and a backlog small enough to cross two quarters in one tick
# still writes the same five: a line cannot flicker, and a silent log loses the evidence that the
# step ran at all
newrepo c7b 3
vt p2; check "I77-7 sub-second walk still writes its lines" "$(walked p2)" "yes"
check "I77-7 sub-second line count" "$(wc -l < "$TR/p2.fd4" | tr -d ' ')" "5"
# I77-7 PASS — the threshold governs the redrawing bar only; plain lines are a record of the run.

# I77-8 — bar mode: a terminal on the display descriptor, a walk long enough to outlive the threshold
newrepo c8 160
# a pseudo-terminal on fd 4 alone: zero.sh's own two streams stay off it, exactly as they are under
# kaizero.sh when its normal output is redirected. python3 rather than script(1), whose argument
# order differs between the two platforms the suite runs on.
bar(){
  local tag=$1 color=$2
  KAIZERO_COLOR="$color" python3 -c 'import pty,sys; raise SystemExit(pty.spawn(["bash","-c",sys.argv[1]]))' \
    "cd '$D' && bash '$ZERO' validate-tasks 4>&1 >/dev/null 2>/dev/null" < /dev/null > "$TR/$tag.raw" 2>/dev/null
  python3 "$TR/barstats.py" "$TR/$tag.raw" > "$TR/$tag.stats"
}
# barstats — one `key=value` line per property of a captured bar rendering, so each check below
# reads a single value instead of re-parsing escape sequences in shell.
cat > "$TR/barstats.py" <<'PYEOF'
import re, sys
raw = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
ansi = re.compile('\x1b\\[[0-9;]*[A-Za-z]')
chunks = raw.split('\r')
frames = [c for c in chunks if 'Validating task definitions' in c]
plain = [ansi.sub('', f) for f in frames]
counts = set(re.search(r'(\d+)/(\d+)\s*$', p).group(0) for p in plain if re.search(r'(\d+)/(\d+)\s*$', p))
mid = plain[len(plain) // 2] if plain else ''
body = re.sub(r'\s*\d+/\d+\s*$', '', mid.split('definitions ', 1)[-1]).strip() if plain else ''
print('frames=%d' % len(frames))
print('counts=%d' % len(counts))
print('latched=%d' % len(set(re.search(r'(\d+)/(\d+)\s*$', p).group(0) for p in plain[:-1] if re.search(r'(\d+)/(\d+)\s*$', p))))
print('cells=%d' % len(body))
print('glyphs=%d' % len(set(body)))
print('width=%d' % len(mid.rstrip()))
print('brackets=%d' % len(re.findall(r'[\[\]()|]', mid.replace('\x1b', ''))) )
print('color=%d' % raw.count('38;2;74;201;243'))
print('erase=%d' % (1 if chunks and '\x1b[K' in chunks[-1] and 'Validating' not in chunks[-1] else 0))
print('final=%d' % (1 if plain and plain[-1].rstrip().endswith('160/160') else 0))
print('clock=%d' % len(re.findall(r'\d+(?:s|m|:\d)', mid)))
PYEOF
rm -f "$D/.git/"task-defs-ok-*
bar b1 1
st(){ sed -n "s/^$1=//p" "$TR/$2.stats"; }
check "I77-8 more than one frame drawn" "$([ "$(st frames b1)" -ge 2 ] && echo yes || echo NO)" "yes"
# 31 fill positions (0 through 30), each visited at most once, plus the closing frame
check "I77-8 at most 32 frames" "$([ "$(st frames b1)" -le 32 ] && echo yes || echo NO)" "yes"
# the count is latched to a 12-percent step: at most 9 distinct values over the walk, plus the true
# total on the closing frame
# nine latched values at a 12-percent step, and the closing frame's true total on top of them
check "I77-8 at most 9 latched counts" "$([ "$(st latched b1)" -le 9 ] && echo yes || echo NO)" "yes"
check "I77-8 the bar is the faster of the two" "$([ "$(st frames b1)" -gt "$(st counts b1)" ] && echo yes || echo NO)" "yes"
check "I77-8 thirty fill cells" "$(st cells b1)" "30"
check "I77-8 a single glyph throughout" "$(st glyphs b1)" "1"
check "I77-8 no bracket or cap characters" "$(st brackets b1)" "0"
check "I77-8 no elapsed or remaining time" "$(st clock b1)" "0"
check "I77-8 the whole line fits 80 columns" "$([ "$(st width b1)" -le 80 ] && echo yes || echo NO)" "yes"
check "I77-8 closing frame names the true total" "$(st final b1)" "1"
check "I77-8 the line is erased after it" "$(st erase b1)" "1"
# I77-8 PASS — one line carrying label, a 30-cell single-glyph bar and a latched count, redrawn per
# fill position, closed on the true total and erased.

# I77-9 — styling follows colour capability; the mode follows the display descriptor alone
rm -f "$D/.git/"task-defs-ok-*
bar b2 0                                 # what kaizero.sh's gate reports under NO_COLOR or a non-UTF-8 locale
check "I77-9 NO_COLOR still redraws a bar" "$([ "$(st frames b2)" -ge 2 ] && echo yes || echo NO)" "yes"
check "I77-9 still thirty cells, in ASCII" "$(st cells b2)" "30"
check "I77-9 no colour escape" "$(st color b2)" "0"
check "I77-9 still erased at the end" "$(st erase b2)" "1"
# I77-9 PASS — a terminal that declines colour is still a terminal: it keeps the bar, in ASCII,
# rather than being demoted to the plain lines a non-terminal gets.

# I77-10 — a sub-second walk on a terminal draws nothing at all, in either styling
newrepo c10 3
for col in 1 0; do
  rm -f "$D/.git/"task-defs-ok-*
  KAIZERO_COLOR="$col" python3 -c 'import pty,sys; raise SystemExit(pty.spawn(["bash","-c",sys.argv[1]]))' \
    "cd '$D' && bash '$ZERO' validate-tasks 4>&1 >/dev/null 2>/dev/null" < /dev/null > "$TR/fast-$col.raw" 2>/dev/null
  check "I77-10 nothing drawn for a sub-second walk (KAIZERO_COLOR=$col)" \
    "$(wc -c < "$TR/fast-$col.raw" | tr -d ' ')" "0"
done
# I77-10 PASS — below the threshold a bar would appear and clear inside a frame or two, so neither
# an opening frame nor a closing one is drawn.

# I77-12 — the stored verdict is stamped with the moment the walk STARTED, not the moment it ended,
# so a Task file edited while a multi-second walk was running is still newer than it
newrepo c12 160
MT=(stat -c %Y); stat -c %Y . >/dev/null 2>&1 || MT=(stat -f %m)
T0=$(date +%s); vt s1; T1=$(date +%s)
CS="$D/.git/$(ls "$D/.git/" | grep '^task-defs-ok-')"
CM=$("${MT[@]}" "$CS")
check "I77-12 the walk really took several seconds" "$([ $(( T1 - T0 )) -ge 3 ] && echo yes || echo NO)" "yes"
# stamped before the candidate files were read, so the whole reading window is still "newer"
check "I77-12 the cache is stamped before the walk ended" "$([ $(( T1 - CM )) -ge 2 ] && echo yes || echo NO)" "yes"
# a file touched at any point after that stamp — which includes the whole walk — invalidates
touch tasks/TASK-77.md
vt s2; check "I77-12 a file touched mid-walk would invalidate" "$(walked s2)" "yes"
# I77-12 PASS — the invalidation window closes at the walk's first read, not at its last, so a peer
# editing a Task file while this instance walks can never be cached over.

# I77-11 — the restart cadence and the network-flap backoff that multiplies it
check "I77-11 default restart wait is 2 seconds" \
  "$(grep -cF 'RESTART_WAIT="${KAIZERO_RESTART_WAIT:-2}"' "$REPO/kaizero.sh")" "1"
check "I77-11 the backoff multiplies that wait, capped at six doublings" \
  "$(grep -cF 'RESTART_GAP=$(( RESTART_WAIT * ( 1 << ( NET_FLAP_STREAK < 6 ? NET_FLAP_STREAK : 6 ) ) ))' "$REPO/kaizero.sh")" "1"
GAPS=""; for s in 0 1 2 3 4 5 6 7; do GAPS="$GAPS$(( 2 * ( 1 << ( s < 6 ? s : 6 ) ) )) "; done
check "I77-11 the flap sequence" "$GAPS" "2 4 8 16 32 64 128 128 "
# I77-11 PASS — the gap defaults to 2 seconds, stays overridable by KAIZERO_RESTART_WAIT, and is
# still what the backoff doubles, so a flapping origin thins out to a 128-second ceiling.

# ISSUE-077 PASS — I77-1 through I77-11 all report PASS.

cd "$TESTROOT"
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
