#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=285s
# shellcheck disable=SC1007
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-004-the-origin-decides-the-mode — no flag needed, --local-merge opts out, an unsupported
# origin refuses.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-004-the-origin-decides-the-mode
# Cross-references: U-026 -> tests/U-026-the-doctor-mirrors-the-origin-decision.sh
#
# The default: a GitHub or GitLab origin puts a launch in MR mode with no flag at all,
# --local-merge opts back into a same-repository merge, and a missing or unsupported origin
# refuses cleanly at launch — U-026 proves the diagnostic check makes the same decision. Two
# fixture repositories, plan (coordination, holds the todo) and code (target), each given an
# explicit origin URL naming the host under test.

TU="$TESTROOT/U-004-the-origin-decides-the-mode"; mkdir -p "$TU/bin" "$TU/stub"
# MR mode is the default, so every fixture target needs an origin a forge resolves
# from or the launch refuses before the case's own subject is reached. A github URL, never fetched
# (TEST_EMIT skips the doctor).
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

# U59 — the origin decides the mode with no flag passed; --local-merge opts out; a missing or
# unsupported origin refuses.
# No fetch/auth network call is needed to prove this — the origin/forge decision reads
# `git remote get-url origin` alone, at the very top of the launch, before KAIZERO_TEST_EMIT's
# doctor-skip is even consulted, so a plain mkrepo'd target with a remote set-url'd URL is
# enough. mkrepo already gives every fixture a github origin, so each case sets the one it wants.
mkrepo "$TU/u59code"; mkrepo "$TU/u59plan"; mktodo "$TU/u59plan"

git -C "$TU/u59code" remote set-url origin https://github.com/acme/repo.git
out=$( ( cd "$TU/u59code" || exit 1; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE= timeout 20 bash "$SCRIPT" "$TU/u59plan/todo.md" 2>&1 ) )
check "U59a github origin, no flag, lands as a gh pull request" "$(echo "$out" | grep -c 'pull request (gh)')" "1"

git -C "$TU/u59code" remote set-url origin https://gitlab.com/acme/repo.git
out=$( ( cd "$TU/u59code" || exit 1; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE= timeout 20 bash "$SCRIPT" "$TU/u59plan/todo.md" 2>&1 ) )
check "U59b gitlab origin, no flag, lands as a glab merge request" "$(echo "$out" | grep -c 'merge request (glab)')" "1"

git -C "$TU/u59code" remote set-url origin https://git.example.com/acme/api.git
out=$( ( cd "$TU/u59code" || exit 1; rc=0; o=$(KAIZERO_TEST_EMIT=1 KAIZERO_FORGE= timeout 20 bash "$SCRIPT" "$TU/u59plan/todo.md" 2>&1) || rc=$?; echo "$o"; echo "RC=$rc" ) )
check "U59c unsupported host refuses" "$(echo "$out" | grep -c "Unsupported forge 'git.example.com'")" "1"
check "U59c names the origin and the remedy" "$(echo "$out" | grep -c 'origin: https://git.example.com/acme/api.git.*--local-merge')" "1"
check "U59c rc" "$(echo "$out" | grep RC=)" "RC=1"
check "U59c no worktree or live marker left behind" "$(( $(git -C "$TU/u59code" worktree list --porcelain | grep -c '^worktree') - 1 + $(ls "$TU/u59code/.git/kaizero-instance" 2>/dev/null | wc -l | tr -d ' ') ))" "0"

out=$( ( cd "$TU/u59code" || exit 1; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=glab timeout 20 bash "$SCRIPT" "$TU/u59plan/todo.md" 2>&1 ) )
check "U59d the same self-hosted host resolves via KAIZERO_FORGE" "$(echo "$out" | grep -c 'merge request (glab)')" "1"

git -C "$TU/u59code" remote remove origin
out=$( ( cd "$TU/u59code" || exit 1; rc=0; o=$(KAIZERO_TEST_EMIT=1 KAIZERO_FORGE= timeout 20 bash "$SCRIPT" "$TU/u59plan/todo.md" 2>&1) || rc=$?; echo "$o"; echo "RC=$rc" ) )
check "U59e no origin refuses" "$(echo "$out" | grep -c "No 'origin' remote")" "1"
check "U59e says landing as a request is the default" "$(echo "$out" | grep -c 'landing as a merge/pull request is the default and needs one')" "1"
check "U59e names --local-merge as the remedy" "$(echo "$out" | grep -c 'run with --local-merge to merge locally instead')" "1"
check "U59e warns it merges with no review" "$(echo "$out" | grep -c 'no review step, review the commits it produces afterward')" "1"
check "U59e rc" "$(echo "$out" | grep RC=)" "RC=1"
check "U59e no worktree or live marker left behind" "$(( $(git -C "$TU/u59code" worktree list --porcelain | grep -c '^worktree') - 1 + $(ls "$TU/u59code/.git/kaizero-instance" 2>/dev/null | wc -l | tr -d ' ') ))" "0"

out=$( ( cd "$TU/u59code" || exit 1; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE= timeout 20 bash "$SCRIPT" --local-merge "$TU/u59plan/todo.md" 2>&1 ) )
check "U59f --local-merge with NO origin at all still merges locally" "$(echo "$out" | grep -c 'Fork -> implement -> commit -> merge')" "1"

git -C "$TU/u59code" remote add origin https://github.com/acme/repo.git
out=$( ( cd "$TU/u59code" || exit 1; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE= timeout 20 bash "$SCRIPT" --local-merge "$TU/u59plan/todo.md" 2>&1 ) )
check "U59g --local-merge overrides a qualifying origin back to local" "$(echo "$out" | grep -c 'Fork -> implement -> commit -> merge')" "1"

# a same-repository layout with a qualifying origin: MR mode by default, and MR mode refuses it.
mkrepo "$TU/u59same"; ( cd "$TU/u59same" || exit 1; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo )
out=$( ( cd "$TU/u59same" || exit 1; rc=0; o=$(KAIZERO_TEST_EMIT=1 KAIZERO_FORGE= timeout 20 bash "$SCRIPT" todo.md 2>&1) || rc=$?; echo "$o"; echo "RC=$rc" ) )
check "U59h same-repo + qualifying origin refuses by default" "$(echo "$out" | grep -c 'MR mode needs a separate coordination repository')" "1"
check "U59h remedy is --local-merge" "$(echo "$out" | grep -c 'run with --local-merge to merge locally instead')" "1"
check "U59h rc" "$(echo "$out" | grep RC=)" "RC=1"
out=$( ( cd "$TU/u59same" || exit 1; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE= timeout 20 bash "$SCRIPT" --local-merge todo.md 2>&1 ) )
check "U59h --local-merge is how that layout runs" "$(echo "$out" | grep -c 'Fork -> implement -> commit -> merge')" "1"

# the decision runs FIRST: a dirty tree and a detached HEAD are both reported only once the
# origin qualifies — with no origin, the origin refusal preempts them.
mkrepo "$TU/u59first"; mkrepo "$TU/u59firstplan"; mktodo "$TU/u59firstplan"
git -C "$TU/u59first" remote remove origin
( cd "$TU/u59first" || exit 1; echo change >> f )
out=$( ( cd "$TU/u59first" || exit 1; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE= timeout 20 bash "$SCRIPT" "$TU/u59firstplan/todo.md" 2>&1 ) )
check "U59j origin refusal precedes the dirty-tree guard" "$(echo "$out" | grep -c "No 'origin' remote")" "1"
check "U59j dirty-tree guard not reached" "$(echo "$out" | grep -c 'is dirty')" "0"
( cd "$TU/u59first" || exit 1; git checkout -q -- f; git checkout -q --detach )
out=$( ( cd "$TU/u59first" || exit 1; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE= timeout 20 bash "$SCRIPT" "$TU/u59firstplan/todo.md" 2>&1 ) )
check "U59j origin refusal precedes the detached-HEAD guard" "$(echo "$out" | grep -c "No 'origin' remote")" "1"
check "U59j detached-HEAD guard not reached" "$(echo "$out" | grep -c 'detached HEAD')" "0"
( cd "$TU/u59first" || exit 1; git checkout -q main )
# a github (a) or gitlab (b) origin, with no flag passed, lands tasks as requests and picks the
# matching forge purely from the host; a host on neither refuses by name (c) unless
# KAIZERO_FORGE resolves it (d); no origin at all refuses instead of silently merging locally
# (e), and both refusals leave no worktree and no instance marker behind; --local-merge merges
# locally with no origin at all (f) and overrides a qualifying one (g); a same-repository layout
# with a qualifying origin now refuses by default and names --local-merge as the way it keeps
# running (h); and the decision precedes every other startup check — the dirty-tree and
# detached-HEAD guards are never reached when the origin refuses first (j).
# U1 and U59 all report the wanted counts/values (U2 retired with the mode it covered).

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
