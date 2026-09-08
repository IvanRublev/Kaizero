#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-030-a-whole-mr-landing — the request one landing opens.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-030-a-whole-mr-landing
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# A whole landing opens the request with the todo line's own title while the operator's checkout
# stays dirty on a foreign branch throughout. Two fixture repositories, `plan` (coordination, holds
# the todo) and `code` (target) — plus a local bare `origin` for the target, which has no host, so
# KAIZERO_FORGE is set for the whole scenario, the escape hatch it exists for.

# --- Setup ---
TU="$TESTROOT/U-030-a-whole-mr-landing"; mkdir -p "$TU/bin" "$TU/stub"
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
# check 8 (TASK-049) calls `<verb> --help` on the resolved forge and greps its output for
# each flag mr_list/mr_create pass — so `--help` answers with the real default flag list per
# prog+verb, unless `<prog>-<verb>-help.txt` exists, which is cat'd verbatim instead.
for prog in gh glab; do
case "$prog" in
  gh)   listflags="--head --state --limit --json"; createflags="--head --base --title --body-file" ;;
  glab) listflags="--source-branch --all --output --per-page --order --sort"
        createflags="--source-branch --target-branch --title --description --yes" ;;
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
if [ "\$is_help" = 1 ] && [ -n "\$verb" ] && [ "\$verb" != auth-status ]; then
  helpfile="$TU/stub/$prog-\$verb-help.txt"
  if [ -f "\$helpfile" ]; then cat "\$helpfile"; exit 0; fi
  if [ "\$verb" = list ]; then printf '%s\n' $listflags; else printf '%s\n' $createflags; fi
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

# U44 — a whole MR-mode landing: the request title, a dirty foreign-branch operator checkout
# throughout, and the same generic credit a local merge gets
mkorigin "$TU/u44code"; mkrepo "$TU/u44plan"
( cd "$TU/u44plan"; printf -- '- [ ] u44a fix the widget\n' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/u44a.md
  git add -A; git commit -qm todo )
( cd "$TU/u44code"; PATH="$TU/bin:$PATH" KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$TU/u44plan/todo.md" >/dev/null 2>&1 )
zsh="$TU/u44plan/.git/zero.sh"; url=$(printf '%q' "$TU/u44code-origin.git")
sed -i.bak "s#^ORIGIN_URL=.*#ORIGIN_URL=$url#" "$zsh"; rm -f "$zsh.bak"
printf 'https://example.invalid/pr/44\n' > "$TU/stub/gh-create.out"

# the operator's own target checkout: on a foreign branch, dirty, throughout the whole run.
( cd "$TU/u44code"; git checkout -qb operator-was-here; echo dirty >> f )

# a separate KAIZERO_SESSION_RECORD identity is driven from its own bash subprocess, so its
# own FAILED/ERRORED stay local to it — check() is exported (test-setup.sh) so the driver can
# call it, and it ends the same way every scenario does so its exit status folds into ours below.
cat > "$TU/u44drive.sh" <<'DRIVE'
set -uo pipefail
export PATH="$TU/bin:$PATH"
REC="$TU/u44.rec"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
cd "$TU/u44plan"
FAILED=0; ERRORED=0
twt=$(bash .git/zero.sh claim u44a); rcc=$?
check "U44 claim exit" "$rcc" "0"
S=$(git -C "$twt" symbolic-ref --short HEAD)
echo "$S" > "$TU/u44-branch"
echo hi >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "U44 change" >/dev/null
bodyfile=$(bash .git/zero.sh mr-body-path u44a)
printf 'U44 request body\n' > "$bodyfile"
out=$(bash .git/zero.sh mr u44a "$twt"); rcm=$?
check "U44 mr exit" "$rcm" "0"
# the line an operator reads: the request's URL, then the box the Hand off left on the
# coordination base — never a landing, which is the reviewer's to make (docs/CONTEXT.md, **Hand off**)
check "U44 mr line is url + box + base" "$(printf '%s' "$out" | grep -cE 'https://example\.invalid/pr/44 opened from .*; box landed as \[↑\] on main; worktrees cleaned$')" "1"
# "box landed as [sym]" describes the coordination-base tick for every outcome, hand-off included
# (docs/CONTEXT.md draws Hand off vs Landing as a Task-level distinction, not a wording rule for
# this line) — the real thing to rule out is the request being reported as already merged.
check "U44 mr line claims no landing" "$(printf '%s' "$out" | grep -ci 'merged')" "0"
check "U44 box landed at ↑" "$(bash .git/zero.sh box-symbol-on-base u44a)" "↑"
# a [↑] box refuses the next claim like any filled box — and the refusal names the route that
# filled it, since no reviewer has merged anything yet (docs/CONTEXT.md, **Hand off**)
out2=$(bash .git/zero.sh claim u44a 2>&1); rc2=$?
check "U44 second claim refuses" "$rc2" "4"
check "U44 refusal names the hand off" "$(printf '%s' "$out2" | grep -c 'already landed or handed off')" "1"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
# exports TU into the driver's env for that one command (TU itself is never globally exported)
# shellcheck disable=SC2097,SC2098
TU="$TU" bash "$TU/u44drive.sh" || FAILED=1

check "U44 title is '<raw id> <title>'" "$(grep -c -- '--title u44a fix the widget' "$TU/stub/gh.argv")" "1"
check "U44 operator checkout still dirty" "$(git -C "$TU/u44code" status --porcelain | grep -c '^.M f')" "1"
check "U44 operator checkout own branch" "$([ "$(git -C "$TU/u44code" symbolic-ref --short HEAD)" = operator-was-here ] && echo yes || echo no)" "yes"

# an `mr` landing credits the same generic counters a local merge does — read straight from the
# files rather than through print_report/print_fleet_total, which need a whole session's worth
# of state (INSTANCE_ID, a live report call) this focused case has no need to stand up.
donefile="$TU/u44plan/.git/todos-done-main-shared"
check "U44 add_todos_done credited an mr landing" "$(cat "$donefile" 2>/dev/null || echo 0)" "1"

# sync-mrs then reads that same request as merged, exactly as any other landing — via the real
# subcommand, not zero_funcs, so this exercises MERGE_LOCK exactly as an operator's own run would.
u44sha=$(git -C "$TU/u44code" rev-parse "$(cat "$TU/u44-branch")")
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":44,"headRefOid":"$u44sha","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/44"}]
JSON
out=$(PATH="$TU/bin:$PATH" bash "$zsh" sync-mrs 2>&1)
check "U44 sync exit" "$?" "0"
check "U44 sync landed it merged -> [x]" "$(bash "$zsh" box-symbol-on-base u44a)" "x"
check "U44 branch deleted once landed" "$(git -C "$TU/u44code" rev-parse -q --verify u44a-fix-the-widget >/dev/null 2>&1 && echo present || echo gone)" "gone"
rm -f "$TU/stub/gh-list.out" "$TU/stub/gh-create.out"
# U44 PASS — the `mr` line is the request URL then its box (`… /pull/44 [↑] on main`) and
# never says landed; the `[↑]` box it leaves refuses the next claim (`4`) with a refusal that names
# that route too; the request title is the todo line's own `<raw id> <title>`; the operator's target
# checkout stays dirty, on its own foreign branch, through claim, land and sync alike (nothing in
# MR mode reads or touches it); an `mr` landing credits `add_todos_done` exactly as a local
# merge does; and the same request, read back merged by `sync-mrs`, lands `[x]` and clears the
# branch after the landing itself has torn down the task worktree.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
