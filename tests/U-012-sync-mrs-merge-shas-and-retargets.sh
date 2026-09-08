#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-012-sync-mrs-merge-shas-and-retargets — a merge sha the local branch lacks, and a retarget
# resolved both ways.
# Needs real `claude`: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under `$TESTROOT`: `$TESTROOT/U-012-sync-mrs-merge-shas-and-retargets`
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# The two answers a pass has to give about a request that moved under it: merged at a sha the
# local branch does not carry (the box still lands, the branch is kept, both shas named), and a
# request retargeted while `[↑]` that settles either way. `zero_funcs` sources everything above
# `zero.sh`'s own dispatch, so the functions below become callable without a subcommand that does
# not exist; `mrsetup` gives them a single real repo standing in for both roles — all they need is
# a real `COORD_GITDIR` and a real `TARGET_ROOT` — and the stub `gh`/`glab` supplies the canned
# JSON, the URL and the exit code each case wants back.

# Setup
TU="$TESTROOT/U-012-sync-mrs-merge-shas-and-retargets"; mkdir -p "$TU/bin" "$TU/stub"
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

# U40 — `sync_mrs`: merged at a sha the local branch does not carry keeps the branch, both shas named; a draft/open request is untouched
mrsetup u40
( cd "$TU/u40"
  git checkout -qb u40a-fix-thing; echo y > g; git add g; git commit -qm work
  git rev-parse HEAD > "$TU/u40a.sha"
  git checkout -qb u40b-quiet-draft main; echo z > h; git add h; git commit -qm work2
  git checkout -q main
  printf '# todo\n\n- [\xe2\x86\x91] u40a fix thing\n- [ ] u40b quiet draft\n' > todo.md
  git add todo.md; git commit -qm "mark u40a inflight"
)
Z="$TU/u40/.git/zero.sh"
u40localsha=$(cat "$TU/u40a.sha")
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  # a reviewer's own commit merged the request at a sha the local branch does not carry.
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":77,"headRefOid":"deadbeefcafe","baseRefName":"main","state":"MERGED","url":"https://github.com/acme/api/pull/77"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U40 merged-elsewhere-sha -> [x]" "$(box_symbol_on_base u40a)" "x"
  check "U40 branch kept" "$(git -C "$TARGET_ROOT" rev-parse -q --verify u40a-fix-thing >/dev/null 2>&1 && echo present || echo gone)" "present"
  check "U40 message names both shas" "$(printf '%s\n' "$out" | grep -c "kept — local $u40localsha vs request deadbeefcafe")" "1"
  rm -f "$TU/stub/gh-list.out"

  # a draft request: both CLIs still report it OPEN — nothing here queries isDraft, so it is
  # left exactly as any other open request, box unchanged, no line printed for it.
  sed -i.bak 's/- \[ \] u40b/- [\xe2\x86\x91] u40b/' "$TU/u40/todo.md"; rm -f "$TU/u40/todo.md.bak"
  git -C "$TU/u40" add todo.md; git -C "$TU/u40" commit -qm "mark u40b inflight"
  cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":81,"headRefOid":"aaa","baseRefName":"main","state":"OPEN","url":"https://github.com/acme/api/pull/81"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U40 draft/open box unchanged" "$(box_symbol_on_base u40b)" "↑"
  check "U40 draft/open prints nothing" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"
  rm -f "$TU/stub/gh-list.out"
)
# - **U40 PASS** — a reviewer's commit merged at a sha the local branch lacks still lands `[x]`,
#   names both shas, and keeps the branch for a look; a draft request (both CLIs report it plain
#   `OPEN`, `isDraft` unread) changes nothing.

# U41 — `sync_mrs`: a request retargeted while `[↑]` resolves both ways once it settles
mrsetup u41
( cd "$TU/u41"
  git checkout -qb u41a-retry-budget; echo y > g; git add g; git commit -qm work
  git checkout -qb u41b-cache-warmup main; echo z > h; git add h; git commit -qm work2
  git checkout -q main
  printf '# todo\n\n- [\xe2\x86\x91] u41a retry budget\n- [\xe2\x86\x91] u41b cache warmup\n' > todo.md
  git add todo.md; git commit -qm "mark both inflight"
)
Z="$TU/u41/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  # both requests retargeted to release/2.4 while still open — box left [↑] for each, no rewrite.
  cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":30,"headRefOid":"aaa","baseRefName":"release/2.4","state":"OPEN","url":"https://github.com/acme/api/pull/30"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U41 both retargeted, box unchanged" "$([ "$(box_symbol_on_base u41a)" = ↑ ] && [ "$(box_symbol_on_base u41b)" = ↑ ] && echo yes || echo no)" "yes"
  check "U41 retarget line count" "$(printf '%s\n' "$out" | grep -c 'still open, box left \[↑\]')" "2"
  rm -f "$TU/stub/gh-list.out"

  # ending 1, isolated to u41a alone: its request is retargeted back to main and merges there —
  # no human step, just the next poll-tick sync seeing it — lands [x]. u41b is parked unchecked
  # first so this pass's single stub row can't be mistaken for its own answer.
  sed -i.bak 's/- \[\xe2\x86\x91\] u41b/- [ ] u41b/' "$TU/u41/todo.md"; rm -f "$TU/u41/todo.md.bak"
  git -C "$TU/u41" add todo.md; git -C "$TU/u41" commit -qm "park u41b"
  aashaa=$(git -C "$TARGET_ROOT" rev-parse u41a-retry-budget)
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":30,"headRefOid":"$aashaa","baseRefName":"main","state":"MERGED","url":"https://github.com/acme/api/pull/30"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U41 retargeted-back merged -> [x]" "$(box_symbol_on_base u41a)" "x"
  rm -f "$TU/stub/gh-list.out"

  # ending 2: u41b's request merges where it now stands (release/2.4, never back to main) — [?].
  sed -i.bak 's/- \[ \] u41b/- [\xe2\x86\x91] u41b/' "$TU/u41/todo.md"; rm -f "$TU/u41/todo.md.bak"
  git -C "$TU/u41" add todo.md; git -C "$TU/u41" commit -qm "reopen u41b"
  cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":31,"headRefOid":"bbb","baseRefName":"release/2.4","state":"MERGED","url":"https://github.com/acme/api/pull/31"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U41 merged-where-it-stands -> [?]" "$(box_symbol_on_base u41b)" "?"
  check "U41 merged-elsewhere line" "$(printf '%s\n' "$out" | grep -c 'merged into release/2.4, not main')" "1"
  rm -f "$TU/stub/gh-list.out"
)
# - **U41 PASS** — a still-open retarget prints once per id and leaves every box `[↑]`; from there,
#   one request retargeted back to the target base and merged lands `[x]` with no human step, and
#   one merged where it now stands lands `[?]`, naming the base it actually merged into.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
