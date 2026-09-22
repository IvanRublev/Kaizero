#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=260s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# TASK-065-session-log-relay — zero.sh's session_log helper copies the KAIZERO_LINK
# symlink-report lines, the merge/mr landing-success lines, and mr's push/forge-creation
# land-gate failures into KAIZERO_SESSION_LOG (never any other line, never in place of the
# original stderr/stdout); kaizero.sh's own relay_session_log prints back only the NEW bytes,
# icon-prefixed, once per run_loop iteration; and the per-launch log file (KAIZERO_SESSION_LOG /
# kaizero.sh's own SESSION_LOG_FILE) is scoped to one launch and gone once it exits.
# Needs real claude: no — a stub claude, or a driver calling zero.sh directly, stands in
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/TASK-065-session-log-relay

TK="$TESTROOT/TASK-065-session-log-relay"; mkdir -p "$TK/bin" "$TK/stub"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktask(){ mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > "tasks/$1.md"; }
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1"; git config user.email t@t.t; git config user.name test )
}
printf '#!/usr/bin/env bash\nexit 0\n' > "$TK/bin/claude"; chmod +x "$TK/bin/claude"
extract_fn(){ eval "$(sed -n "/^$1() {/,/^}/p" "$2")"; }

# --- Part A: local-merge mode — success line copied, land-gate failure never is ---
mkrepo "$TK/repo"
( cd "$TK/repo"; printf -- '- [ ] A1 x\n- [ ] A2 y\n' > todo.md; mktask A1; mktask A2; git add -A; git commit -qm todo )
( cd "$TK/repo"; KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md >/dev/null 2>&1 || true )
ZA="$TK/repo/.git/zero.sh"
LOGA="$TK/session.log"; : > "$LOGA"
cat > "$TK/adrive.sh" <<'DRIVE'
set -uo pipefail
REC="$TK/a-session"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" "1" > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH="1" KAIZERO_SESSION_LOG="$LOGA"
cd "$TK/repo"
FAILED=0; ERRORED=0
wt=$(bash .git/zero.sh claim A1)
echo change >> "$wt/f"; git -C "$wt" add -A; git -C "$wt" commit -qm "A1 change" >/dev/null
out=$(bash .git/zero.sh merge A1 "$wt" 2>"$TK/a1.err"); rc=$?
check "A1 merge exit" "$rc" "0"
printf '%s' "$out" > "$TK/a1.out"
# A2 — land-gate failure (no diff against base): the failure line must never reach the log
wt2=$(bash .git/zero.sh claim A2)
bash .git/zero.sh merge A2 "$wt2" > "$TK/a2.out" 2>"$TK/a2.err"; rc2=$?
check "A2 merge land-gate exit" "$rc2" "5"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TK="$TK" LOGA="$LOGA" bash "$TK/adrive.sh" || FAILED=1
check "A1 stdout: merge success line" "$(grep -c '^merge A1: merged to main; worktree + branch cleaned$' "$TK/a1.out")" "1"
check "A1 log: success line copied" "$(grep -c '^merge A1: merged to main; worktree + branch cleaned$' "$LOGA")" "1"
check "A2 stderr: land-gate failure present" "$(grep -c 'land gate failed at local' "$TK/a2.err")" "1"
check "A2 log: land-gate failure absent" "$(grep -c 'land gate failed' "$LOGA")" "0"
# A PASS — a successful local-merge outcome line is copied into the session log verbatim; a
# local-merge land-gate failure reaches stderr as always but never the log.

# --- Part B: KAIZERO_LINK symlink-report lines, newly-linked and already-linked ---
LOGB="$TK/b-session.log"; : > "$LOGB"
# link_ignored calls session_log directly (proven a real call site, not a stand-in, by grepping
# zero.sh for the call inside link_ignored's own body below); session_log itself is a one-liner
# whose behavior Parts A and D already prove end to end through real merge/mr calls, so here it
# is just wired in directly rather than sed-extracted (sed's range form is for multi-line bodies).
check "B0 link_ignored really calls session_log" "$(sed -n '/^link_ignored() {/,/^}/p' "$ZA" | grep -c 'session_log ')" "2"
{ printf '%s\n' 'session_log() { [ -n "${KAIZERO_SESSION_LOG:-}" ] && printf "%s\n" "$1" >> "$KAIZERO_SESSION_LOG" 2>/dev/null; return 0; }'
  sed -n '/^link_ignored() {/,/^}/p' "$ZA"; } > "$TK/li.sh"
mkdir -p "$TK/b-wt"; ( cd "$TK/b-wt"; git init -q -b main; git config user.email t@t.t; git config user.name test )
mkdir -p "$TK/repo/tasks"
( set -euo pipefail; . "$TK/li.sh"; KAIZERO_LINK=tasks KAIZERO_SESSION_LOG="$LOGB" link_ignored "$TK/b-wt" "$TK/repo" ) 2>"$TK/b1.err"
( set -euo pipefail; . "$TK/li.sh"; KAIZERO_LINK=tasks KAIZERO_SESSION_LOG="$LOGB" link_ignored "$TK/b-wt" "$TK/repo" ) 2>"$TK/b2.err"
check "B1 stderr newly-linked" "$(grep -c '❄ Linked tasks from' "$TK/b1.err")" "1"
check "B1 log newly-linked" "$(grep -c '^Linked tasks from' "$LOGB")" "1"
check "B2 stderr already-linked" "$(grep -c '❄ tasks already linked from' "$TK/b2.err")" "1"
check "B2 log already-linked" "$(grep -c '^tasks already linked from' "$LOGB")" "1"
# B PASS — both the newly-linked and the already-linked symlink-report lines are copied into the
# session log, worded distinctly, matching what stderr already prints.

# --- Part C: an out-of-scope line (a claim refusal) never reaches the log ---
LOGC="$TK/c-session.log"; : > "$LOGC"
cat > "$TK/cdrive.sh" <<'DRIVE'
set -uo pipefail
REC="$TK/c-session"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" "1" > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH="1" KAIZERO_SESSION_LOG="$LOGC"
cd "$TK/repo"
bash .git/zero.sh claim A1 >/dev/null 2>"$TK/c1.err"   # A1 already merged away — refuses
true
DRIVE
# shellcheck disable=SC2097,SC2098
TK="$TK" LOGC="$LOGC" bash "$TK/cdrive.sh"
check "C claim refusal present on stderr" "$([ -s "$TK/c1.err" ] && echo yes || echo no)" "yes"
check "C claim refusal absent from log" "$(wc -l < "$LOGC" | tr -d ' ')" "0"
# C PASS — a claim refusal (out of scope) shows up on stderr as always, never in the session log.

# --- Part D: mr mode — success, push land-gate failure, forge land-gate failure ---
cat > "$TK/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TK/stub/gh.argv"
verb=""
case "\$1 \${2:-}" in "pr create") verb=create ;; "pr list") verb=list ;; esac
outfile="$TK/stub/gh-\$verb.out"; exitfile="$TK/stub/gh-\$verb.exit"
if [ -f "\$exitfile" ]; then
  [ -f "$TK/stub/gh-\$verb.err" ] && cat "$TK/stub/gh-\$verb.err" >&2
  exit "\$(cat "\$exitfile")"
fi
if [ "\$verb" = list ] && [ ! -f "\$outfile" ]; then printf '[]'; exit 0; fi
[ -n "\$verb" ] && [ -f "\$outfile" ] && cat "\$outfile"
exit 0
STUB
chmod +x "$TK/bin/gh"
mkorigin "$TK/dcode"; mkrepo "$TK/dplan"
( cd "$TK/dplan"; printf -- '- [ ] D1 ok\n- [ ] D2 pushfail\n- [ ] D3 mrfail\n' > todo.md
  mktask D1; mktask D2; mktask D3; git add -A; git commit -qm todo )
( cd "$TK/dcode"; PATH="$TK/bin:$PATH" KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$TK/dplan/todo.md" >/dev/null 2>&1 )
ZD="$TK/dplan/.git/zero.sh"; url=$(printf '%q' "$TK/dcode-origin.git")
sed -i.bak "s#^ORIGIN_URL=.*#ORIGIN_URL=$url#" "$ZD"; rm -f "$ZD.bak"
LOGD="$TK/d-session.log"; : > "$LOGD"
printf 'https://example.invalid/pr/1\n' > "$TK/stub/gh-create.out"

cat > "$TK/ddrive.sh" <<'DRIVE'
set -uo pipefail
export PATH="$TK/bin:$PATH"
REC="$TK/d-session"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" "1" > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH="1" KAIZERO_SESSION_LOG="$LOGD"
cd "$TK/dplan"
FAILED=0; ERRORED=0

# D1 — a clean mr succeeds
wt=$(bash .git/zero.sh claim D1)
echo hi >> "$wt/f"; git -C "$wt" add -A; git -C "$wt" commit -qm "D1 change" >/dev/null
printf 'D1 body\n' > "$(bash .git/zero.sh mr-body-path D1)"
out=$(bash .git/zero.sh mr D1 "$wt" 2>"$TK/d1.err"); rc=$?
check "D1 mr exit" "$rc" "0"
printf '%s' "$out" > "$TK/d1.out"

# D2 — push fails (origin unreachable): land gate failed at push. The bare origin is moved aside
# for the push alone — not the worktree's own remote config, which claim/mr elsewhere depend on.
wt2=$(bash .git/zero.sh claim D2)
echo hi >> "$wt2/f"; git -C "$wt2" add -A; git -C "$wt2" commit -qm "D2 change" >/dev/null
printf 'D2 body\n' > "$(bash .git/zero.sh mr-body-path D2)"
mv "$TK/dcode-origin.git" "$TK/dcode-origin.git.away"
bash .git/zero.sh mr D2 "$wt2" >/dev/null 2>"$TK/d2.err"; rc2=$?
mv "$TK/dcode-origin.git.away" "$TK/dcode-origin.git"
check "D2 mr push failure exit" "$rc2" "5"
bash .git/zero.sh release D2 >/dev/null 2>&1   # one task per session: free the slot before D3

# D3 — push OK, gh pr create fails: land gate failed at mr
wt3=$(bash .git/zero.sh claim D3)
echo hi >> "$wt3/f"; git -C "$wt3" add -A; git -C "$wt3" commit -qm "D3 change" >/dev/null
printf 'D3 body\n' > "$(bash .git/zero.sh mr-body-path D3)"
echo 1 > "$TK/stub/gh-create.exit"; printf 'boom\n' > "$TK/stub/gh-create.err"
bash .git/zero.sh mr D3 "$wt3" >/dev/null 2>"$TK/d3.err"; rc3=$?
check "D3 mr forge failure exit" "$rc3" "5"

[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TK="$TK" LOGD="$LOGD" bash "$TK/ddrive.sh" || FAILED=1

check "D1 stdout names the url" "$(grep -c 'https://example.invalid/pr/1' "$TK/d1.out")" "1"
check "D1 log: mr success line copied" "$(grep -c '^mr D1: https://example.invalid/pr/1 opened from ' "$LOGD")" "1"
check "D2 stderr: push land-gate failure" "$(grep -c 'land gate failed at push' "$TK/d2.err")" "1"
check "D2 log: push land-gate failure copied" "$(grep -c 'land gate failed at push' "$LOGD")" "1"
check "D3 stderr: forge land-gate failure" "$(grep -c 'land gate failed at mr: boom' "$TK/d3.err")" "1"
check "D3 log: forge land-gate failure copied" "$(grep -c 'land gate failed at mr' "$LOGD")" "1"
# out-of-scope mr land-gate families (a dirty tree, a missing checkbox, an empty body, ...) never
# reach the log — checked directly rather than by allow-listing every line, since a push/gh
# failure's own multi-line git/gh error text is itself legitimately copied verbatim (session_log's
# argument is the same $out the stderr echo already embeds, newlines and all)
check "D log: no local land-gate line leaked in" "$(grep -c 'land gate failed at local' "$LOGD")" "0"
check "D log: no body land-gate line leaked in" "$(grep -c 'land gate failed at body' "$LOGD")" "0"
# D PASS — a clean mr's landing-success line, a push land-gate failure and a forge
# request-creation land-gate failure are each copied into the session log, matching stderr/stdout;
# nothing else in the log.

# --- Part E: relay_session_log — new bytes only, prefixed via icon(), no-op with nothing new ---
# icon() itself (its "❄ " vs nothing) is real kaizero.sh behavior driven by color/tty detection
# already covered elsewhere (see icon()'s own doc comment) — Part F below proves relay_session_log
# goes through the real icon(), end to end, in the exact non-tty capture every scenario in this
# suite runs under. Here icon() is stubbed to its own non-tty (plain) behavior so relay's OWN
# bytes-since-last-call bookkeeping is what is under test.
# not wrapped in a `( … )` subshell: check() setting FAILED/ERRORED must reach this script's own
# trailing verdict, and command substitution `$(relay_session_log)` would ALSO fork a subshell for
# the whole call, losing SESSION_LOG_POS's update on return — same reason run_loop's own call site
# is a plain statement, never `$(...)`. Both captured via redirection instead.
extract_fn relay_session_log "$REAL_SCRIPT"
icon(){ :; }
SESSION_LOG_FILE="$TK/e.log"; SESSION_LOG_POS=0
printf 'first line\nsecond line\n' > "$SESSION_LOG_FILE"
relay_session_log > "$TK/e1.out"
check "E1 relay prints both new lines" "$(grep -cE '^(first|second) line$' "$TK/e1.out")" "2"
relay_session_log > "$TK/e2.out"
check "E2 relay reprints nothing" "$(wc -c < "$TK/e2.out" | tr -d ' ')" "0"
printf 'third line\n' >> "$SESSION_LOG_FILE"
relay_session_log > "$TK/e3.out"
check "E3 relay prints only the new line" "$(cat "$TK/e3.out")" "third line"
# a missing file is a no-op, never an error
SESSION_LOG_FILE="$TK/no-such-log"; SESSION_LOG_POS=0
relay_session_log > "$TK/e4.out"; rc4=$?
check "E4 relay on missing file: no output" "$(wc -c < "$TK/e4.out" | tr -d ' ')" "0"
check "E4 relay on missing file: exit 0" "$rc4" "0"
# E PASS — relay_session_log prints exactly the bytes appended since its last call, reprints
# nothing already relayed, and no-ops cleanly when there is no file yet.

# --- Part F: end-to-end through run_loop — the file is per-launch, relayed at the loop
# boundary, and gone once kaizero.sh exits ---
mkrepo "$TK/frepo"
( cd "$TK/frepo"; printf -- '- [ ] F1 x\n' > todo.md; git add -A; git commit -qm init )
cat > "$TK/bin/fclaude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
printf '%s\n' "$KAIZERO_SESSION_LOG" > "$FTRACK/log-path"
[ -f "$KAIZERO_SESSION_LOG" ] && echo yes > "$FTRACK/log-existed" || echo no > "$FTRACK/log-existed"
printf 'merge F1: merged to main; worktree + branch cleaned\n' >> "$KAIZERO_SESSION_LOG"
exit 0
EOF
chmod +x "$TK/bin/fclaude"
mkdir -p "$TK/fbin"; cp "$TK/bin/fclaude" "$TK/fbin/claude"
export FTRACK="$TK/ftrack"; mkdir -p "$FTRACK"
( cd "$TK/frepo"; PATH="$TK/fbin:$PATH" timeout 30 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TK/f.log" 2>&1 )
check "F1 stub saw KAIZERO_SESSION_LOG" "$([ -s "$FTRACK/log-path" ] && echo yes || echo no)" "yes"
check "F1 log file existed at launch" "$(cat "$FTRACK/log-existed")" "yes"
# this suite captures kaizero.sh's stdout to a file (never a tty), so COLOR_CAPABLE=0 and icon()
# prints nothing at all (its own documented plain-mode behavior) — the relayed line appears bare,
# exactly like every other ❄-prefixed report this suite already greps for without the glyph. No
# leading `^` anchor: script(1) (real claude's stand-in pty) can leave a stray control byte right
# before the next write to the same fd, harmless but not part of the relayed text itself.
check "F1 relayed line reaches kaizero's own output" "$(grep -c 'merge F1: merged to main; worktree + branch cleaned$' "$TK/f.log")" "1"
FLOGPATH="$(cat "$FTRACK/log-path")"
check "F1 log file gone after exit" "$([ -e "$FLOGPATH" ] && echo NO || echo yes)" "yes"
# a second, separate launch never reuses the first launch's path
: > "$FTRACK/log-path"
( cd "$TK/frepo"; PATH="$TK/fbin:$PATH" timeout 30 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TK/f2.log" 2>&1 )
FLOGPATH2="$(cat "$FTRACK/log-path")"
check "F2 second launch gets a different path" "$([ "$FLOGPATH2" != "$FLOGPATH" ] && echo yes || echo NO)" "yes"
check "F2 second launch's file also gone after exit" "$([ -e "$FLOGPATH2" ] && echo NO || echo yes)" "yes"
# F PASS — kaizero.sh hands claude a per-launch KAIZERO_SESSION_LOG that already exists at
# launch time; a line zero.sh (simulated here directly by the stub) appends to it reaches
# kaizero.sh's own terminal output, icon-prefixed, by the next run_loop iteration boundary
# (here, the very next one — MAX_LOOPS=1's closer); the file is gone once that launch's
# kaizero.sh exits; and a separate later launch gets its own, different path.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
