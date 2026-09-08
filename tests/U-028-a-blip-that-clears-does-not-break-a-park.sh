#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=250s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-028-a-blip-that-clears-does-not-break-a-park — a blip that clears before forge_auth_ok's
# retries run out, and a transient, non-auth sync-mrs failure that does not stop a park either.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-028-a-blip-that-clears-does-not-break-a-park
# Wall-clock budget: its longest Run command is `timeout 70` — allow that command at least 70s
#
# wait_for_reviews/wait_for_dependency_clear's MR-mode behaviours live in kaizero.sh's own
# run_loop, not in the emitted zero.sh — zero_funcs/KAIZERO_TEST_EMIT can't reach them, so the
# cases below run the real doctor and the real restart loop: a real, fetchable, no-host bare
# origin (mkorigin) for the target, a plain mkrepo for the coordination repo, and a controllable
# stub claude rebuilt per case via mkpath (a snapshot copy, so each case's $TU/bin/claude must be
# written before its own mkpath call).
#
# The one way a park does NOT end: a login probe that fails once and clears again before
# forge_auth_ok's own retries are exhausted, proven at a wait_for_reviews park; and a transient,
# non-auth sync-mrs failure (gh pr list itself fails, login healthy) that does not stop a park
# either, proven at both a wait_for_reviews park and a wait_for_dependency_clear park.

### Setup
TU="$TESTROOT/U-028-a-blip-that-clears-does-not-break-a-park"; mkdir -p "$TU/bin" "$TU/stub"
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

### U59 — a network blip that clears within `forge_auth_ok`'s own retries never reaches the closer (BUG-047)
mkorigin "$TU/u59code"; mkrepo "$TU/u59plan"
( cd "$TU/u59code"; git checkout -qb u59a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u59plan"; printf -- '- [\xe2\x86\x91] u59a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":59,"headRefOid":"zzz","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/59"}]
JSON
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u59launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u59launched"
P59=$(mkpath u59 claude flock git timeout gh glab jq)
rm -f "$TU/stub/gh-auth-status-"
( i=0; while ! grep -q 'Waiting for reviews' "$TU/u59.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
  echo "connection reset" > "$TU/stub/gh-auth-status-"
  sleep 3
  rm -f "$TU/stub/gh-auth-status-" ) &
FLIP59=$!
cd "$TU/u59code"
PATH="$P59" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s bash "$SCRIPT" "$TU/u59plan/todo.md" > "$TU/u59.log" 2>&1 &
WPID=$!
i=0; while [ "$i" -lt 120 ] && ! grep -q 'auth status failed\|execution stats' "$TU/u59.log" 2>/dev/null; do sleep 0.5; i=$((i+1)); done
kill -TERM "$WPID" 2>/dev/null
i=0; while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
kill -0 "$WPID" 2>/dev/null && kill -KILL "$WPID" 2>/dev/null
wait "$WPID" 2>/dev/null || true
check "U59 no claude launched" "$(wc -l < "$TU/u59launched" | tr -d ' ')" "0"
check "U59 auth status message" "$(grep -c 'auth status failed' "$TU/u59.log")" "0"
check "U59 still parking after blip" "$([ "$(grep -c 'Waiting for reviews' "$TU/u59.log")" -ge 2 ] && echo yes || echo no)" "yes"
wait "$FLIP59" 2>/dev/null || true
rm -f "$TU/stub/gh-auth-status-" "$TU/stub/gh-list.out"
# U59 PASS — forge_auth_ok's retries (three tries, two seconds apart) absorb a login probe that
# fails once and clears again before they're exhausted: no "auth status failed" message, no
# closer, the park keeps polling past the blip exactly as it would have with no blip at all — the
# fleet stays up through an outage BUG-047 used to make fatal.

### U61 — a transient, non-auth `sync-mrs` failure (`gh pr list` itself fails, login healthy) does not stop a `wait_for_reviews` park
mkorigin "$TU/u61code"; mkrepo "$TU/u61plan"
( cd "$TU/u61code"; git checkout -qb u61a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u61plan"; printf -- '- [\xe2\x86\x91] u61a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
: > "$TU/u61launched"
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u61launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
P61=$(mkpath u61 claude flock git timeout gh glab jq)
rm -f "$TU/stub/gh-list" "$TU/stub/gh-auth-status-"
echo "connection reset" > "$TU/stub/gh-list"
( cd "$TU/u61code"; PATH="$P61" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 56 bash "$SCRIPT" "$TU/u61plan/todo.md" > "$TU/u61.log" 2>&1 ) || true
check "U61 no claude launched" "$(wc -l < "$TU/u61launched" | tr -d ' ')" "0"
check "U61 auth status message" "$(grep -c 'auth status failed' "$TU/u61.log")" "0"
check "U61 still parking" "$([ "$(grep -c 'Waiting for reviews' "$TU/u61.log")" -ge 2 ] && echo yes || echo no)" "yes"
rm -f "$TU/stub/gh-list"
# U61 PASS — forge_auth_ok alone cannot distinguish a dead token from a `gh pr list` blip: with
# login healthy and only `list` failing, the probe passes, `sync-mrs` fails and is swallowed by
# its own `|| true` exactly as before this fix, no "auth status failed" line appears, and the
# park keeps polling.

### U62 — a transient, non-auth `sync-mrs` failure (`gh pr list` fails, login healthy) does not stop a `wait_for_dependency_clear` park
mkorigin "$TU/u62code"; mkrepo "$TU/u62plan"
( cd "$TU/u62code"; git checkout -qb u62a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u62plan"; printf -- '- [\xe2\x86\x91] u62a fix thing\n- [ ] u62b needs u62a\n' > todo.md; git add todo.md; git commit -qm todo )
: > "$TU/u62launched"
cat > "$TU/bin/claude" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$TU/u62launched"
n=\$(wc -l < "$TU/u62launched" | tr -d ' ')
[ "\$n" -eq 1 ] && "$TU/u62plan/.git/zero.sh" no-claim-mark
exit 0
EOF
chmod +x "$TU/bin/claude"
P62=$(mkpath u62 claude flock git timeout gh glab jq)
rm -f "$TU/stub/gh-list" "$TU/stub/gh-auth-status-"
echo "connection reset" > "$TU/stub/gh-list"
( cd "$TU/u62code"; PATH="$P62" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 70 bash "$SCRIPT" "$TU/u62plan/todo.md" > "$TU/u62.log" 2>&1 ) || true
# the block, none after; still parked when timeout hits
check "U62 exactly one launch" "$(wc -l < "$TU/u62launched" | tr -d ' ')" "1"
check "U62 auth status message" "$(grep -c 'auth status failed' "$TU/u62.log")" "0"
check "U62 still parking" "$([ "$(grep -c 'Waiting for reviews' "$TU/u62.log")" -ge 2 ] && echo yes || echo no)" "yes"
rm -f "$TU/stub/gh-list"
# U62 PASS — same distinction as U61, proven at the sibling park: a `list`-only failure with
# login healthy never reaches the `auth status failed` message, and the block stays parked on the
# marker instead of ending.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
