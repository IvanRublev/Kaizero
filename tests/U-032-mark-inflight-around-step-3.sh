#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-032-mark-inflight-around-step-3 — `mark_inflight` around step 3.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-032-mark-inflight-around-step-3
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# The todo rewrite under interference: `sync_mrs` brackets step 3 with `mark_inflight`, cleared on
# a normal exit and left behind naming the coordination root when the pass is killed mid-rewrite.
# `zero_funcs` sources everything above `zero.sh`'s own dispatch, so the functions below become
# callable without a subcommand that does not exist; `mrsetup` gives them a single real repo standing
# in for both roles — all they need is a real `COORD_GITDIR` and a real `TARGET_ROOT` — and the stub
# `gh`/`glab` supplies the canned JSON, the URL and the exit code each case wants back.

# --- Setup ---
TU="$TESTROOT/U-032-mark-inflight-around-step-3"; mkdir -p "$TU/bin" "$TU/stub"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git remote add origin "https://github.com/acme/$(basename "$1").git" ); }
mktodo(){ ( cd "$1"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }
# emit(): the --local-merge baseline launch — no origin read, local merge, exactly what a launch
# did before MR mode became the default.
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

# zero_funcs <zero.sh path>: sources everything up to (not including) the trailing `case
# "${1:-}" in` dispatch, so mr_list/mr_create become callable directly without
# hitting that dispatch's `exit 64` (which would kill the sourcing shell — these two functions
# have no operator-facing surface of their own, so there is no subcommand to invoke them by).
zero_funcs(){
  local f="$1" tmp ln
  ln=$(grep -nF 'case "${1:-}" in' "$f" | head -1 | cut -d: -f1)
  tmp="$(mktemp)"; head -n "$((ln - 1))" "$f" > "$tmp"
  # shellcheck disable=SC1090
  . "$tmp"; rm -f "$tmp"
}

# mrsetup <name>: a single real repo standing in for both COORD and TARGET (SAME_REPO=1) — all
# mr_list/mr_create need from it is a real, working COORD_GITDIR and ORIGIN_URL (both baked by zero.sh)
# and a real TARGET_ROOT (so the "never $TARGET_ROOT" cwd checks have something to compare
# against). Emitted with `emit()` (--local-merge — TEST_EMIT bakes ORIGIN_URL empty in MR
# mode regardless, since the doctor that would resolve it never runs), so FORGE/ORIGIN_URL are
# always overridden by the case itself, after sourcing, never read from the bake.
mrsetup(){
  mkrepo "$TU/$1"; mktodo "$TU/$1"; emit "$TU/$1" todo.md >/dev/null
  # 039h: `--local-merge` bakes MR_MODE=0/FORGE=''/ORIGIN_URL='' unconditionally into the emitted
  # zero.sh — a real `bash "$Z" sync-mrs` child process would then never see this case's own
  # MR_MODE=1/FORGE/ORIGIN_URL overrides. Rewrite the three bake lines to defaults so an exported
  # override wins and the un-overridden bake is unchanged.
  sed -i.bak \
    -e 's/^MR_MODE=.*/: "${MR_MODE:=0}"/' \
    -e 's/^FORGE=.*/: "${FORGE:=}"/' \
    -e 's/^ORIGIN_URL=.*/: "${ORIGIN_URL:=}"/' \
    "$TU/$1/.git/zero.sh"
  rm -f "$TU/$1/.git/zero.sh.bak"
}

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

# U47 — `sync_mrs` brackets step 3 with `mark_inflight`, cleared on normal exit and left behind
# naming the coordination root when the pass is killed mid-rewrite
# a real, separate bash process for the risky part below (background + SIGKILL) — an in-process
# zero_funcs call sharing this shell's own fd table with a killed background job is a known
# footgun in this harness (see U48's own note); a fresh process sidesteps it entirely.
cat > "$TU/u47inner.sh" <<'INNER'
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
cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":60,"headRefOid":"aaa","baseRefName":"main","state":"CLOSED","url":"https://x/60"}]
JSON
rm -f "$TU/u47ready" "$TU/u47go"
tick_box(){ : > "$TU/u47ready"; while [ ! -f "$TU/u47go" ]; do sleep 0.05; done; }
# plain redirection, not `out=$(sync_mrs)`: command substitution forks an extra grandchild to
# run sync_mrs, and `kill -9 "$pid"` on the outer `()` subshell alone leaves that grandchild
# orphaned, still spinning in tick_box's loop forever — a real leak, caught by inspecting `ps`
# after a run. The redirect sits OUTSIDE the parens, not inside them: `( sync_mrs > file 2>&1 )`
# corrupts sync_mrs's own `exec 10>"$MERGE_LOCK"` fd in this environment ("flock: data error:
# Bad file descriptor") — the same footgun the fd-table note above already names, just tripped
# by a different redirect shape.
( sync_mrs ) > "$TU/u47bg.out" 2>&1 &
pid=$!
i=0; while [ ! -f "$TU/u47ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
[ -f "$TU/u47ready" ] && echo yes > "$TU/u47_reached" || echo no > "$TU/u47_reached"
kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
MF=$(inflight_file_for "$COORD_ROOT")
[ -f "$MF" ] && echo yes > "$TU/u47_marker" || echo no > "$TU/u47_marker"
sed -n 3p "$MF" 2>/dev/null > "$TU/u47_markerroot" || : > "$TU/u47_markerroot"
rm -f "$MF" "$TU/u47go"
box_symbol_on_base u47a > "$TU/u47_box" 2>/dev/null || echo "?" > "$TU/u47_box"
rm -f "$TU/stub/gh-list.out"
INNER

mrsetup u47
( cd "$TU/u47"
  git checkout -qb u47a-fix-thing; echo y > g; git add g; git commit -qm work
  git checkout -q main
  printf '# todo\n\n- [\xe2\x86\x91] u47a fix thing\n' > todo.md
  git add todo.md; git commit -qm "mark u47a inflight"
)
Z="$TU/u47/.git/zero.sh"
bash "$TU/u47inner.sh" "$TU" "$Z"
check "U47 reached the blocked rewrite" "$(cat "$TU/u47_reached")" "yes"
check "U47 marker left after kill" "$(cat "$TU/u47_marker")" "yes"
check "U47 marker names coordination root" "$([ "$(cat "$TU/u47_markerroot")" = "$TU/u47" ] && echo yes || echo no)" "yes"
check "U47 box still ↑, nothing rewritten" "$(cat "$TU/u47_box")" "↑"

# a pass that completes normally leaves no marker behind — separate repo, fresh sync_mrs call.
mrsetup u47b
( cd "$TU/u47b"
  git checkout -qb u47ba-fix-thing; echo y > g; git add g; git commit -qm work
  git checkout -q main
  printf '# todo\n\n- [\xe2\x86\x91] u47ba fix thing\n' > todo.md
  git add todo.md; git commit -qm "mark u47ba inflight"
)
Z2="$TU/u47b/.git/zero.sh"
( zero_funcs "$Z2"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":61,"headRefOid":"aaa","baseRefName":"main","state":"CLOSED","url":"https://x/61"}]
JSON
  out=$(sync_mrs)
  MF=$(inflight_file_for "$COORD_ROOT")
  check "U47 normal completion leaves no marker" "$([ -f "$MF" ] && echo no || echo yes)" "yes"
  check "U47 normal completion still lands it" "$(box_symbol_on_base u47ba)" "⛔"
  rm -f "$TU/stub/gh-list.out"
  [ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
) || FAILED=1
# U47 PASS — a pass blocked mid-rewrite (its `tick_box` call held open) and then `SIGKILL`ed
# leaves its `inflight_file_for` marker behind naming the coordination root, with the box untouched (still `↑`
# — the kill landed before that id's commit); a pass that runs to completion always clears the
# marker.

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

# U66 — a coordination checkout sitting off `$COORD_BASE`, with an uncommitted change to a
# tracked file other than the todo, refuses the branch switch in the sync's own words;
# committing that file lets the same fixture write `[x]`
mrsetup u66
( cd "$TU/u66"
  echo on-main > other.txt; git add other.txt; git commit -qm "other.txt on main"
  git checkout -qb away; echo on-away > other.txt; git commit -qam "other.txt on away"
  git checkout -qb u66a-fix-thing main; echo y > g; git add g; git commit -qm work
  git checkout -q main
  printf '# todo\n\n- [\xe2\x86\x91] u66a fix thing\n' > todo.md
  git add todo.md; git commit -qm "mark u66a inflight"
  git checkout -q away
  echo dirty-local > other.txt   # uncommitted, tracked, NOT todo.md — the gate the todo-scoped
  # quiet_checkout check declares fine; only git's own branch-switch refusal catches this one
)
Z="$TU/u66/.git/zero.sh"
u66sha=$(git -C "$TU/u66" rev-parse u66a-fix-thing)
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":90,"headRefOid":"$u66sha","baseRefName":"main","state":"MERGED","url":"https://x/90"}]
JSON
  rc=0; out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs 2>"$TU/u66err") || rc=$?
  check "U66 sync's own line, not git's bare error" "$(grep -c 'sync: could not switch .* to main' "$TU/u66err")" "1"
  check "U66 not git's own bare error text alone" "$(grep -c '^error: Your local changes' "$TU/u66err")" "0"
  check "U66 box still ↑, nothing rewritten" "$(box_symbol_on_base u66a)" "↑"
  check "U66 nothing on stdout" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"
  check "U66 no inflight marker left" "$([ -e "$TU/u66/.git/merge-inflight-target" ] && echo present || echo absent)" "absent"

  git -C "$TU/u66" add other.txt; git -C "$TU/u66" commit -qm "commit the blocking file"
  out2=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs 2>"$TU/u66err2")
  check "U66 committing it lets the fixture land [x]" "$(box_symbol_on_base u66a)" "x"
  check "U66 second pass's own stdout line" "$(printf '%s\n' "$out2" | grep -c 'sync u66a: merged → \[x\] (https://x/90) . branch u66a-fix-thing deleted')" "1"
  rm -f "$TU/stub/gh-list.out"
  [ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
) || FAILED=1
# U66 PASS — `quiet_checkout`'s own todo-scoped gate is satisfied (`other.txt` is not the
# pathspec it checks), so the pass reaches step 3's `git checkout -q "$COORD_BASE"`; git itself
# refuses the switch because the coordination checkout's uncommitted edit to `other.txt` would be
# overwritten, and `sync_mrs` catches that failure (`coerr=$(git … checkout … 2>&1)`) and prints
# its own `sync: could not switch … — <git's reason>, boxes left alone` line rather than letting
# git's bare `error: Your local changes …` stand alone on stderr — every box is left exactly as it
# was, `clear_inflight` still runs on this exit path, and the lock is released. Once the blocking
# commit is made, the identical fixture's next `sync-mrs` pass switches cleanly and lands `[x]`
# with the branch deleted, proving the refusal was about the branch switch alone, not the forge
# answer or the box state.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
