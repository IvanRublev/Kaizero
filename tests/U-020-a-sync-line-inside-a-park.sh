#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=85s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-020-a-sync-line-inside-a-park — the repaint is cleared right before it, so the line starts
# clean rather than mid-frame.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: python3 (the pty.fork() harness the repaint case runs under)
# Folder under $TESTROOT: $TESTROOT/U-020-a-sync-line-inside-a-park
# Wall-clock budget: its longest Run command is `timeout 30` — allow that command at least 30s
#
# wait_for_reviews/wait_for_dependency_clear's MR-mode behaviours live in kaizero.sh's own
# run_loop, not in the emitted zero.sh — zero_funcs/KAIZERO_TEST_EMIT can't reach them, so the
# case below runs the real doctor and the real restart loop: a real, fetchable, no-host bare
# origin (mkorigin) for the target, a plain mkrepo for the coordination repo, and a controllable
# stub claude rebuilt per case via mkpath (a snapshot copy, so each case's $TU/bin/claude must be
# written before its own mkpath call).
#
# A sync-mrs line printed inside a park has to survive on a real terminal: the repaint is cleared
# right before it, so the line starts clean rather than mid-frame.

### Setup
TU="$TESTROOT/U-020-a-sync-line-inside-a-park"; mkdir -p "$TU/bin" "$TU/stub"
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

### U57 — a `sync-mrs` line printed inside a park survives on a real terminal: the repaint is cleared right before it and the sync line starts clean, not mid-frame
cat > "$TU/pty_helper57.py" <<'PY'
# a minimal pty wrapper: runs argv[2:] under a real pty (so [ -t 1 ] is true inside the
# script, taking the terminal-repaint branch) and tees every raw byte to argv[1] — pty.spawn's
# own wait can hang once the child has genuinely exited (no real controlling tty in an
# unattended harness), so the caller detects completion from the log content itself and kills
# this process outright; only the captured bytes are ever trusted for the assertions below.
import pty, os, sys
logfd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
def reader(fd):
    data = os.read(fd, 65536)
    if data: os.write(logfd, data)
    return data
pty.spawn(sys.argv[2:], reader)
PY

mkorigin "$TU/u57code"; mkrepo "$TU/u57plan"
( cd "$TU/u57code"; git checkout -qb u57a-fix-thing; echo y > g; git add g; git commit -qm work
  git rev-parse HEAD > "$TU/u57a.sha"; git checkout -q main )
( cd "$TU/u57plan"; printf -- '- [\xe2\x86\x91] u57a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
u57sha=$(cat "$TU/u57a.sha")
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":9,"headRefOid":"$u57sha","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/9"}]
JSON
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u57launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u57launched"
P57=$(mkpath u57 claude flock git timeout gh glab jq)

RAWLOG="$TU/u57.raw"
( i=0
  while ! grep -aq 'Waiting for reviews' "$RAWLOG" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":9,"headRefOid":"$u57sha","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/9"}]
JSON
) &
FLIP57=$!

( cd "$TU/u57code"
  PATH="$P57" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s python3 "$TU/pty_helper57.py" "$RAWLOG" timeout 30 bash "$SCRIPT" "$TU/u57plan/todo.md" </dev/null ) &
PTYPID=$!
i=0; while ! grep -aq 'surveys the frozen field' "$RAWLOG" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
# kill -9 on the subshell's own pid alone is not reliable here — bash may or may not tail-exec
# python3 into that same pid, so the grandchild can survive as an orphan (observed directly).
# pkill -f on the unique RAWLOG path in argv is exact and does not depend on that ambiguity.
kill -9 "$PTYPID" 2>/dev/null || true
pkill -9 -f "pty_helper57.py $RAWLOG" 2>/dev/null || true
wait "$PTYPID" "$FLIP57" 2>/dev/null || true
rm -f "$TU/stub/gh-list.out"

check "U57 run completed (closing banner seen)" "$(grep -aq 'surveys the frozen field' "$RAWLOG" && echo yes || echo no)" "yes"
check "U57 no claude launched" "$(wc -l < "$TU/u57launched" | tr -d ' ')" "0"
check "U57 box now x" "$(git -C "$TU/u57plan" show HEAD:todo.md | grep -c '\[x\] u57a')" "1"
check "U57 sync line printed exactly once" "$(grep -ac 'sync u57a: merged' "$RAWLOG")" "1"
CLEAN=$(python3 - "$RAWLOG" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
print(data.count(b'\x1b[K\r\x1b[Ksync '))
PY
)
check "U57 repaint cleared right before the sync line, sync starts clean" "$CLEAN" "1"
# U57 PASS — under a real pty (pty.spawn, not a log redirect), [ -t 1 ] is true so
# wait_for_reviews takes its repaint branch; the raw captured byte stream shows the last spinner
# frame's own \033[K immediately followed by \r\033[K (the wait's own clear-before-sync) and then
# `sync u57a: merged …` starting with no leftover spinner-line bytes glued onto it — proof the
# line survives whole on a terminal, not just on a log (already covered by U32/U37). pty.spawn's
# own wait can hang after its child has genuinely exited in this unattended harness, so
# completion is judged from the log content and process cleanup uses pkill -f, never
# pty_helper57.py's own exit code.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
