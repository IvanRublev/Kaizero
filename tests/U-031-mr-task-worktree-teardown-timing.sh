#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-031-mr-task-worktree-teardown-timing — `mr_task` tears its target worktree down at land-time,
# and `sync_mrs`'s merged-branch delete tolerates a failed worktree lookup.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-031-mr-task-worktree-teardown-timing
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# Two fixture repositories, `plan` (coordination, holds the todo) and `code` (target) — plus a
# local bare `origin` for the target, which has no host, so KAIZERO_FORGE is set for the
# whole scenario, the escape hatch it exists for.

# --- Setup ---
TU="$TESTROOT/U-031-mr-task-worktree-teardown-timing"; mkdir -p "$TU/bin" "$TU/stub"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git remote add origin "https://github.com/acme/$(basename "$1").git" ); }

mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1"; git config user.email t@t.t; git config user.name test )
}

printf '#!/usr/bin/env bash\nprintf "ARGV: %%s\\n" "$*"\nexit 0\n' > "$TU/bin/claude"; chmod +x "$TU/bin/claude"

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
ALLPATH="$(mkpath all claude flock git timeout gh glab jq)"

export PATH="$ALLPATH" KAIZERO_FORGE=gh

# U45 — `mr_task` tears its target worktree down at land-time (BUG-039r), and `sync_mrs`'s
# merged-branch delete tolerates a failed worktree lookup
mkorigin "$TU/u45code"; mkrepo "$TU/u45plan"
( cd "$TU/u45plan"; printf -- '- [ ] u45a fix the gizmo\n- [ ] u45b fix the sprocket\n' > todo.md
  mkdir -p tasks
  printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/u45a.md
  printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/u45b.md
  git add -A; git commit -qm todo )
( cd "$TU/u45code"; PATH="$TU/bin:$PATH" KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$TU/u45plan/todo.md" >/dev/null 2>&1 )
zsh="$TU/u45plan/.git/zero.sh"; url=$(printf '%q' "$TU/u45code-origin.git")
sed -i.bak "s#^ORIGIN_URL=.*#ORIGIN_URL=$url#" "$zsh"; rm -f "$zsh.bak"
printf 'https://example.invalid/pr/45\n' > "$TU/stub/gh-create.out"

# u45a: a whole `mr` landing, then check the target worktree the moment it lands — no waiting
# for `sync-mrs` to find the request merged.
cat > "$TU/u45adrive.sh" <<'DRIVE'
set -uo pipefail
REC="$TU/u45a.rec"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
export PATH="$TU/bin:$PATH"
cd "$TU/u45plan"
FAILED=0; ERRORED=0
twt=$(bash .git/zero.sh claim u45a)
echo "$twt" > "$TU/u45a-twt"
git -C "$twt" symbolic-ref --short HEAD > "$TU/u45a-branch"
echo hi >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "U45a change" >/dev/null
bodyfile=$(bash .git/zero.sh mr-body-path u45a)
printf 'U45a request body\n' > "$bodyfile"
out=$(bash .git/zero.sh mr u45a "$twt"); rcm=$?
check "U45a mr exit" "$rcm" "0"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TU="$TU" bash "$TU/u45adrive.sh" || FAILED=1

u45atwt=$(cat "$TU/u45a-twt"); u45abranch=$(cat "$TU/u45a-branch")
check "U45a target worktree gone right after mr" "$(git -C "$TU/u45code" worktree list | grep -c -F "$u45atwt")" "0"
check "U45a branch still present, request open" "$(git -C "$TU/u45code" rev-parse -q --verify "$u45abranch" >/dev/null 2>&1 && echo present || echo gone)" "present"

# request lands merged — sync-mrs reports the branch deleted, with no leaked worktree left for
# `branch -D` to fight over (mr_task already cleared it at land-time).
u45asha=$(git -C "$TU/u45code" rev-parse "$u45abranch")
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":45,"headRefOid":"$u45asha","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/45"}]
JSON
out=$(PATH="$TU/bin:$PATH" bash "$zsh" sync-mrs 2>&1)
check "U45a sync reports branch deleted" "$(printf '%s' "$out" | grep -c "sync u45a: merged → \[x\] (https://example.invalid/pr/45) . branch $u45abranch deleted")" "1"
check "U45a branch actually gone" "$(git -C "$TU/u45code" rev-parse -q --verify "$u45abranch" >/dev/null 2>&1 && echo present || echo gone)" "gone"
rm -f "$TU/stub/gh-list.out"

# u45b: same landing, but this time `worktree list` on the target itself fails outright — the
# merged case must still run to completion (box lands, branch goes, no merge-inflight marker
# survives) rather than dying mid-pass on an unguarded assignment. A real
# `bash .git/zero.sh sync-mrs` SUBPROCESS, not an in-process function call: bash never inherits
# `errexit` into a `$(...)` command substitution unless `shopt -s inherit_errexit` is set, so a
# function called as `out=$(sync_mrs)` in-process would silently swallow this exact failure —
# only a real process boundary, with `set -euo pipefail` live at its own top, reproduces it.
cat > "$TU/u45bdrive.sh" <<'DRIVE'
set -uo pipefail
REC="$TU/u45b.rec"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
export PATH="$TU/bin:$PATH"
cd "$TU/u45plan"
twt=$(bash .git/zero.sh claim u45b)
git -C "$twt" symbolic-ref --short HEAD > "$TU/u45b-branch"
echo hi >> "$twt/f"; git -C "$twt" add -A; git -C "$twt" commit -qm "U45b change" >/dev/null
bodyfile=$(bash .git/zero.sh mr-body-path u45b)
printf 'U45b request body\n' > "$bodyfile"
bash .git/zero.sh mr u45b "$twt" >/dev/null
DRIVE
# shellcheck disable=SC2097,SC2098
TU="$TU" bash "$TU/u45bdrive.sh"

u45bbranch=$(cat "$TU/u45b-branch")
u45bsha=$(git -C "$TU/u45code" rev-parse "$u45bbranch")
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":46,"headRefOid":"$u45bsha","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/46"}]
JSON
# a `git` shim, ahead of the real one on PATH, that fails only `-C "$TU/u45code" worktree list` —
# the exact call `wt_for_branch_in` makes — and delegates every other invocation untouched.
REALGIT="$(type -P git)"
mkdir -p "$TU/bin-fakegit"
cat > "$TU/bin-fakegit/git" <<GITSTUB
#!/usr/bin/env bash
if [ "\$1" = -C ] && [ "\$2" = "$TU/u45code" ] && [ "\$3" = worktree ] && [ "\$4" = list ]; then
  echo "fake-git: worktree list forced to fail" >&2
  exit 1
fi
exec "$REALGIT" "\$@"
GITSTUB
chmod +x "$TU/bin-fakegit/git"

out=$(PATH="$TU/bin-fakegit:$TU/bin:$PATH" bash "$zsh" sync-mrs 2>"$TU/u45berr"); rc=$?
check "U45b sync_mrs exits 0 despite failed lookup" "$rc" "0"
check "U45b still reports branch deleted" "$(printf '%s' "$out" | grep -c "sync u45b: merged → \[x\] (https://example.invalid/pr/46) . branch $u45bbranch deleted")" "1"
check "U45b box reached x" "$(bash "$zsh" box-symbol-on-base u45b)" "x"
check "U45b no merge-inflight marker left" "$([ -f "$TU/u45plan/.git/merge-inflight" ] && echo no || echo yes)" "yes"
rm -f "$TU/stub/gh-list.out" "$TU/stub/gh-create.out"
# U45 PASS — `mr_task`'s success path removes the target worktree the moment a request opens
# (`git worktree list` no longer names it) while its branch survives untouched, since the branch
# is not yet an ancestor of the target base; a later `sync-mrs` on that same request finding it
# merged then reports the branch deleted, never kept, because there is no leaked worktree left to
# block `branch -D`; and when the merged case's own target-worktree lookup fails outright,
# `sync_mrs` still runs to completion — box ticked, branch gone, no `merge-inflight` marker left
# behind — instead of dying mid-pass on an unguarded command substitution under `errexit`.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
