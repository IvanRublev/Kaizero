#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=285s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-001-mr-mode-launch-refusals — the one-repository refusal, --doctor's own three, a dirty
# tree first, and no forge call under --local-merge.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-001-mr-mode-launch-refusals
#
# What a launch refuses once MR mode is the default, and what it must not do when it is opted
# out of. Two fixture repositories, plan (coordination, holds the todo) and code (target) — plus
# a local bare origin for the target, which has no host, so KAIZERO_FORGE is set for the
# whole scenario, the escape hatch it exists for. These cases never reach the doctor:
# KAIZERO_TEST_EMIT=1 stops the launch right after the banner, so the origin URL a fixture
# carries is never fetched.

TU="$TESTROOT/U-001-mr-mode-launch-refusals"; mkdir -p "$TU/bin" "$TU/stub"
# MR mode is the default, so every fixture target needs an origin a forge resolves
# from or the launch refuses before the case's own subject is reached. A github URL, never fetched
# (TEST_EMIT skips the doctor; the real-doctor cases use mkorigin instead).
mkrepo(){ mkdir -p "$1"; ( cd "$1" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git remote add origin "https://github.com/acme/$(basename "$1").git" ); }
mktodo(){ ( cd "$1" || exit 1; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }
# emit(): the --local-merge baseline launch — no origin read, local merge, exactly what a launch
# did before MR mode became the default.
emit(){ ( cd "$1" || exit 1; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1 ); }

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
NOFORGE="$(mkpath noforge claude flock git timeout jq)"                # gh/glab both missing

# doctor(): standalone bare --doctor from $1 (the target root) — the generic checks, the same
# origin/forge decision a launch makes, then exactly checks 1-8; no coordination repo, no todo,
# needed (none of these checks wants one).
# $PATH/$KAIZERO_FORGE inherited from the caller's env (the scenario-wide export below, or a
# per-case override prefixed onto the call: `PATH=... doctor "$dir"`).
doctor(){ ( cd "$1" || exit 1; rc=0; out=$(timeout 20 bash "$SCRIPT" --doctor 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }

export PATH="$ALLPATH" KAIZERO_FORGE=gh   # scenario-wide default; unset per-case for selection tests

# U1 — one-repository layout refuses at launch, before any side effect
mkrepo "$TU/u1"; mktodo "$TU/u1"
out=$( ( cd "$TU/u1" || exit 1; rc=0; o=$(KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" todo.md 2>&1) || rc=$?; echo "$o"; echo "RC=$rc" ) )
check "U1 refuses" "$(echo "$out" | grep -c 'needs a separate coordination repository')" "1"
check "U1 names todo+target" "$(echo "$out" | grep -c "'$TU/u1/todo.md' is inside the target '$TU/u1'")" "1"
check "U1 rc" "$(echo "$out" | grep RC=)" "RC=1"
# only the main one
check "U1 no worktree left" "$(git -C "$TU/u1" worktree list --porcelain | grep -c '^worktree' )" "1"
check "U1 no zero.sh" "$([ -f "$TU/u1/.git/zero.sh" ] && echo NO || echo yes)" "yes"
check "U1 remedy is --local-merge" "$(echo "$out" | grep -c 'run with --local-merge to merge locally instead')" "1"
check "U1 --local-merge runs it" "$(emit "$TU/u1" todo.md | grep -c 'Fork -> implement -> commit -> merge')" "1"
# a qualifying origin puts this one-repository launch in MR mode with no flag, and it refuses:
# exit 1, names the todo path and the target root, points at --local-merge, and nothing beyond
# the refusal message runs — one worktree record (the main one), no zero.sh written. The same
# launch with --local-merge is the way this layout keeps working.

# U10 — kaizero --doctor's own refusals and --doctor --local-merge
mkdir -p "$TU/u10-nogit"
out=$( ( cd "$TU/u10-nogit" || exit 1; rc=0; o=$(timeout 20 bash "$SCRIPT" --doctor 2>&1) || rc=$?; echo "$o"; echo "RC=$rc" ) )
check "U10 not a git repository" "$(echo "$out" | grep -c 'Not a git repository')" "1"

mkdir -p "$TU/u10-sub/sub"; ( cd "$TU/u10-sub" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test; git commit -q --allow-empty -m init )
out=$( ( cd "$TU/u10-sub/sub" || exit 1; rc=0; o=$(timeout 20 bash "$SCRIPT" --doctor 2>&1) || rc=$?; echo "$o"; echo "RC=$rc" ) )
check "U10 not at the main repo root" "$(echo "$out" | grep -c 'Not at the main repo root')" "1"

( cd "$TU/u10-sub" || exit 1; git checkout -q --detach )
out=$( ( cd "$TU/u10-sub" || exit 1; rc=0; o=$(timeout 20 bash "$SCRIPT" --doctor 2>&1) || rc=$?; echo "$o"; echo "RC=$rc" ) )
check "U10 detached HEAD" "$(echo "$out" | grep -c "Detached HEAD in the target repository '$TU/u10-sub' — check out the base branch first")" "1"

( cd "$TU/u10-sub" || exit 1; git checkout -q main )
out=$( ( cd "$TU/u10-sub" || exit 1; PATH=/usr/bin:/bin timeout 5 bash "$SCRIPT" --doctor --local-merge 2>&1 ); echo "RC=$?" )
# claude/flock still checked, so a bare PATH still refuses on those, never on gh/glab/jq
check "U10 --doctor --local-merge needs no forge CLI" "$(echo "$out" | grep -cE 'gh CLI|glab CLI|jq not found')" "0"

# git worktree list reports the physical root, so a launch dir reached through a
# symlink must be compared with pwd -P, not raw $PWD, or the root guard misfires here.
ln -s "$TU/u10-sub" "$TU/u10-sub-link"
out=$( ( cd "$TU/u10-sub-link" || exit 1; rc=0; o=$(timeout 20 bash "$SCRIPT" --doctor 2>&1) || rc=$?; echo "$o"; echo "RC=$rc" ) )
check "U10 symlinked launch dir not misidentified as off-root" "$(echo "$out" | grep -c 'not at the main repo root')" "0"

mkrepo "$TU/u10q-code"; mkrepo "$TU/u10q-plan"; mktodo "$TU/u10q-plan"
ln -s "$TU/u10q-code" "$TU/u10q-code-link"
out=$(emit "$TU/u10q-code-link" "$TU/u10q-plan/todo.md")
check "U10 symlinked launch dir, main guard, not misidentified as off-root" "$(echo "$out" | grep -c 'not at the main repo root')" "0"
check "U10 symlinked launch dir, main guard, still emits" "$(echo "$out" | grep -c '^Wrote ')" "1"
# the three refusals carry the exact words a real launch uses and fire before any origin is
# read; --doctor --local-merge never asks about gh/glab/jq; a launch dir reached through a
# symlink is never misidentified as off-root, in either the --doctor guard or the main launch
# guard.

# U11 — KAIZERO_TEST_EMIT: doctor skipped, dirty tree refused first, and the FORGE fallback
mkrepo "$TU/u11code"; mkrepo "$TU/u11plan"; mktodo "$TU/u11plan"
( cd "$TU/u11code" || exit 1; echo change >> f )
out=$( ( cd "$TU/u11code" || exit 1; rc=0; o=$(PATH="$NOFORGE" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" "$TU/u11plan/todo.md" 2>&1) || rc=$?; echo "$o"; echo "RC=$rc" ) )
check "U11 dirty target refused before any forge call" "$(echo "$out" | grep -c 'is dirty')" "1"
( cd "$TU/u11code" || exit 1; git checkout -q -- f )

mkrepo "$TU/u11code2"; mkrepo "$TU/u11plan2"; mktodo "$TU/u11plan2"
out=$( ( cd "$TU/u11code2" || exit 1; PATH="$NOFORGE" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" "$TU/u11plan2/todo.md" 2>&1 ) )
# it still gets to the emit
check "U11 no forge CLI/origin/network needed under TEST_EMIT" "$(echo "$out" | grep -c '^Wrote ')" "1"
# KAIZERO_FORGE unset in this env, so gh is the fallback below
check "U11 FORGE=KAIZERO_FORGE when set" "$(grep -c "^FORGE='glab'" "$TU/u11plan2/.git/zero.sh")" "0"
check "U11 FORGE=gh fallback when unset" "$(grep -c "^FORGE=gh" "$TU/u11plan2/.git/zero.sh")" "1"
check "U11 banner names a forge" "$(echo "$out" | grep -c 'pull request (gh)')" "1"

mkrepo "$TU/u11code3"; mkrepo "$TU/u11plan3"; mktodo "$TU/u11plan3"
out=$( ( cd "$TU/u11code3" || exit 1; PATH="$NOFORGE" KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=glab timeout 20 bash "$SCRIPT" "$TU/u11plan3/todo.md" 2>&1 ) )
check "U11 KAIZERO_FORGE honored under TEST_EMIT" "$(grep -c '^FORGE=glab' "$TU/u11plan3/.git/zero.sh")" "1"
check "U11 banner names glab" "$(echo "$out" | grep -c 'merge request (glab)')" "1"
# a dirty tree refuses before any forge call in MR mode too; under KAIZERO_TEST_EMIT the
# whole doctor is skipped (no forge CLI, no origin, no network — PATH=/nonexistent proves it),
# and FORGE still resolves — from KAIZERO_FORGE when set, gh otherwise — so the bake line and
# the banner are always well-formed.

# U15 — absence check: under --local-merge, git fetch/gh/glab never fire; byte-identical elsewhere
mkdir -p "$TU/u15fail/bin"
for prog in gh glab; do printf '#!/usr/bin/env bash\necho "FAIL: %s invoked under --local-merge" >&2\nexit 9\n' "$prog" > "$TU/u15fail/bin/$prog"; chmod +x "$TU/u15fail/bin/$prog"; done
REALGIT="$(type -P git)"   # baked in below by value, never by PATH search — else "git" resolving
                              # back to this very wrapper (first on PATH) recurses forever
cat > "$TU/u15fail/bin/git" <<EOF
#!/usr/bin/env bash
case "\$1" in
  fetch|push|ls-remote|clone) echo "FAIL: git \$1 invoked under --local-merge" >&2; exit 9 ;;
esac
if [ "\$1" = remote ] && [ "\$2" = get-url ]; then echo "FAIL: origin read under --local-merge" >&2; exit 9; fi
exec "$REALGIT" "\$@"
EOF
chmod +x "$TU/u15fail/bin/git"
mkrepo "$TU/u15code"; mkrepo "$TU/u15plan"; mktodo "$TU/u15plan"
out=$( ( cd "$TU/u15code" || exit 1; PATH="$TU/u15fail/bin:$ALLPATH" KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$TU/u15plan/todo.md" 2>&1 ) )
check "U15 no fetch/gh/glab/origin read under --local-merge" "$(echo "$out" | grep -c FAIL)" "0"

mkrepo "$TU/u15b1"; mktodo "$TU/u15b1"
solo=$(emit "$TU/u15b1" todo.md)
check "U15 solo prompt unchanged (spot check, same shape as T21)" "$(echo "$solo" | grep -c '@@')" "0"
# a git/gh/glab that fails the run if invoked proves none of them fire under --local-merge, and
# that the flag short-circuits before any origin is read at all; the emitted prompt still
# carries no unresolved @@…@@ placeholder.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
