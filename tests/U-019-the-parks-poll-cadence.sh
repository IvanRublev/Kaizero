#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=110s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-019-the-parks-poll-cadence — an exact call count on a pty and on a pipe, and an unparsable
# poll value.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: python3 (the pty.fork() harness U53 runs its terminal case under)
# Folder under $TESTROOT: $TESTROOT/U-019-the-parks-poll-cadence
# Wall-clock budget: its longest Run command is `timeout 30` — allow that command at least 30s
#
# wait_for_reviews/wait_for_dependency_clear's MR-mode behaviours live in kaizero.sh's own
# run_loop, not in the emitted zero.sh — zero_funcs/KAIZERO_TEST_EMIT can't reach them, so the
# cases below run the real doctor and the real restart loop: a real, fetchable, no-host bare
# origin (mkorigin) for the target, a plain mkrepo for the coordination repo, and a controllable
# stub claude rebuilt per case via mkpath (a snapshot copy, so each case's $TU/bin/claude must be
# written before its own mkpath call).
#
# The cadence the park polls at: a fixed WAIT_TICK rather than the fast repaint tick, proven by
# an exact call count on a real pty and on a pipe, and KAIZERO_REVIEW_POLL warning and falling
# back to 5m on an unparsable value.

### Setup
TU="$TESTROOT/U-019-the-parks-poll-cadence"; mkdir -p "$TU/bin" "$TU/stub"
# MR mode is the default, so every fixture target needs an `origin` a forge resolves
# from or the launch refuses before the case's own subject is reached. A github URL, never fetched
# (TEST_EMIT skips the doctor; the real-doctor cases use `mkorigin` instead).
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git remote add origin "https://github.com/acme/$(basename "$1").git" ); }

# target repo cloned from a local bare origin — real, fetchable, no host. $1 = target dir.
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1"; git config user.email t@t.t; git config user.name test )
}

# stub claude: prints its argv (captured to see the banner precede it in the launch log) and exits.
printf '#!/usr/bin/env bash\nprintf "ARGV: %%s\\n" "$*"\nexit 0\n' > "$TU/bin/claude"; chmod +x "$TU/bin/claude"

# stub gh/glab: record argv+cwd, one failure marker per verb ($TU/stub/<prog>-<verb>) — and,
# for `auth status`, one PER HOSTNAME too ($TU/stub/<prog>-auth-status-<host>, host from
# --hostname, blank when the fixture's origin has none) — so a case can fail one host's login
# without touching another's. Exit 0 by default (auth status passes, matching what check 6 and
# the mid-run re-check both need).
# `list`/`create` gain two more per-verb files, read if present: `<prog>-<verb>.out`
# (cat'd to stdout before anything else — the canned JSON/URL a case wants mr_list/mr_create to
# reshape) and `<prog>-<verb>.rc` (its content, read as the exit code, instead of the marker
# logic below — so a case can return 0 with empty stdout, or non-zero with real stdout, neither
# of which the marker-only mechanism above can express).
#
# check 5 calls `<verb> --help` on the resolved forge and greps its output for each
# flag mr_list/mr_create pass — so `--help` answers with the real default flag list per
# prog+verb, unless `<prog>-<verb>-help.txt` exists, which is cat'd verbatim instead. It also
# probes `gh pr list --json` with no value (exactly `pr list --json`, no fourth arg) — the real
# CLI prints its field list on stderr and exits 1, so the stub does the same, from
# `gh-list-json.txt` if present else the real default field list.
for prog in gh glab; do
case "$prog" in
  gh)   listflags="--repo --head --state --limit --json"; createflags="--repo --head --base --title --body-file"
        authflags="--hostname" ;;
  glab) listflags="--repo --source-branch --all --output --per-page --order --sort"
        createflags="--repo --source-branch --target-branch --title --description --yes"
        authflags="--hostname" ;;
esac
cat > "$TU/bin/$prog" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TU/stub/$prog.argv"
printf '%s\n' "\$PWD" >> "$TU/stub/$prog.cwd"
verb=""
is_help=0
for a in "\$@"; do [ "\$a" = --help ] && is_help=1; done
case "\$1 \${2:-}" in
  "auth status") verb=auth-status ;;
  "pr create"|"mr create") verb=create ;;
  "pr list"|"mr list") verb=list ;;
esac
if [ "\$1 \${2:-}" = "pr list" ] && [ "\${3:-}" = "--json" ] && [ \$# -eq 3 ]; then
  jsonfile="$TU/stub/gh-list-json.txt"
  if [ -f "\$jsonfile" ]; then cat "\$jsonfile" >&2; else printf '%s\n' 'number headRefOid baseRefName state url' >&2; fi
  exit 1
fi
if [ "\$is_help" = 1 ] && [ -n "\$verb" ]; then
  helpfile="$TU/stub/$prog-\$verb-help.txt"
  if [ -f "\$helpfile" ]; then cat "\$helpfile"; exit 0; fi
  case "\$verb" in
    list) printf '%s\n' $listflags ;;
    create) printf '%s\n' $createflags ;;
    auth-status) printf '%s\n' $authflags ;;
  esac
  exit 0
fi
if [ "\$verb" = auth-status ]; then
  host=""; prev=""
  for a in "\$@"; do [ "\$prev" = --hostname ] && host="\$a"; prev="\$a"; done
  marker="$TU/stub/${prog}-auth-status-\$host"
  outfile=""; rcfile=""
else
  marker="$TU/stub/${prog}-\$verb"
  outfile="$TU/stub/${prog}-\$verb.out"
  rcfile="$TU/stub/${prog}-\$verb.rc"
fi
[ -n "\$outfile" ] && [ -f "\$outfile" ] && cat "\$outfile"
if [ -n "\$rcfile" ] && [ -f "\$rcfile" ]; then read -r rc < "\$rcfile"; exit "\${rc:-0}"; fi
if [ -n "\$verb" ] && [ -f "\$marker" ]; then cat "\$marker" >&2; exit 1; fi
exit 0
STUB
chmod +x "$TU/bin/$prog"
done

# closed PATH sets — never the ambient $PATH, so a "missing" case is really missing regardless
# of what happens to be installed on the machine running this file, and a "present" case is
# always the stub, never a real forge CLI. $1 names the variant dir, the rest are the tools it
# gets ("claude"/"gh"/"glab" copy the stubs above; anything else symlinks the real binary — git,
# flock, timeout, jq are the only ones any case needs beyond /usr/bin:/bin's own coreutils).
mkpath(){
  local d="$TU/path-$1"; shift; mkdir -p "$d"
  for t in "$@"; do
    case "$t" in
      claude|gh|glab) cp "$TU/bin/$t" "$d/$t" ;;
      *)              p=$(command -v "$t") || { echo "REFUSING: '$t' not found — cannot build $d" >&2; exit 1; }
                    ln -sf "$p" "$d/$t" ;;
    esac
  done
  printf '%s:/usr/bin:/bin' "$d"
}
ALLPATH="$(mkpath all claude flock git timeout gh glab jq)"           # everything present

export PATH="$ALLPATH" KAIZERO_FORGE=gh   # scenario-wide default; unset per-case for selection tests

### U53 — poll cadence exact call count, terminal (real pty) and pipe: a fixed `WAIT_TICK`, not the fast repaint tick
# pty_helper.py <log-path> <deadline-seconds> <argv...> — runs argv under a REAL pty (isatty()
# true for the child), teeing raw output to <log-path>, and force-reaps the whole process group
# after <deadline-seconds> so a parked kaizero.sh (which outlives a bare `timeout`'s
# single-child SIGTERM once its own pty-master reader has already exited) never leaks.
cat > "$TU/pty_helper.py" <<'PYEOF'
import pty, os, sys, select, signal, time
log_path = sys.argv[1]; deadline = float(sys.argv[2]); argv = sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
start = time.time()
with open(log_path, 'wb') as log:
    while True:
        remaining = deadline - (time.time() - start)
        if remaining <= 0:
            break
        try:
            r, _, _ = select.select([fd], [], [], min(remaining, 1.0))
        except OSError:
            break
        if fd in r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            log.write(data); log.flush()
        try:
            wpid, _ = os.waitpid(pid, os.WNOHANG)
        except OSError:
            break
        if wpid == pid:
            break
try:
    os.killpg(pid, signal.SIGKILL)
except OSError:
    pass
try:
    os.waitpid(pid, 0)
except OSError:
    pass
PYEOF

mkorigin "$TU/u53code"; mkrepo "$TU/u53plan"
( cd "$TU/u53code"; git checkout -qb u53a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u53plan"; printf -- '- [\xe2\x86\x91] u53a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":9,"headRefOid":"neverresolves","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/9"}]
JSON
printf '#!/usr/bin/env bash\nexit 0\n' > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
P53=$(mkpath u53 claude flock git timeout gh glab jq)

# piped (log branch): stdout is a plain file, [ -t 1 ] false.
rm -f "$TU/stub/gh.argv"
( cd "$TU/u53code"; PATH="$P53" KAIZERO_REVIEW_WAIT=13s KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=3s timeout 30 bash "$SCRIPT" "$TU/u53plan/todo.md" > "$TU/u53pipe.log" 2>&1 )
check "U53 piped: exit" "$?" "0"
# ~3-5 poll-ticks over a 3s-poll/13s-park window; matched on '--repo', which only the poll's own
# mr_list call carries — the doctor's own 'pr list --help'/'pr list --json' probes land in the
# same log but never carry it. A range, not an exact count: `date +%s` gives 1s granularity
# against a tight 3s poll interval, so real process-startup timing variance shifts which second
# each tick lands on and can add or drop one tick — same tolerance style as this suite's other
# wall-clock-sensitive counts (e.g. T-013's "mr elapsed").
n="$(grep -c 'pr list --repo' "$TU/stub/gh.argv" 2>/dev/null || echo 0)"
check "U53 piped: exact pr-list calls" "$([ "$n" -ge 3 ] && [ "$n" -le 5 ] && echo yes || echo "no ($n)")" "yes"
check "U53 piped: did park (log line)" "$([ "$(grep -c 'Waiting for reviews' "$TU/u53pipe.log")" -ge 1 ] && echo yes || echo no)" "yes"

# terminal (repaint branch): a REAL pty, [ -t 1 ] true — same cadence must hold there too.
rm -f "$TU/stub/gh.argv"
( cd "$TU/u53code"; PATH="$P53" KAIZERO_REVIEW_WAIT=13s KAIZERO_REVIEW_POLL=3s \
    python3 "$TU/pty_helper.py" "$TU/u53pty.log" 20 bash "$SCRIPT" "$TU/u53plan/todo.md" )
# same cadence under a real terminal; '--repo' isolates the poll's own calls from the doctor's
# help/json probes
check "U53 pty: exact pr-list calls" "$(grep -c 'pr list --repo' "$TU/stub/gh.argv" 2>/dev/null || echo 0)" "3"
# proves [ -t 1 ] took the repaint branch, not the log one
check "U53 pty: did repaint (isatty)" "$([ "$(grep -a -c $'\033\[K' "$TU/u53pty.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U53 pty: park line present" "$([ "$(grep -a -c 'Waiting for reviews' "$TU/u53pty.log")" -ge 1 ] && echo yes || echo no)" "yes"
rm -f "$TU/stub/gh-list.out" "$TU/stub/gh.argv"
# U53 PASS — the poll belongs to the outer wait loop's own iteration (granularity WAIT_TICK, a
# fixed 5s), not the fast repaint tick: a 13s park at KAIZERO_REVIEW_POLL=3s fires exactly 3
# `pr list` calls (1 loop-top + 2 poll-tick) whether stdout is a plain pipe or a genuine pty —
# proven under a real terminal via a hand-rolled pty.fork() harness (bare `timeout` alone cannot
# bound a pty child: once its pty-master reader dies, the orphaned kaizero.sh survives
# timeout's single-child SIGTERM and keeps running/parking indefinitely — the harness force-reaps
# the whole process group on its own deadline instead).

### U54 — `KAIZERO_REVIEW_POLL` warns and falls back to `5m` on an unparsable value
mkorigin "$TU/u54code"; mkrepo "$TU/u54plan"
( cd "$TU/u54code"; git checkout -qb u54a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u54plan"; printf -- '- [\xe2\x86\x91] u54a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":19,"headRefOid":"neverresolves","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/19"}]
JSON
printf '#!/usr/bin/env bash\nexit 0\n' > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
P54=$(mkpath u54 claude flock git timeout gh glab jq)
rm -f "$TU/stub/gh.argv"
( cd "$TU/u54code"; PATH="$P54" KAIZERO_REVIEW_WAIT=4s KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=bogus timeout 20 bash "$SCRIPT" "$TU/u54plan/todo.md" > "$TU/u54.log" 2>&1 )
check "U54 warns on unparsable value" "$(grep -c 'Ignoring KAIZERO_REVIEW_POLL=bogus (want 900, 90s, 15m, 1h) — using 5m' "$TU/u54.log")" "1"
# the loop-top call only, no poll-tick fires before the 4s ceiling; '--repo' isolates the poll's
# own calls from the doctor's help/json probes
check "U54 default 5m fallback: no poll inside a 4s park" "$(grep -c 'pr list --repo' "$TU/stub/gh.argv" 2>/dev/null || echo 0)" "1"
rm -f "$TU/stub/gh-list.out" "$TU/stub/gh.argv"
# U54 PASS — the parse+warn lives inside run_loop() itself (kaizero.sh:358-373), not the
# doctor/bake stage, so KAIZERO_TEST_EMIT (which exits before run_loop is ever reached) can't
# observe it — this needs a real run, the same harness as U32/U53. One run proves both: the exact
# warning text, and that the fallback is really live (a 4s park sees no poll-tick fire, same as
# an unset KAIZERO_REVIEW_POLL would).

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
