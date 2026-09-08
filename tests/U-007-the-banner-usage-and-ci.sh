#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=85s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-007-the-banner-usage-and-ci — the banner's three forms, usage()/-h, the review env vars it
# documents, and the CI job.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-007-the-banner-usage-and-ci
#
# What a launch prints and what the project documents about it: the banner's three forms, the
# help screen's --local-merge/MR-mode-as-default wording and its KAIZERO_REVIEW_WAIT/
# KAIZERO_REVIEW_POLL entries, and the CI job that installs glab and asserts jq. Two fixture
# repositories, plan (coordination, holds the todo) and code (target) — plus a local bare origin
# for the target, which has no host, so KAIZERO_FORGE is set for the whole scenario, the
# escape hatch it exists for.

TU="$TESTROOT/U-007-the-banner-usage-and-ci"; mkdir -p "$TU/bin" "$TU/stub"
# MR mode is the default, so every fixture target needs an origin a forge resolves
# from or the launch refuses before the case's own subject is reached. A github URL, never fetched
# (TEST_EMIT skips the doctor; the real-doctor cases use mkorigin instead).
mkrepo(){ mkdir -p "$1"; ( cd "$1" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git remote add origin "https://github.com/acme/$(basename "$1").git" ); }
mktodo(){ ( cd "$1" || exit 1; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }

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

# U13 — the banner's three forms
mkrepo "$TU/u13code"; mkrepo "$TU/u13plan"; mktodo "$TU/u13plan"
out=$( ( cd "$TU/u13code" || exit 1; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$TU/u13plan/todo.md" 2>&1 ) )
check "U13 plain merge" "$(echo "$out" | grep -c 'Fork -> implement -> commit -> merge')" "1"

mkrepo "$TU/u13code2"; mkrepo "$TU/u13plan2"; mktodo "$TU/u13plan2"
out=$( ( cd "$TU/u13code2" || exit 1; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$TU/u13plan2/todo.md" 2>&1 ) )
check "U13 gh pull request" "$(echo "$out" | grep -c 'pull request (gh)')" "1"

mkrepo "$TU/u13code3"; mkrepo "$TU/u13plan3"; mktodo "$TU/u13plan3"
out=$( ( cd "$TU/u13code3" || exit 1; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=glab timeout 20 bash "$SCRIPT" "$TU/u13plan3/todo.md" 2>&1 ) )
check "U13 glab merge request" "$(echo "$out" | grep -c 'merge request (glab)')" "1"

# U14 — usage()/-h
out=$(bash "$SCRIPT" -h)
check "U14 synopsis has --local-merge" "$(echo "$out" | grep -c '^usage:.*\[--local-merge\]')" "1"
# want >=1
check "U14 --local-merge option line" "$([ "$(echo "$out" | grep -c -- '--local-merge  ')" -ge 1 ] && echo yes || echo no)" "yes"
check "U14 --local-merge no-review warning" "$([ "$(echo "$out" | grep -c 'no review step')" -ge 1 ] && echo yes || echo no)" "yes"
check "U14 --doctor --local-merge" "$(echo "$out" | grep -c -- '--doctor --local-merge')" "1"
check "U14 MR mode named as the default" "$(echo "$out" | grep -c 'Default mode: MR mode')" "1"
# the help screen names --local-merge and MR-mode-as-default, and warns that --local-merge
# merges with no review step.

# U16 — CI: glab install + jq assertion + weekly schedule
check "U16 glab install step" "$([ "$(grep -c 'glab' "$REPO/.github/workflows/ci.yml")" -ge 1 ] && echo yes || echo no)" "yes"
check "U16 jq assertion step" "$([ "$(grep -c 'jq' "$REPO/.github/workflows/ci.yml")" -ge 1 ] && echo yes || echo no)" "yes"
check "U16 weekly schedule" "$(grep -c 'schedule:' "$REPO/.github/workflows/ci.yml")" "1"
check "U16 cron present" "$(grep -c 'cron:' "$REPO/.github/workflows/ci.yml")" "1"

# U31 — README.md documents KAIZERO_REVIEW_WAIT/KAIZERO_REVIEW_POLL
# -h/--help itself only inlines four variables and says the rest — including these two,
# MR-mode-only — are "in README.md" (kaizero.sh's own usage()), so this checks the doc they
# were deliberately pushed to rather than the CLI banner.
D="$(cat "$REPO/README.md")"
check "U31 names REVIEW_WAIT" "$(printf '%s' "$D" | grep -c 'KAIZERO_REVIEW_WAIT=duration')" "1"
check "U31 names REVIEW_POLL" "$(printf '%s' "$D" | grep -c 'KAIZERO_REVIEW_POLL=duration')" "1"
check "U31 unset = unbounded" "$(printf '%s' "$D" | grep -c 'parks with no ceiling')" "1"
check "U31 0 = never parks" "$(printf '%s' "$D" | grep -c '\`0\` never parks')" "1"
# a wider window would also catch the usage example's own 5m
check "U31 poll default named" "$(printf '%s\n' "$D" | grep -A2 'KAIZERO_REVIEW_POLL=duration' | grep -c '5m')" "1"

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
