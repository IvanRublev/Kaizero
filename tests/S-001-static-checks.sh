#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# S-001-static-checks — static checks (shellcheck + bash 3.2 syntax). Lints kaizero.sh and
# the scripts it emits at runtime, then checks the bash 3.2 heredoc-in-$(...) constraint
# structurally and with a real bash 3.x parse.
# Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor tests
# `command -v claude` before any startup guard runs)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/S-001-static-checks
# Wall-clock budget: seconds — no Run command of this scenario wraps itself in timeout
#
# Lints kaizero.sh (S1) and the scripts it emits at runtime (S2), then checks the
# bash 3.2 constraint — structurally (S3a) and by a real bash 3.x parse (S3b). The emitted
# scripts live in single-quoted heredocs, invisible to a lint of kaizero.sh — that
# blind spot once shipped an unbalanced quote in zero.sh. KAIZERO_TEST_EMIT=1
# runs init for real in a throwaway repo (writes the scripts, exits before claude), then
# we lint the actual files. -e SC2016 mirrors .github/check-embedded.sh: single-quoted
# bash -c/awk blobs are intentional. $SHELLCHECK is the binary the shared setup resolved.

# Setup
TS="$TESTROOT/S-001-static-checks/repo"; mkdir -p "$TS"

# S1 — kaizero.sh itself is shellcheck-clean. Findings, if any, print above the verdict.
"$SHELLCHECK" "$REAL_SCRIPT"
check "S1 kaizero.sh clean" "$?" "0"

# S2 — the scripts kaizero.sh emits at runtime are shellcheck-clean
# emit in a subshell (init must run at the temp repo root); lint from HERE with absolute
# paths — a version-manager shim (asdf/mise) re-resolves shellcheck by cwd, so cd'ing into
# the temp repo (no .tool-versions) would break the shim, not the script.
( cd "$TS"; git init -q; git config user.email t@t.t; git config user.name test
  echo '- [ ] G noop' > todo.md; git add -A; git commit -qm init
  KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md >/dev/null )
rc=0
for f in compact-exit-hook.sh zero.sh terminator.sh; do
  if [ -f "$TS/.git/$f" ]; then
    "$SHELLCHECK" -e SC2016 "$TS/.git/$f" || rc=1
  else
    echo "S2: $f not emitted" >&2; rc=1
  fi
done
check "S2 emitted scripts clean" "$rc" "0"

# S3 — bash 3.2 syntax. macOS ships bash 3.2 as /bin/bash and that is what a Homebrew
# install runs, but bash 3.2 has parse-time limits bash 5 does not (a heredoc inside $(…)
# is one; it once made the whole script unparsable). Parse-only, no execution. Two steps:
# S3a catches the construct by text, S3b runs a real bash 3.x parse.

# S3a — the heredoc-inside-$( … ) construct, caught structurally
#
# A Linux-only CI leg has no bash 3.2 to parse with, so a
# /bin/bash -n gate alone goes silent exactly where the bug is easiest to reintroduce. This
# scan is pure text: it tracks quote state, skips comments and here-doc bodies, ignores $(( ))
# and <<<, and reports any here-doc opened inside a command substitution, by line and
# delimiter.
mkdir -p "$TESTROOT/S-001-static-checks"
cat > "$TESTROOT/S-001-static-checks/heredoc-scan.awk" <<'SCAN_EOF'
{
  if (await != "") {                       # inside a here-doc body: only the delimiter ends it
    t = $0; sub(/^[ \t]+/, "", t)
    if ($0 == await || t == await) await = ""
    next
  }
  n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (sq) { if (c == "'") sq = 0; continue }
    if (c == "\\") { i++; continue }
    if (substr($0, i, 3) == "$((") { arith++; i += 2; continue }
    if (substr($0, i, 2) == "$(")  { stack[++subst] = dq; dq = 0; i += 1; continue }
    if (c == ")") {
      if (arith > 0 && substr($0, i+1, 1) == ")") { arith--; i++ }
      else if (subst > 0) { dq = stack[subst--] }
      continue
    }
    if (dq) { if (c == "\"") dq = 0; continue }
    if (c == "'") { sq = 1; continue }
    if (c == "\"") { dq = 1; continue }
    if (c == "#" && (i == 1 || substr($0, i-1, 1) ~ /[ \t;&|(]/)) break
    if (substr($0, i, 3) == "<<<") { i += 2; continue }
    if (substr($0, i, 2) == "<<") {
      j = i + 2
      if (substr($0, j, 1) == "-") j++
      while (substr($0, j, 1) == " ") j++
      d = ""; q = substr($0, j, 1)
      if (q == "'" || q == "\"") { j++; while (j <= n && substr($0, j, 1) != q) { d = d substr($0, j, 1); j++ } }
      else { while (j <= n && substr($0, j, 1) ~ /[A-Za-z0-9_]/) { d = d substr($0, j, 1); j++ } }
      if (subst > 0) { printf "%s:%d: here-doc <<%s opened inside $( … )\n", FILENAME, FNR, d; bad = 1 }
      if (d != "") await = d
      i = j - 1
      continue
    }
  }
}
END { exit (bad ? 1 : 0) }
SCAN_EOF
SCAN="awk -f $TESTROOT/S-001-static-checks/heredoc-scan.awk"
$SCAN "$REAL_SCRIPT"
check "S3a no here-doc inside \$( … )" "$?" "0"

# self-test: the scan must FAIL on the pre-fix form, or it is only passing beside the bug.
# The fix predates this repo's history, so `git show HEAD~1:kaizero.sh` has nothing to
# catch — rebuild the offending construct from the current script instead.
sed "s#^    IFS= read -r -d '' prompt <<'PROMPT_EOF' || :#    local prompt=\"\$(cat <<'PROMPT_EOF'#" \
  "$REAL_SCRIPT" > "$TESTROOT/S-001-static-checks/unfixed.sh"
$SCAN "$TESTROOT/S-001-static-checks/unfixed.sh" >/dev/null
# the scan must FAIL (nonzero) on the deliberately-unfixed script, or it proves nothing
check "S3a selftest catches the unfixed form" "$?" "1"

# S3b — a real bash 3.x parse
#
# Against the $B3 binary the shared setup resolved. Covers the emitted
# scripts too: they are written at runtime, so a bash-3.2 parse error inside zero.sh never shows
# up in a parse of kaizero.sh. S2 emitted them.
ver="$("$B3" --version | head -1 | sed -n 's/.*version \([0-9.]*\).*/\1/p')"
rc=0; files="$REAL_SCRIPT"
TS="$TESTROOT/S-001-static-checks/repo"
for f in compact-exit-hook.sh zero.sh terminator.sh; do
  if [ -f "$TS/.git/$f" ]; then
    files="$files $TS/.git/$f"
  else
    echo "S3b: $f not emitted by S2" >&2; rc=1
  fi
done
for f in $files; do "$B3" -n "$f" || rc=1; done
check "S3b parses under bash $ver" "$rc" "0"

# S4 — BUG 057 absence checks. term_owner/find_owner used to resolve the session to signal or
# own by matching a command name (comm=claude) or walking $PPID; that matcher is deleted, not
# narrowed, and must not come back under any spelling. Written here (not only as a review-time grep)
# so it runs on every suite pass. $TS/.git still holds the S2 emit.
check "S4a no command-name comparison" \
  "$(grep -c 'comm=' "$SCRIPT" "$TS/.git/compact-exit-hook.sh" "$TS/.git/zero.sh" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')" "0"
check "S4b no \$PPID ancestor walk" "$(grep -c 'PPID' "$SCRIPT")" "0"
check "S4c no alternative agent-name knob" \
  "$(grep -ciE 'agent_name|CLAUDE_(BIN|NAME|COMM)|alternative.{0,20}name' "$SCRIPT")" "0"
check "S4d CLAUDE_PID never a signal target" \
  "$(grep -n 'kill.*"\$CLAUDE_PID"' "$SCRIPT" | grep -vc 'kill -0')" "0"
check "S4e no process-group mechanism or signal" \
  "$(grep -c 'setsid\|setpgid\|kill -[A-Za-z]* -[0-9]' "$SCRIPT" "$TS/.git/compact-exit-hook.sh" "$TS/.git/zero.sh" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')" "0"

# S5 — check()'s own ERROR: path (ISSUE-058c). A guard refusal has no meaningful actual-vs-want
# comparison, so check() must report it as ERROR, never as a FAIL-shaped mismatch. Run in a
# subshell so the demonstration's own FAILED/ERRORED never bleeds into this scenario's real
# verdict — this case is checking check()'s behavior, not exercising a real guard refusal.
s5_out="$( ( FAILED=0; ERRORED=0
  check "s5-demo" "ERROR:refusal text" ""
  echo "ERRORED=$ERRORED"
) )"
check "S5a ERROR: verdict line quotes the refusal text verbatim, not FAIL-shaped" \
  "$(printf '%s\n' "$s5_out" | grep -c '^s5-demo : refusal text  ERROR$')" "1"
check "S5b ERROR: path sets ERRORED, never FAILED" \
  "$(printf '%s\n' "$s5_out" | grep -c '^ERRORED=1$')" "1"

# S6 — WAIT_TICK (the network/claimable-probe poll cadence used by wait_for_network and
# wait_for_claimable) is overridable via KAIZERO_WAIT_TICK, the same pattern as every other
# *_DEFAULT knob (KAIZERO_WATCHDOG, KAIZERO_DEPENDENCY_WAIT, KAIZERO_REVIEW_POLL) — so a test
# fixture can shrink the real wall-clock cost of a park/outage assertion without changing what
# it proves.
check "S6 WAIT_TICK overridable via KAIZERO_WAIT_TICK" \
  "$(grep -cF 'WAIT_TICK="${KAIZERO_WAIT_TICK:-5}"' "$REPO/kaizero.sh")" "1"

# S7 — LOG_TICK (the heartbeat cadence for a piped/logged park) is overridable the same way, so
# a fixture proving "the log heartbeats past one LOG_TICK" doesn't have to hold a real outage
# open for the full hardcoded 20s to prove it.
check "S7 LOG_TICK overridable via KAIZERO_LOG_TICK" \
  "$(grep -cF 'LOG_TICK="${KAIZERO_LOG_TICK:-20}"' "$REPO/kaizero.sh")" "1"

# S8 — RESTART_WAIT (the between-restart cadence used for RESTART_GAP) is overridable via
# KAIZERO_RESTART_WAIT, same pattern — it was a plain `RESTART_WAIT=5` with no env read at all,
# so a fixture that exported RESTART_WAIT directly was silently ignored.
check "S8 RESTART_WAIT overridable via KAIZERO_RESTART_WAIT" \
  "$(grep -cF 'RESTART_WAIT="${KAIZERO_RESTART_WAIT:-5}"' "$REPO/kaizero.sh")" "1"

# S9 — WATCHDOG_GRACE (seconds between the watchdog's SIGTERM and its SIGKILL escalation) is
# overridable via KAIZERO_WATCHDOG_GRACE, so a watchdog-kill-escalation fixture doesn't have to
# hold a stuck process open for the full hardcoded 10s to prove the escalation fires.
check "S9 WATCHDOG_GRACE overridable via KAIZERO_WATCHDOG_GRACE" \
  "$(grep -cF 'WATCHDOG_GRACE="${KAIZERO_WATCHDOG_GRACE:-10}"' "$REPO/kaizero.sh")" "1"

# S10 — forge_auth_ok's own retry wait (between its own up-to-3 attempts) is overridable via
# KAIZERO_FORGE_AUTH_RETRY_WAIT, so a forge-auth-flap fixture's up-to-two retries don't have to
# cost 2s each.
check "S10 forge_auth_ok retry wait overridable via KAIZERO_FORGE_AUTH_RETRY_WAIT" \
  "$(grep -cF 'FORGE_AUTH_RETRY_WAIT="${KAIZERO_FORGE_AUTH_RETRY_WAIT:-2}"' "$REPO/kaizero.sh")" "1"

# S11 — the pre-launch "Starting session in 3...2...1" countdown can be skipped entirely via
# KAIZERO_LAUNCH_COUNTDOWN=0, so a fixture that launches many real sessions doesn't pay a fixed
# 3s tax on every one of them.
check "S11 pre-launch countdown skippable via KAIZERO_LAUNCH_COUNTDOWN=0" \
  "$(grep -cF '${KAIZERO_LAUNCH_COUNTDOWN:-1}' "$REPO/kaizero.sh")" "1"

# S PASS — S1 and S2 both PASS (kaizero.sh clean, both emitted scripts clean),
# S3a PASS with its SELFTEST PASS, S3b PASS, S4 PASS, S5 PASS, S6 PASS, S7 PASS, S8 PASS,
# S9 PASS, S10 PASS, and S11 PASS.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
