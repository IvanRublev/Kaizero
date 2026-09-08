#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=85s
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# `KAIZERO_FORGE= cmd` intentionally sets it empty for one call (unselects the forge).
# shellcheck disable=SC2164,SC1091,SC1007
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-026-the-doctor-mirrors-the-origin-decision — the diagnostic check mirrors the launch's
# default: bare --doctor decides on origin, --doctor --local-merge never reads one.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-026-the-doctor-mirrors-the-origin-decision
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
# Cross-references named in the body below: Scenario U-004 -> tests/U-004-the-origin-decides-the-mode.sh
#
# U-004-the-origin-decides-the-mode proves the launch's own origin/forge decision; this scenario
# proves --doctor makes the identical decision when run bare, and stays silent about origin
# entirely under --local-merge. A local bare `origin` for the target, which has no host, so
# KAIZERO_FORGE is set for the whole scenario, the escape hatch it exists for.

### Setup
TU="$TESTROOT/U-026-the-doctor-mirrors-the-origin-decision"; mkdir -p "$TU/bin" "$TU/stub"

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

# closed PATH set — never the ambient $PATH, so this scenario's forge stub is always the one
# reached, never a real forge CLI. git, flock, timeout, jq are the only tools any case needs
# beyond /usr/bin:/bin's own coreutils.
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

# doctor(): standalone bare `--doctor` from $1 (the target root) — the generic checks, the same
# origin/forge decision a launch makes, then exactly checks 1-7; no coordination repo, no todo,
# needed (none of these checks wants one).
# $PATH/$KAIZERO_FORGE inherited from the caller's env (the scenario-wide export below, or a
# per-case override prefixed onto the call: `PATH=... doctor "$dir"`).
doctor(){ ( cd "$1"; rc=0; out=$(timeout 20 bash "$SCRIPT" --doctor 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }

export PATH="$ALLPATH" KAIZERO_FORGE=gh   # scenario-wide default; unset per-case for selection tests

### U60 — the diagnostic check mirrors the new default: bare `--doctor` decides on origin, `--doctor --local-merge` never reads one
mkorigin "$TU/u60"                                   # real, fetchable, no-host bare origin
out=$(KAIZERO_FORGE=gh doctor "$TU/u60")
check "U60 bare --doctor, resolvable origin, runs the forge checks" "$(echo "$out" | grep -c 'RC=0')" "1"
check "U60 bare --doctor fetched origin" "$([ -n "$(git -C "$TU/u60" rev-parse -q --verify refs/remotes/origin/main)" ] && echo 1 || echo 0)" "1"

( cd "$TU/u60"; git remote set-url origin https://git.example.com/acme/api.git )
out=$(KAIZERO_FORGE= doctor "$TU/u60")
check "U60 bare --doctor, unsupported origin, refuses with the launch's own words" "$(echo "$out" | grep -c "Unsupported forge 'git.example.com'")" "1"
check "U60 rc" "$(echo "$out" | grep RC=)" "RC=1"

( cd "$TU/u60"; git remote remove origin )
out=$(KAIZERO_FORGE= doctor "$TU/u60")
check "U60 bare --doctor, no origin, refuses with the launch's own words" "$(echo "$out" | grep -c 'landing as a merge/pull request is the default and needs one')" "1"
check "U60 names --local-merge" "$(echo "$out" | grep -c 'run with --local-merge to merge locally instead')" "1"
check "U60 rc" "$(echo "$out" | grep RC=)" "RC=1"

# --local-merge: generic checks only, silent about origin in every one of the three cases.
lmdoctor(){ ( cd "$1"; rc=0; out=$(timeout 20 bash "$SCRIPT" --doctor --local-merge 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }
for u60case in none unsupported good; do
  case "$u60case" in
    none)        ( cd "$TU/u60"; git remote remove origin 2>/dev/null || true ) ;;
    unsupported) ( cd "$TU/u60"; git remote add origin https://git.example.com/acme/api.git ) ;;
    good)        ( cd "$TU/u60"; git remote set-url origin https://github.com/acme/api.git ) ;;
  esac
  out=$(KAIZERO_FORGE= lmdoctor "$TU/u60")
  check "U60 --doctor --local-merge ($u60case): silent about origin, all OK" "$(echo "$out" | grep -c 'All prerequisites OK')" "1"
  check "U60 --doctor --local-merge ($u60case): says nothing about origin" "$(echo "$out" | grep -c "origin")" "0"
done
# U60 PASS — run bare, the diagnostic check makes exactly the decision a launch makes: the forge
# checks (including the base fetch) on a resolvable origin, and otherwise the launch's own two
# refusals, word for word. --doctor --local-merge stops at the generic checks and never reads an
# origin, whatever the repository's origin happens to be.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
