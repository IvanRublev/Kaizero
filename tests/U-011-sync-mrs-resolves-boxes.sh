#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-011-sync-mrs-resolves-boxes — `[↑]`→`[x]`/`[⛔]` and the dirty-todo gate.
# Needs real `claude`: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under `$TESTROOT`: `$TESTROOT/U-011-sync-mrs-resolves-boxes`
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
# Cross-references named in the body below: Scenario U-034 → `tests/U-034-sync-mrs-the-three-not-answered-causes.md`
#
# What one `sync_mrs` pass turns a reviewed request into. A merged request
# lands `[x]` and deletes the local branch, a declined one lands `[⛔]` and keeps it, a retarget
# while still open prints once and rewrites nothing, and a dirty todo refuses the whole pass.
# `zero_funcs` sources everything above `zero.sh`'s own
# dispatch, so the functions below become callable without a subcommand that does not exist;
# `mrsetup` gives them a single real repo standing in for both roles — all they need is a real
# `COORD_GITDIR` and a real `TARGET_ROOT` — and the stub `gh`/`glab` supplies the canned JSON, the
# URL and the exit code each case wants back.

# Setup
TU="$TESTROOT/U-011-sync-mrs-resolves-boxes"; mkdir -p "$TU/bin" "$TU/stub"
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

# U29 — `sync_mrs`: `[↑]`→`[x]` on a target-based merge with the local branch deleted, `[↑]`→`[⛔]` on decline with the branch kept, no forge call once nothing is `[↑]`, `MR_MODE=0` refuses
mrsetup u29
( cd "$TU/u29"
  git checkout -qb u29a-fix-thing
  echo y > g; git add g; git commit -qm work
  git rev-parse HEAD > "$TU/u29a.sha"
  git checkout -qb u29b-cache-warmup main
  echo z > h; git add h; git commit -qm work2
  git checkout -q main
  printf '# todo\n\n- [↑] u29a fix thing\n- [ ] u29b cache warmup\n' > todo.md
  git add todo.md; git commit -qm "mark u29a inflight"
)
Z="$TU/u29/.git/zero.sh"
u29asha=$(cat "$TU/u29a.sha")
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":412,"headRefOid":"$u29asha","baseRefName":"main","state":"MERGED","url":"https://github.com/acme/api/pull/412"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U29 merged stdout line" "$(printf '%s\n' "$out" | grep -c 'sync u29a: merged → \[x\] (https://github.com/acme/api/pull/412) . branch u29a-fix-thing deleted')" "1"
  check "U29 box u29a now x" "$(box_symbol_on_base u29a)" "x"
  check "U29 branch u29a deleted" "$(git -C "$TARGET_ROOT" rev-parse -q --verify u29a-fix-thing >/dev/null 2>&1 && echo present || echo gone)" "gone"
  rm -f "$TU/stub/gh-list.out"

  # only now is u29b put in review — isolates the second gh-list.out to u29b's own mr_list call.
  sed -i.bak 's/- \[ \] u29b/- [↑] u29b/' "$TU/u29/todo.md"; rm -f "$TU/u29/todo.md.bak"
  git -C "$TU/u29" add todo.md; git -C "$TU/u29" commit -qm "mark u29b inflight"

  cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":415,"headRefOid":"zzz","baseRefName":"main","state":"CLOSED","url":"https://github.com/acme/api/pull/415"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U29 declined stdout line" "$(printf '%s\n' "$out" | grep -c 'sync u29b: declined → \[⛔\] (https://github.com/acme/api/pull/415) . branch u29b-cache-warmup kept')" "1"
  check "U29 box u29b now decline" "$(box_symbol_on_base u29b)" "⛔"
  check "U29 branch u29b kept" "$(git -C "$TARGET_ROOT" rev-parse -q --verify u29b-cache-warmup >/dev/null 2>&1 && echo present || echo gone)" "present"
  rm -f "$TU/stub/gh-list.out"

  before=$(wc -l < "$TU/stub/gh.argv" 2>/dev/null || echo 0)
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  after=$(wc -l < "$TU/stub/gh.argv" 2>/dev/null || echo 0)
  check "U29 no ↑ left → no forge call" "$([ "$before" = "$after" ] && echo yes || echo no)" "yes"
  check "U29 no ↑ left → prints nothing" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"

  rc=0; MR_MODE=0 bash "$Z" sync-mrs >/dev/null 2>&1 || rc=$?
  check "U29 MR_MODE=0 refuses" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
)
# - **U29 PASS**.

# U30 — `sync_mrs`: a retarget while still `open` prints once and leaves the box `[↑]`; a dirty todo refuses the whole pass and rewrites nothing
mrsetup u30
( cd "$TU/u30"
  git checkout -qb u30a-retry-budget
  echo y > g; git add g; git commit -qm work
  git checkout -q main
  printf '# todo\n\n- [↑] u30a retry budget\n' > todo.md
  git add todo.md; git commit -qm "mark inflight"
)
Z="$TU/u30/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":9,"headRefOid":"aaa","baseRefName":"release/2.4","state":"OPEN","url":"https://github.com/acme/api/pull/9"}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U30 retarget line" "$(printf '%s\n' "$out" | grep -c 'sync u30a: request now targets release/2.4, not main . still open, box left \[↑\]')" "1"
  check "U30 box unchanged" "$(box_symbol_on_base u30a)" "↑"
  rm -f "$TU/stub/gh-list.out"

  echo dirty >> "$TU/u30/todo.md"
  cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":10,"headRefOid":"bbb","baseRefName":"main","state":"MERGED","url":"https://github.com/acme/api/pull/10"}]
JSON
  rc=0; out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs 2>"$TU/u30err") || rc=$?
  check "U30 dirty todo refused" "$(grep -c 'boxes left alone' "$TU/u30err")" "1"
  check "U30 dirty todo, nothing to stdout" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"
  check "U30 box still ↑ after refusal" "$(box_symbol_on_base u30a)" "↑"
  check "U30 no inflight marker left" "$([ -e "$TU/u30/.git/merge-inflight-target" ] && echo present || echo absent)" "absent"
  rc2=0; out2=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs 2>"$TU/u30err2") || rc2=$?
  check "U30 second sync-mrs not blocked" "$(grep -c 'boxes left alone' "$TU/u30err2")" "1"
  git -C "$TARGET_ROOT" checkout -q -- todo.md
  rm -f "$TU/stub/gh-list.out"
)
# - **U30 PASS** — U29-U30 cover sync_mrs's core: the shared newest-open-else-highest-number pick (a
#   single-row TSV exercises it directly; U20/U21 above already proved the sort/fold it reads),
#   `[↑]`→`[x]`/`[⛔]` with a `zero sync <id>` commit each, the sha-gated `branch -D`, the
#   once-empty early return before any forge call, `MR_MODE=0`'s refusal, the retarget-while-open
#   line printed without a box rewrite, and `quiet_checkout`'s dirty-todo gate leaving every box
#   and every uncommitted edit alone. Every case left unproven here is picked up later: the
#   two-branches/no-branch/no-request `[?]` causes (U39, in `tests/U-034-sync-mrs-the-three-not
#   -answered-causes.md`), a reviewer's own commits landing at a sha the local branch lacks (U40),
#   the multi-row newest-open-else-highest-number rule inside `sync_mrs` itself (U49), the three
#   merge-strategy shapes and a `-D` refused on a checked-out branch (U50), the `mr-body/` sweep
#   (U42), `mark_inflight` surviving a mid-pass kill (U47), and two instances racing one
#   `MERGE_LOCK` (U48).

# U64 — a forge row with an empty column (`url`) does not shift any field after it
mrsetup u64
( cd "$TU/u64"
  git checkout -qb u64a-empty-url
  echo y > g; git add g; git commit -qm work
  git checkout -q main
  printf '# todo\n\n- [\xe2\x86\x91] u64a empty url\n' > todo.md
  git add todo.md; git commit -qm "mark inflight"
)
Z="$TU/u64/.git/zero.sh"
u64asha=$(git -C "$TU/u64" rev-parse u64a-empty-url)
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":700,"headRefOid":"$u64asha","baseRefName":"main","state":"MERGED","url":""}]
JSON
  out=$(FORGE="$FORGE" ORIGIN_URL="$ORIGIN_URL" MR_MODE="$MR_MODE" bash "$Z" sync-mrs)
  check "U64 stdout names branch past empty url" "$(printf '%s\n' "$out" | grep -c 'sync u64a: merged → \[x\] () . branch u64a-empty-url deleted')" "1"
  check "U64 box u64a now x" "$(box_symbol_on_base u64a)" "x"
  check "U64 branch u64a deleted" "$(git -C "$TARGET_ROOT" rev-parse -q --verify u64a-empty-url >/dev/null 2>&1 && echo present || echo gone)" "gone"
  rm -f "$TU/stub/gh-list.out"
)
# - **U64 PASS** — `winner`'s empty `url` field sits ahead of `branch`/`base`/`sha` in the `pending`
#   TSV line `sync_mrs` builds and later re-reads with `IFS=$'\t' read -r`; a single-char, non-
#   whitespace `IFS` never collapses a run of delimiters, so the empty column costs nothing and the
#   branch name after it prints and deletes exactly as it does with a real URL present.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
