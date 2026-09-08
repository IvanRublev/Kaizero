#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=116s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-027-a-token-that-dies-mid-park — a token that dies inside a wait_for_reviews park; the
# wait_for_dependency_clear sibling and the shared-probe absence check live in
# U-021-breaking-the-park.sh's own U60/U63.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-027-a-token-that-dies-mid-park
# Wall-clock budget: its longest Run command is `timeout 35` — allow that command at least 35s
#
# wait_for_reviews/wait_for_dependency_clear's MR-mode behaviours live in kaizero.sh's own
# run_loop, not in the emitted zero.sh — zero_funcs/KAIZERO_TEST_EMIT can't reach them, so the
# cases below run the real doctor and the real restart loop: a real, fetchable, no-host bare
# origin (mkorigin) for the target, a plain mkrepo for the coordination repo, and a controllable
# stub claude rebuilt per case via mkpath (a snapshot copy, so each case's $TU/bin/claude must be
# written before its own mkpath call).
#
# The third of the three ways a park ends badly and still ends once: a token that dies inside the
# park rather than before it — proven here at a wait_for_reviews park.

### Setup
TU="$TESTROOT/U-027-a-token-that-dies-mid-park"; mkdir -p "$TU/bin" "$TU/stub"
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
# without touching another's. Exit 0 by default (auth status passes, matching what check 5 and
# the mid-run re-check both need).
# `list`/`create` (039d) gain two more per-verb files, read if present: `<prog>-<verb>.out`
# (cat'd to stdout before anything else — the canned JSON/URL a case wants mr_list/mr_create to
# reshape) and `<prog>-<verb>.rc` (its content, read as the exit code, instead of the marker
# logic below — so a case can return 0 with empty stdout, or non-zero with real stdout, neither
# of which the marker-only mechanism above can express).
#
# check 8 (TASK-049) calls `<verb> --help` on the resolved forge and greps its output for each
# flag mr_list/mr_create pass — so `--help` answers with the real default flag list per
# prog+verb, unless `<prog>-<verb>-help.txt` exists, which is cat'd verbatim instead. It also
# probes `gh pr list --json` with no value (exactly `pr list --json`, no fourth arg) — the real
# CLI prints its field list on stderr and exits 1, so the stub does the same, from
# `gh-list-json.txt` if present else the real default field list.
for prog in gh glab; do
case "$prog" in
  gh)   listflags="--repo --head --state --limit --json"; createflags="--repo --head --base --title --body-file" ;;
  glab) listflags="--repo --source-branch --all --output --per-page --order --sort"
        createflags="--repo --source-branch --target-branch --title --description --yes" ;;
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
    auth-status) printf '%s\n' --hostname ;;
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

### U58 — a token that dies DURING a review park stops the run through the closer, exit 2, instead of `sync-mrs` swallowing the failure and spinning forever
mkorigin "$TU/u58code"; mkrepo "$TU/u58plan"
( cd "$TU/u58code"; git checkout -qb u58a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u58plan"; printf -- '- [\xe2\x86\x91] u58a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
u58sha=$(git -C "$TU/u58code" rev-parse u58a-fix-thing)
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":58,"headRefOid":"$u58sha","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/58"}]
JSON

# forge_auth_ok() only runs when ORIGIN_HOST is non-empty (kaizero.sh:471), and mkorigin's
# hostless local-path clone makes it a structural no-op everywhere, launch AND mid-run alike — the
# broken-login flip below would never be read at all. Same fix as U-024's U62/U63: a fake HTTPS
# origin from the start, plus a git wrapper ahead of the real git on PATH that answers ls-remote
# for it and redirects fetch back to the real local bare origin.
u58realgit="$(type -P git)"
u58fakeurl="https://fake-forge-u58.test/org/u58code.git"
u58realorigin="$(git -C "$TU/u58code" remote get-url origin)"
git -C "$TU/u58code" remote set-url origin "$u58fakeurl"
mk_u58_gitwrap() {
  rm -f "$TU/path-u58/git"
  cat > "$TU/path-u58/git" <<EOF
#!/usr/bin/env bash
REALGIT="$u58realgit"
FAKEURL="$u58fakeurl"
REALORIGIN="$u58realorigin"
args=("\$@")
sub=""; i=0
while [ "\$i" -lt "\${#args[@]}" ]; do
  a="\${args[\$i]}"
  case "\$a" in
    -C|-c) i=\$((i+2)); continue ;;
    -*) i=\$((i+1)); continue ;;
    *) sub="\$a"; break ;;
  esac
done
if [ "\$sub" = ls-remote ]; then
  for a in "\${args[@]}"; do
    if [ "\$a" = "\$FAKEURL" ]; then
      ref="\${args[\$((\${#args[@]}-1))]}"
      printf '%040d\t%s\n' 1 "\$ref"
      exit 0
    fi
  done
fi
if [ "\$sub" = fetch ]; then
  newargs=()
  for a in "\${args[@]}"; do
    [ "\$a" = origin ] && a="\$REALORIGIN"
    newargs+=("\$a")
  done
  exec "\$REALGIT" "\${newargs[@]}"
fi
exec "\$REALGIT" "\$@"
EOF
  chmod +x "$TU/path-u58/git"
}

P58=$(mkpath u58 claude flock git timeout gh glab jq); mk_u58_gitwrap

# control: this exact fixture (same sha, MERGED), unblocked, writes a `zero sync u58a` commit and
# self-ends the moment it does — proving the 0-count assertion below is non-vacuous.
( cd "$TU/u58code"; PATH="$P58" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 20 bash "$SCRIPT" "$TU/u58plan/todo.md" > "$TU/u58ctrl.log" 2>&1 )
check "U58 control: fixture can sync" "$(git -C "$TU/u58plan" log --oneline --grep='zero sync u58a' | wc -l | tr -d ' ')" "1"
git -C "$TU/u58plan" reset -q --hard HEAD~1
# the control run's own sync deletes the local task branch as real merged-branch cleanup — the
# commit object itself survives ungarbage-collected within this run, so recreate the branch at
# the same sha rather than rebuilding u58code (which would mint a new sha and invalidate
# gh-list.out's headRefOid above).
git -C "$TU/u58code" branch u58a-fix-thing "$u58sha"

printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u58launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u58launched"
P58=$(mkpath u58 claude flock git timeout gh glab jq); mk_u58_gitwrap
rm -f "$TU/stub/gh-auth-status-fake-forge-u58.test"
# unlike the control, the real park needs the PR still OPEN so the pre-loop sync-mrs pass leaves
# the box at [↑] and wait_for_reviews actually parks — a MERGED state (like the control's) ticks
# the box on the very first pass, before the park (and the auth break inside it) is ever reached.
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":58,"headRefOid":"$u58sha","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/58"}]
JSON
# the origin now has a real host (fake-forge-u58.test), so the stub's auth-status marker is
# host-scoped, not the blank-host name a hostless origin would use.
( i=0; while ! grep -q 'waiting for reviews' "$TU/u58.log" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
  echo "broken login" > "$TU/stub/gh-auth-status-fake-forge-u58.test" ) &
FLIP58=$!
rc=0
( cd "$TU/u58code"; PATH="$P58" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 30 bash "$SCRIPT" "$TU/u58plan/todo.md" > "$TU/u58.log" 2>&1 ) || rc=$?
check "U58 exit" "$rc" "2"
check "U58 no claude launched" "$(wc -l < "$TU/u58launched" | tr -d ' ')" "0"
check "U58 auth status message" "$(grep -c 'auth status failed' "$TU/u58.log")" "1"
check "U58 report still printed" "$([ "$(grep -c 'Execution stats' "$TU/u58.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U58 no sync commit after break" "$(git -C "$TU/u58plan" log --oneline --grep='zero sync' | wc -l | tr -d ' ')" "0"
wait "$FLIP58" 2>/dev/null || true
rm -f "$TU/stub/gh-auth-status-fake-forge-u58.test" "$TU/stub/gh-list.out"
# U58 PASS — wait_for_reviews's own poll tick now re-runs the same $FORGE auth status probe the
# pre-launch re-check uses, ahead of sync-mrs — a token that dies mid-park is caught there
# instead of sync-mrs's `|| true` swallowing every failure silently forever; the park ends
# through the same IDFAIL/exit-2 closer validate-ids uses, report still printed, no claude
# launched, no `zero sync u58a` commit past the break (the control run above proves this exact
# fixture would have written one had sync-mrs been reached).
#
# U60 (the wait_for_dependency_clear sibling of U58) and U63 (the shared-probe absence check) are
# covered, in current form, by U-021-breaking-the-park.sh's own U60 and U63 — dropped here to
# avoid a stale duplicate; see that file for both.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
