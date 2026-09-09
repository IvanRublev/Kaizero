#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-014-sync-mrs-branch-deletion-and-the-body-sweep — the three merge-strategy shapes, a `-D`
# refused, the `mr-body/` sweep, and a failing `mr_list`.
# Needs real `claude`: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under `$TESTROOT`: `$TESTROOT/U-014-sync-mrs-branch-deletion-and-the-body-sweep`
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# What a pass cleans up and what it refuses to: branch deletion across merge, squash and rebase, a
# `-D` refused because the branch is checked out in a worktree, the `mr-body/` sweep that runs
# even when nothing is `[↑]` and makes no forge call doing it, and a forge failure on the
# `mr_list` call that warns and leaves everything else alone. `zero_funcs` sources everything
# above `zero.sh`'s own dispatch, so the functions below become callable without a subcommand that
# does not exist; `mrsetup` gives them a single real repo standing in for both roles — all they
# need is a real `COORD_GITDIR` and a real `TARGET_ROOT` — and the stub `gh`/`glab` supplies the
# canned JSON, the URL and the exit code each case wants back.

# Setup
TU="$TESTROOT/U-014-sync-mrs-branch-deletion-and-the-body-sweep"; mkdir -p "$TU/bin" "$TU/stub"
# MR mode is the default, so every fixture target needs an `origin` a forge resolves
# from or the launch refuses before the case's own subject is reached. A github URL, never fetched
# (TEST_EMIT skips the doctor; the real-doctor cases use `mkorigin` instead).
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git remote add origin "https://github.com/acme/$(basename "$1").git" ); }
mktodo(){ ( cd "$1"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }
# emit(): the --local-merge baseline launch — no origin read, local merge, exactly what a launch
# did before MR mode became the default.
emit(){ ( cd "$1"; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1 ); }

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
# check 5 calls `<verb> --help` on the resolved forge and greps its output for
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

# U42 — the `mr-body/` sweep clears a stale description even when nothing is `[↑]`, and makes no forge call doing it
mrsetup u42
( cd "$TU/u42"
  printf '# todo\n\n- [x] u42a already landed\n' > todo.md
  git add todo.md; git commit -qm "u42a already landed"
)
Z="$TU/u42/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  bodyfile=$(mr_body_path u42a)
  printf 'stale description, left over from a kill between the box commit and its own cleanup\n' > "$bodyfile"
  check "U42 stale body exists before sweep" "$([ -f "$bodyfile" ] && echo yes || echo no)" "yes"

  before=$(wc -l < "$TU/stub/gh.argv" 2>/dev/null || echo 0)
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  after=$(wc -l < "$TU/stub/gh.argv" 2>/dev/null || echo 0)
  check "U42 no ↑ box -> no forge call" "$([ "$before" = "$after" ] && echo yes || echo no)" "yes"
  check "U42 sync prints nothing" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"
  check "U42 stale body swept" "$([ -f "$bodyfile" ] && echo no || echo yes)" "yes"
)
# - **U42 PASS** — `sweep_mr_bodies` runs unconditionally at the top of every `sync_mrs` pass, ahead
#   of (and independent from) the `↑`-gated forge loop: a landed id's leftover description file is
#   removed on a pass that touches no network at all.

# U50 — `sync_mrs` branch deletion across the three merge-strategy shapes, and a `-D` refused because the branch is checked out in a worktree
mrsetup u50
( cd "$TU/u50"
  git checkout -qb u50a-merge-commit; echo a > g; git add g; git commit -qm work
  git checkout -qb u50b-squash main;  echo b > h; git add h; git commit -qm work
  git checkout -qb u50c-rebase main;  echo c > i; git add i; git commit -qm work
  git checkout -qb u50d-checked-out main; echo d > j; git add j; git commit -qm work
  git checkout -q main
  printf '# todo\n\n- [\xe2\x86\x91] u50a merge commit shape\n- [ ] u50b squash shape\n- [ ] u50c rebase shape\n- [ ] u50d checked out refusal\n' > todo.md
  git add todo.md; git commit -qm "mark u50a inflight"
)
Z="$TU/u50/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  # all three merge-strategy shapes hit the SAME sha-equality code path — the forge always reports
  # headRefOid as the branch's own tip regardless of how it landed on the base — so each is proven
  # with its own id, merged at that tip, landing [x] with the branch deleted.
  u50asha=$(git -C "$TARGET_ROOT" rev-parse u50a-merge-commit)
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":100,"headRefOid":"$u50asha","baseRefName":"main","state":"MERGED","url":"https://x/100"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U50 merge-commit shape -> [x], branch deleted" "$(box_symbol_on_base u50a)/$(git -C "$TARGET_ROOT" rev-parse -q --verify u50a-merge-commit >/dev/null 2>&1 && echo present || echo gone)" "x/gone"
  rm -f "$TU/stub/gh-list.out"

  sed -i.bak 's/- \[ \] u50b/- [\xe2\x86\x91] u50b/' "$TU/u50/todo.md"; rm -f "$TU/u50/todo.md.bak"
  git -C "$TU/u50" add todo.md; git -C "$TU/u50" commit -qm "mark u50b inflight"
  u50bsha=$(git -C "$TARGET_ROOT" rev-parse u50b-squash)
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":101,"headRefOid":"$u50bsha","baseRefName":"main","state":"MERGED","url":"https://x/101"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U50 squash shape -> [x], branch deleted" "$(box_symbol_on_base u50b)/$(git -C "$TARGET_ROOT" rev-parse -q --verify u50b-squash >/dev/null 2>&1 && echo present || echo gone)" "x/gone"
  rm -f "$TU/stub/gh-list.out"

  sed -i.bak 's/- \[ \] u50c/- [\xe2\x86\x91] u50c/' "$TU/u50/todo.md"; rm -f "$TU/u50/todo.md.bak"
  git -C "$TU/u50" add todo.md; git -C "$TU/u50" commit -qm "mark u50c inflight"
  u50csha=$(git -C "$TARGET_ROOT" rev-parse u50c-rebase)
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":102,"headRefOid":"$u50csha","baseRefName":"main","state":"MERGED","url":"https://x/102"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U50 rebase shape -> [x], branch deleted" "$(box_symbol_on_base u50c)/$(git -C "$TARGET_ROOT" rev-parse -q --verify u50c-rebase >/dev/null 2>&1 && echo present || echo gone)" "x/gone"
  rm -f "$TU/stub/gh-list.out"

  sed -i.bak 's/- \[ \] u50d/- [\xe2\x86\x91] u50d/' "$TU/u50/todo.md"; rm -f "$TU/u50/todo.md.bak"
  git -C "$TU/u50" add todo.md; git -C "$TU/u50" commit -qm "mark u50d inflight"
  git -C "$TARGET_ROOT" worktree add -q "$TU/u50d-wt" u50d-checked-out   # a reviewer/operator sitting on this branch, in its own worktree
  u50dsha=$(git -C "$TARGET_ROOT" rev-parse u50d-checked-out)
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":103,"headRefOid":"$u50dsha","baseRefName":"main","state":"MERGED","url":"https://x/103"}]
JSON
)
# a real `bash zero.sh sync-mrs` SUBPROCESS for this one case (not the in-process zero_funcs
# route the rest of this test uses): its own `exec 10>…`/`flock 10` needs a genuinely fresh fd
# table when its stderr is being captured, which only a separate process reliably gives it.
# `mrsetup` already rewrote the bake lines to `: "${VAR:=default}"`, so exported overrides win.
out=$(PATH="$TU/bin:$PATH" FORGE=gh ORIGIN_URL="https://github.com/acme/api.git" MR_MODE=1 bash "$Z" sync-mrs 2>"$TU/u50derr")
check "U50 checked-out branch -> [x], kept, warned" "$(PATH="$TU/bin:$PATH" FORGE=gh ORIGIN_URL="https://github.com/acme/api.git" MR_MODE=1 bash "$Z" box-symbol-on-base u50d)/$(git -C "$TU/u50" rev-parse -q --verify u50d-checked-out >/dev/null 2>&1 && echo present || echo gone)" "x/present"
check "U50 checked-out warning on stderr" "$(grep -c 'could not delete branch u50d-checked-out' "$TU/u50derr")" "1"
check "U50 checked-out stdout still names it kept" "$(printf '%s\n' "$out" | grep -c 'sync u50d: merged → \[x\] (https://x/103) . branch u50d-checked-out kept')" "1"
rm -f "$TU/stub/gh-list.out"
# - **U50 PASS** — the merge commit, squash and rebase shapes all land `[x]` with the branch
#   deleted through the one sha-equality path `sync_mrs` has; a `branch -D` refused because the
#   branch is checked out in its own worktree still lands `[x]` (the forge's word is the durable
#   record) but keeps the branch, warns on stderr naming it, and fails nothing — `sync_mrs`'s own
#   exit status is 0.

# U52 — a forge failure on the `mr_list` call warns and leaves everything else unchanged, including a stub that exits non-zero with empty stdout
mrsetup u52
( cd "$TU/u52"
  git checkout -qb u52a-fix-thing; echo y > g; git add g; git commit -qm work
  git checkout -q main
  printf '# todo\n\n- [\xe2\x86\x91] u52a fix thing\n' > todo.md
  git add todo.md; git commit -qm "mark u52a inflight"
)
Z="$TU/u52/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  printf 'temporary outage' > "$TU/stub/gh-list"   # marker-only: exit 1, no .out/.rc — empty stdout
  rc=0; out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs) || rc=$?
  # a warning, not a hard failure
  check "U52 sync itself still exits 0" "$rc" "0"
  check "U52 nothing to stdout" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"
  check "U52 box left untouched (↑)" "$(box_symbol_on_base u52a)" "↑"
  check "U52 no zero-sync commit made" "$(git -C "$COORD_ROOT" log --oneline --grep='zero sync u52a' | wc -l | tr -d ' ')" "0"
  rm -f "$TU/stub/gh-list"
) 2>"$TU/u52err"
check "U52 warning naming the branch" "$(grep -c 'sync u52a: forge list failed for u52a-fix-thing' "$TU/u52err")" "1"
# - **U52 PASS** — a `pr list` call that fails (a stub reporting non-zero with empty stdout — the
#   case a bare `[ -z "$rows" ]` read could otherwise misread as "no requests") is caught by
#   `mr_list`'s own non-zero return before `sync_mrs` ever reads `$rows`, prints one warning naming
#   the branch and the exit code, and moves on: no box rewritten, no commit made, `sync_mrs` itself
#   still returns 0 so a single flaky forge call never breaks the loop.

# U53 — a body for a slash-containing id survives the sweep exactly like a plain id's, while its box is still `[ ]`
mrsetup u53
( cd "$TU/u53"
  printf '# todo\n\n- [ ] SMTH/9 slash id still open\n' > todo.md
  git add todo.md; git commit -qm "slash id todo"
)
Z="$TU/u53/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  bodyfile=$(mr_body_path 'SMTH/9')
  printf 'in-flight description for a slash id\n' > "$bodyfile"
  check "U53 slash-id body exists before sweep" "$([ -f "$bodyfile" ] && echo yes || echo no)" "yes"
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U53 slash-id body survives sweep" "$([ -f "$bodyfile" ] && echo yes || echo no)" "yes"
)
# - **U53 PASS** — `sweep_mr_bodies`' forward id → path lookup walks `todo_lines`' raw ids and
#   re-derives each one's exact path with `mr_body_path`, the same call a slash id's description was
#   ever written under; it never reconstructs an id from a filename, so `sanitize_id`'s lossy
#   `/` → `-` fold never lets it mis-resolve one id's body for another's.

# U65 — a fleet zeroing base `main` sweeps no body file belonging to a peer fleet on base `main-2`, whose slug `main` is a prefix of
mkrepo "$TU/u65"; mktodo "$TU/u65"
bake65(){
  # emit() overwrites the one .git/zero.sh this single repo has, per branch it is called on —
  # copy each bake out under its own name right after, and neutralize its MR_MODE/FORGE/
  # ORIGIN_URL bake the same way mrsetup does, so an exported override wins for either copy.
  emit "$TU/u65" todo.md >/dev/null
  sed -i.bak \
    -e 's/^MR_MODE=.*/: "${MR_MODE:=0}"/' \
    -e 's/^FORGE=.*/: "${FORGE:=}"/' \
    -e 's/^ORIGIN_URL=.*/: "${ORIGIN_URL:=}"/' \
    "$TU/u65/.git/zero.sh"
  rm -f "$TU/u65/.git/zero.sh.bak"
  cp "$TU/u65/.git/zero.sh" "$1"
}
( cd "$TU/u65"; printf '# todo\n\n- [x] G65 own landed task\n' > todo.md; git add todo.md; git commit -qm "u65 main todo" )
bake65 "$TU/u65-main.sh"
( cd "$TU/u65"
  git checkout -qb main-2
  printf '# todo\n\n- [ ] G65p peer still open task\n' > todo.md
  git add todo.md; git commit -qm "u65 main-2 todo"
)
bake65 "$TU/u65-main2.sh"
Zmain="$TU/u65-main.sh"; Zmain2="$TU/u65-main2.sh"
( zero_funcs "$Zmain2"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  peerbody=$(mr_body_path G65p)
  printf 'peer fleet, still-open task description\n' > "$peerbody"
  check "U65 peer body path starts with main's own prefix" "$(basename "$peerbody")" "G65p.md"
  check "U65 peer body exists before main's sync" "$([ -f "$peerbody" ] && echo yes || echo no)" "yes"
)
( zero_funcs "$Zmain"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  ownbody=$(mr_body_path G65)
  printf 'stale own body, left behind by a killed session\n' > "$ownbody"
  peerbody=$(mr_body_path G65p 2>/dev/null || true)
)
out=$(FORGE=gh ORIGIN_URL="https://github.com/acme/api.git" MR_MODE=1 bash "$Zmain" sync-mrs)
check "U65 own stale body swept" "$([ -f "$TU/u65/.git/mr-body/G65.md" ] && echo no || echo yes)" "yes"
check "U65 peer body untouched" "$([ -f "$TU/u65/.git/mr-body/G65p.md" ] && echo yes || echo no)" "yes"
# - **U65 PASS** — `main`'s own `sweep_mr_bodies` walks only `main`'s own `todo_lines`, re-deriving
#   each raw id's exact path with `mr_body_path`; it never lists `$COORD_GITDIR` by the
#   `mr-body-main-` prefix `main-2`'s own body files also start with, so a peer fleet's still-open
#   body for `main-2` survives a pass that sweeps `main`'s own landed one sitting right beside it in
#   the same directory.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
