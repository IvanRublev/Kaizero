#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=35s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-003-the-launch-fetch — the refspec a launch names explicitly, and its two failure messages.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-003-the-launch-fetch
#
# The one fetch a launch runs before anything forks off origin/<base>: it names
# refs/remotes/origin/<base> explicitly rather than trusting a clone's own refspec, and a base
# absent from origin — including an empty remote — names the branch it could not find. Two
# fixture repositories, plan (coordination, holds the todo) and code (target) — plus a local
# bare origin for the target, which has no host, so KAIZERO_FORGE is set for the whole
# scenario, the escape hatch it exists for.

TU="$TESTROOT/U-003-the-launch-fetch"; mkdir -p "$TU/bin" "$TU/stub"

# target repo cloned from a local bare origin — real, fetchable, no host. $1 = target dir.
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1" || exit 1; git config user.email t@t.t; git config user.name test )
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

# doctor(): standalone bare --doctor from $1 (the target root) — the generic checks, the same
# origin/forge decision a launch makes, then exactly checks 1-8; no coordination repo, no todo,
# needed (none of these checks wants one).
# $PATH/$KAIZERO_FORGE inherited from the caller's env (the scenario-wide export below, or a
# per-case override prefixed onto the call: `PATH=... doctor "$dir"`).
doctor(){ ( cd "$1" || exit 1; rc=0; out=$(timeout 20 bash "$SCRIPT" --doctor 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }

export PATH="$ALLPATH" KAIZERO_FORGE=gh   # scenario-wide default; unset per-case for selection tests

# U8 — the launch fetch names the refspec explicitly: proven in a single-branch clone
mkdir -p "$TU/u8-seed"; ( cd "$TU/u8-seed" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git checkout -q -b other; git commit -q --allow-empty -m other )
git clone -q --bare "$TU/u8-seed" "$TU/u8-origin.git"
git clone -q --branch other --single-branch "$TU/u8-origin.git" "$TU/u8"
( cd "$TU/u8" || exit 1; git config user.email t@t.t; git config user.name test; git checkout -q -b main )
pre=$( cd "$TU/u8" || exit 1; git rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1 && echo yes || echo no )
out=$(doctor "$TU/u8")
post=$( cd "$TU/u8" || exit 1; git rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1 && echo yes || echo no )
check "U8 ref absent before the doctor's fetch" "$pre" "no"
check "U8 ref created by the doctor's fetch" "$post" "yes"
# the base diverges from the branch this clone started on, but check 8 only warns, never gates
check "U8 doctor RC" "$(echo "$out" | grep RC=)" "RC=0"
# refs/remotes/origin/<base> does not exist beforehand in a --single-branch clone of another
# branch, and the doctor's explicit-refspec fetch creates it.

# U9 — the launch fetch's two failure messages
git init -q --bare "$TU/u9-empty-origin.git"
mkdir -p "$TU/u9"; ( cd "$TU/u9" || exit 1; git init -q -b main; git remote add origin "$TU/u9-empty-origin.git"
  git config user.email t@t.t; git config user.name test; git commit -q --allow-empty -m init )
out=$(doctor "$TU/u9")
pat="'main' is not on origin in $TU/u9"
check "U9 missing base names the branch" "$(echo "$out" | grep -cF -- "$pat")" "1"
check "U9 names the upstream-setting fix" "$(echo "$out" | grep -c 'git push -u origin main')" "1"

mkorigin "$TU/u9b"
zap "$TU/u9b-origin.git"   # origin now unreachable: any OTHER fetch failure
out=$(doctor "$TU/u9b")
check "U9 other fetch failure names git's own stderr" "$(echo "$out" | grep -c 'Fetch of origin/main failed')" "1"
# a base absent from origin (including an empty remote) names the branch and the -u-setting push
# that fixes it; any other fetch failure carries git's own stderr.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
