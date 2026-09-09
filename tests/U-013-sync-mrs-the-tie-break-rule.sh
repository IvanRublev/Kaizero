#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-013-sync-mrs-the-tie-break-rule — newest-open-else-highest-number, proven with two rows for
# one id in a single response.
# Needs real `claude`: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under `$TESTROOT`: `$TESTROOT/U-013-sync-mrs-the-tie-break-rule`
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# The rule `sync_mrs` shares with `mr` for picking one request out of several carrying the same
# id: the newest open one, else the highest number. A single response with two rows exercises it
# inside `sync_mrs` itself. `zero_funcs` sources everything above `zero.sh`'s own dispatch, so the
# functions below become callable without a subcommand that does not exist; `mrsetup` gives them a
# single real repo standing in for both roles — all they need is a real `COORD_GITDIR` and a real
# `TARGET_ROOT` — and the stub `gh`/`glab` supplies the canned JSON, the URL and the exit code
# each case wants back.

# Setup
TU="$TESTROOT/U-013-sync-mrs-the-tie-break-rule"; mkdir -p "$TU/bin" "$TU/stub"
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

# U49 — `sync_mrs`'s shared newest-open-else-highest-number rule, proven with two rows in a single response
mrsetup u49
( cd "$TU/u49"
  git checkout -qb u49a-thing; echo y > g; git add g; git commit -qm work
  git checkout -qb u49b-thing main; echo z > h; git add h; git commit -qm work2
  git checkout -qb u49c-thing main; echo w > i; git add i; git commit -qm work3
  git checkout -q main
  printf '# todo\n\n- [\xe2\x86\x91] u49a older-merged-newer-closed\n- [ ] u49b older-closed-newer-merged\n- [ ] u49c older-open-newer-closed\n' > todo.md
  git add todo.md; git commit -qm "mark u49a inflight"
)
Z="$TU/u49/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  u49asha=$(git -C "$TARGET_ROOT" rev-parse u49a-thing)
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":10,"headRefOid":"$u49asha","baseRefName":"main","state":"MERGED","url":"https://x/10"},{"number":11,"headRefOid":"zzz","baseRefName":"main","state":"CLOSED","url":"https://x/11"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U49 older-merged-newer-closed -> declined (#11 wins)" "$(box_symbol_on_base u49a)" "⛔"
  rm -f "$TU/stub/gh-list.out"

  sed -i.bak 's/- \[ \] u49b/- [\xe2\x86\x91] u49b/' "$TU/u49/todo.md"; rm -f "$TU/u49/todo.md.bak"
  git -C "$TU/u49" add todo.md; git -C "$TU/u49" commit -qm "mark u49b inflight"
  u49bsha=$(git -C "$TARGET_ROOT" rev-parse u49b-thing)
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":20,"headRefOid":"yyy","baseRefName":"main","state":"CLOSED","url":"https://x/20"},{"number":21,"headRefOid":"$u49bsha","baseRefName":"main","state":"MERGED","url":"https://x/21"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U49 older-closed-newer-merged -> merged (#21 wins)" "$(box_symbol_on_base u49b)" "x"
  rm -f "$TU/stub/gh-list.out"

  sed -i.bak 's/- \[ \] u49c/- [\xe2\x86\x91] u49c/' "$TU/u49/todo.md"; rm -f "$TU/u49/todo.md.bak"
  git -C "$TU/u49" add todo.md; git -C "$TU/u49" commit -qm "mark u49c inflight"
  cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":30,"headRefOid":"aaa","baseRefName":"main","state":"OPEN","url":"https://x/30"},{"number":31,"headRefOid":"bbb","baseRefName":"main","state":"CLOSED","url":"https://x/31"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U49 older-open-beneath-newer-non-open -> stays ↑" "$(box_symbol_on_base u49c)" "↑"
  check "U49 nothing printed for the still-open u49c" "$(printf '%s' "$out" | grep -c 'u49c')" "0"
  rm -f "$TU/stub/gh-list.out"
)
# - **U49 PASS** — each id's todo box only flips to `↑` once the prior id's has already resolved
#   away from `↑`, so a single `sync_mrs` pass never cross-contaminates two ids with the same
#   stubbed response (a stub that ignores `--head` would otherwise hand every still-`↑` id in one
#   pass the same canned rows). The rule holds both orders when no request is `open` (highest
#   number wins, whichever state it carries) and holds the open-wins-outright exception even when
#   the open row is numbered *lower* than a closed one beneath it — the box stays `↑` and the sync
#   prints nothing for that id, rather than writing `⛔` over a request still under review. `[?]`
#   causes not re-reported on the next pass need no separate proof: `ids_with_box '↑'` (sync_mrs's own
#   1) only ever selects boxes still holding `↑`, and every `[?]`/`⛔`/`x` verdict here and in
#   U39/U41 already leaves that set, which this test and those already exercise across repeated
#   `sync_mrs` calls.

# U49b — a head carrying a request merged into `$TARGET_BASE` *and* a still-`open` one resolves to the merge, in both row orders
mrsetup u49b
( cd "$TU/u49b"
  git checkout -qb u49ba-thing; echo y > g; git add g; git commit -qm work
  git checkout -qb u49bb-thing main; echo z > h; git add h; git commit -qm work2
  git checkout -q main
  printf '# todo\n\n- [\xe2\x86\x91] u49ba merged-then-open\n- [ ] u49bb open-then-merged\n' > todo.md
  git add todo.md; git commit -qm "mark u49ba inflight"
)
Z="$TU/u49b/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  u49basha=$(git -C "$TARGET_ROOT" rev-parse u49ba-thing)
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":40,"headRefOid":"$u49basha","baseRefName":"main","state":"MERGED","url":"https://x/40"},{"number":41,"headRefOid":"zzz","baseRefName":"main","state":"OPEN","url":"https://x/41"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U49b merge (lower #) beats open (higher #) -> x" "$(box_symbol_on_base u49ba)" "x"
  check "U49b branch deleted on the sha-matched merge" "$(git -C "$TARGET_ROOT" branch --list u49ba-thing | wc -l | tr -d ' ')" "0"
  check "U49b leftover-open note names #41's url" "$(printf '%s\n' "$out" | grep -c 'u49ba: request https://x/41 is still open')" "1"
  rm -f "$TU/stub/gh-list.out"

  sed -i.bak 's/- \[ \] u49bb/- [\xe2\x86\x91] u49bb/' "$TU/u49b/todo.md"; rm -f "$TU/u49b/todo.md.bak"
  git -C "$TU/u49b" add todo.md; git -C "$TU/u49b" commit -qm "mark u49bb inflight"
  u49bbsha=$(git -C "$TARGET_ROOT" rev-parse u49bb-thing)
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":50,"headRefOid":"zzz","baseRefName":"main","state":"OPEN","url":"https://x/50"},{"number":51,"headRefOid":"$u49bbsha","baseRefName":"main","state":"MERGED","url":"https://x/51"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U49b merge (higher #) beats open (lower #) -> x" "$(box_symbol_on_base u49bb)" "x"
  check "U49b leftover-open note names #50's url" "$(printf '%s\n' "$out" | grep -c 'u49bb: request https://x/50 is still open')" "1"
  rm -f "$TU/stub/gh-list.out"
)
# - **U49b PASS** — the one test the shared `mr_pick` does not make, and it is `sync_mrs`'s alone:
#   a row merged into `$TARGET_BASE` beats a competing `open` row regardless of which one carries
#   the higher request number — `mr_task` keeps reusing `mr_pick`'s own open-wins verdict for the
#   head unchanged, since opening a second request there is the worse error. The still-`open`
#   request's own url reaches the printed line as the human's to close, and the branch deletion
#   still follows the sha rule unchanged (the merged row's head sha matches the branch tip here, so
#   it is torn down exactly as U50's plain-merge case proves).

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
