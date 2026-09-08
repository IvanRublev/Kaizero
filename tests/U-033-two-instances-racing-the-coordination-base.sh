#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-033-two-instances-racing-the-coordination-base — two instances racing the same coordination
# base.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-033-two-instances-racing-the-coordination-base
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# The todo rewrite under interference: two instances racing the same coordination base rewrite no
# box twice. `mrsetup` gives them a single real repo standing in for both roles — all they need is a
# real `COORD_GITDIR` and a real `TARGET_ROOT` — and the stub `gh`/`glab` supplies the canned JSON,
# the URL and the exit code each case wants back.

# --- Setup ---
TU="$TESTROOT/U-033-two-instances-racing-the-coordination-base"; mkdir -p "$TU/bin" "$TU/stub"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git remote add origin "https://github.com/acme/$(basename "$1").git" ); }
mktodo(){ ( cd "$1"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }
emit(){ ( cd "$1"; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1 ); }

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

# mrsetup <name>: a single real repo standing in for both COORD and TARGET (SAME_REPO=1) — all
# mr_list/mr_create need from it is a real, working COORD_GITDIR and ORIGIN_URL (both baked by zero.sh)
# and a real TARGET_ROOT (so the "never $TARGET_ROOT" cwd checks have something to compare
# against). Emitted with `emit()` (--local-merge — TEST_EMIT bakes ORIGIN_URL empty in MR
# mode regardless, since the doctor that would resolve it never runs), so FORGE/ORIGIN_URL are
# always overridden by the case itself, after sourcing, never read from the bake.
mrsetup(){ mkrepo "$TU/$1"; mktodo "$TU/$1"; emit "$TU/$1" todo.md >/dev/null; }

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

# U48 — two `sync_mrs` instances racing the same coordination base: one writes, the other finds
# nothing left to write, and no box is rewritten twice
cat > "$TU/u48inner.sh" <<'INNER'
set -euo pipefail
TU="$1" Z="$2"
zero_funcs(){
  local f="$1" tmp ln
  ln=$(grep -nF 'case "${1:-}" in' "$f" | head -1 | cut -d: -f1)
  tmp="$(mktemp)"; head -n "$((ln - 1))" "$f" > "$tmp"
  # shellcheck disable=SC1090
  . "$tmp"; rm -f "$tmp"
}
zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
rm -f "$TU/u48ready" "$TU/u48go"
# process A: its own forge query stalls (inside a subshell — the override must not leak into
# B's sibling call in the shared parent scope, or B deadlocks waiting on its own signal), so it
# computes the SAME now-stale verdict as B and only reaches MERGE_LOCK after B has already
# written the box and deleted the branch.
( eval "$(declare -f mr_list | sed '1s/^mr_list/real_mr_list/')"
  mr_list(){ : > "$TU/u48ready"; while [ ! -f "$TU/u48go" ]; do sleep 0.05; done; real_mr_list "$@"; }
  out=$(sync_mrs); printf '%s' "$out" > "$TU/u48a.out" ) &
pidA=$!
i=0; while [ ! -f "$TU/u48ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
out=$(sync_mrs); printf '%s' "$out" > "$TU/u48b.out"
: > "$TU/u48go"
wait "$pidA"
box_symbol_on_base u48a > "$TU/u48_box" 2>/dev/null || echo "?" > "$TU/u48_box"
git -C "$TARGET_ROOT" rev-parse -q --verify u48a-fix-thing >/dev/null 2>&1 && echo present > "$TU/u48_branch" || echo gone > "$TU/u48_branch"
git -C "$COORD_ROOT" log --oneline --grep='zero sync u48a' > "$TU/u48_commits"
INNER

mrsetup u48
( cd "$TU/u48"
  git checkout -qb u48a-fix-thing; echo y > g; git add g; git commit -qm work
  git rev-parse HEAD > "$TU/u48a.sha"
  git checkout -q main
  printf '# todo\n\n- [\xe2\x86\x91] u48a fix thing\n' > todo.md
  git add todo.md; git commit -qm "mark u48a inflight"
)
Z="$TU/u48/.git/zero.sh"
u48sha=$(cat "$TU/u48a.sha")
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":70,"headRefOid":"$u48sha","baseRefName":"main","state":"MERGED","url":"https://x/70"}]
JSON
bash "$TU/u48inner.sh" "$TU" "$Z"
check "U48 B wrote the box" "$(cat "$TU/u48_box")" "x"
check "U48 B's commit line" "$(grep -c 'sync u48a: merged' "$TU/u48b.out")" "1"
check "U48 A found nothing left to write" "$(grep -c 'sync u48a: merged' "$TU/u48a.out")" "0"
check "U48 A prints nothing at all" "$(wc -c < "$TU/u48a.out" | tr -d ' ')" "0"
check "U48 exactly one zero-sync commit" "$(wc -l < "$TU/u48_commits" | tr -d ' ')" "1"
check "U48 branch deleted once" "$(cat "$TU/u48_branch")" "gone"
rm -f "$TU/stub/gh-list.out"
# U48 PASS — `A`'s own `mr_list` call blocks until `B` has finished, so `B` always lands the
# commit first (`box_symbol_on_base` → `x`, the branch deleted, exactly one `zero sync u48a`
# commit); `A` then acquires `MERGE_LOCK`, re-reads the box under it per step 3's own rule, finds
# it already not `↑`, and writes nothing — the same mechanism both `wait_for_reviews` and
# `wait_for_dependency_clear` rely on for two fleets parked on one base at once.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
