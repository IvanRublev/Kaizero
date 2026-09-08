#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-008-mr-list — normalized TSV from either CLI, ascending by number, and an exit status
# captured before jq.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-008-mr-list
# Wall-clock budget: its longest Run command is timeout 20 — allow that command at least 20s
#
# The first of the two forge calls: mr_list normalizes what either CLI answers into one
# TSV — gh's states downcased, glab's opened/locked folded to open, both sorted
# ascending by number — and captures the call's exit status before jq touches it, so a non-zero
# call with empty stdout is a failure rather than "no requests". zero_funcs sources everything
# above zero.sh's own dispatch, so the functions below become callable without a subcommand that
# does not exist; mrsetup gives them a single real repo standing in for both roles — all they
# need is a real COORD_GITDIR and a real TARGET_ROOT — and the stub gh/glab supplies the
# canned JSON, the URL and the exit code each case wants back.

# Setup
TU="$TESTROOT/U-008-mr-list"; mkdir -p "$TU/bin" "$TU/stub"
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
printf '%s\n' "GH_REPO=\${GH_REPO:-} GITLAB_REPO=\${GITLAB_REPO:-} GH_HOST=\${GH_HOST:-}" >> "$TU/stub/$prog.env"
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
mrsetup(){ mkrepo "$TU/$1"; mktodo "$TU/$1"; emit "$TU/$1" todo.md >/dev/null; }

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

# U20 — mr_list (gh): normalized TSV, ascending sort by number, state downcased
mrsetup u20
Z="$TU/u20/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"
  cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":5,"headRefOid":"aaa1111","baseRefName":"main","state":"OPEN","url":"https://github.com/acme/api/pull/5"},
 {"number":2,"headRefOid":"bbb2222","baseRefName":"main","state":"MERGED","url":"https://github.com/acme/api/pull/2"}]
JSON
  rc=0; out=$(mr_list task-branch) || rc=$?
  check "U20 rc" "$rc" "0"
  check "U20 ascending, 2 first" "$(printf '%s\n' "$out" | head -1 | cut -f1)" "2"
  check "U20 newest (5) last" "$(printf '%s\n' "$out" | tail -1 | cut -f1)" "5"
  check "U20 five columns" "$(printf '%s\n' "$out" | awk -F'\t' 'NR==1{print NF}')" "5"
  check "U20 states downcased" "$(printf '%s\n' "$out" | awk -F'\t' '{print $4}' | tr '\n' ',')" "merged,open,"
  rm -f "$TU/stub/gh-list.out"
)
# U20 PASS.

# U21 — mr_list (glab): opened/locked fold to open, ascending sort by iid
mrsetup u21
Z="$TU/u21/.git/zero.sh"
( zero_funcs "$Z"; FORGE=glab; ORIGIN_URL="https://gitlab.example.com/acme/api.git"
  cat > "$TU/stub/glab-list.out" <<'JSON'
[{"iid":7,"sha":"ccc7777","target_branch":"main","state":"opened","web_url":"https://gitlab.example.com/acme/api/-/merge_requests/7"},
 {"iid":3,"sha":"ddd3333","target_branch":"main","state":"locked","web_url":"https://gitlab.example.com/acme/api/-/merge_requests/3"},
 {"iid":9,"sha":"eee9999","target_branch":"main","state":"merged","web_url":"https://gitlab.example.com/acme/api/-/merge_requests/9"}]
JSON
  rc=0; out=$(mr_list task-branch) || rc=$?
  check "U21 rc" "$rc" "0"
  check "U21 ascending order (3,7,9)" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ',')" "3,7,9,"
  check "U21 opened/locked fold to open" "$(printf '%s\n' "$out" | awk -F'\t' '{print $4}' | tr '\n' ',')" "open,open,merged,"
  rm -f "$TU/stub/glab-list.out"
)
# U21 PASS.

# U22 — exit status captured before jq: a non-zero call with empty stdout is a failure, never "no requests"
mrsetup u22
Z="$TU/u22/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"
  printf '5\n' > "$TU/stub/gh-list.rc"
  rc=0; out=$(mr_list some-branch) || rc=$?
  check "U22 mr_list non-zero rc propagated" "$rc" "5"
  check "U22 mr_list prints nothing" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"
  rm -f "$TU/stub/gh-list.rc"

  printf '7\n' > "$TU/stub/gh-create.rc"
  rc=0; out=$(mr_create some-branch T /dev/null 2>/dev/null) || rc=$?
  check "U22 mr_create non-zero rc propagated" "$rc" "7"
  rm -f "$TU/stub/gh-create.rc"
)
# U22 PASS.

# U26 — mr_list names the repository explicitly (--repo/-R), never the caller's cwd; stdin closed; a single $FORGE dispatch
mrsetup u26
( cd "$TU/u26"; git checkout -q -b some-other-branch
  git remote add upstream "$TU/u26-upstream-unreachable.git" )
Z="$TU/u26/.git/zero.sh"
before="$(pwd)"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"
  printf '[]' > "$TU/stub/gh-list.out"
  mr_list x >/dev/null
  check "U26 gh list --repo carries ORIGIN_URL" "$(tail -1 "$TU/stub/gh.argv" | grep -c -- "--repo $ORIGIN_URL")" "1"
  check "U26 gh list cwd unchanged, upstream never read" "$([ "$(tail -1 "$TU/stub/gh.cwd")" = "$before" ] && echo yes || echo no)" "yes"
  rm -f "$TU/stub/gh-list.out"
)
( zero_funcs "$Z"; FORGE=glab; ORIGIN_URL="https://gitlab.example.com/acme/api.git"
  printf '[]' > "$TU/stub/glab-list.out"
  mr_list x >/dev/null
  check "U26 glab list --repo carries ORIGIN_URL" "$(tail -1 "$TU/stub/glab.argv" | grep -c -- "--repo $ORIGIN_URL")" "1"
  rm -f "$TU/stub/glab-list.out"
)
check "U26 mr_list reads stdin from /dev/null (both CLIs)" "$(sed -n '/^mr_list()/,/^}/p' "$Z" | grep -c '</dev/null')" "2"
check "U26 mr_list dispatches \$FORGE exactly once" "$(sed -n '/^mr_list()/,/^}/p' "$Z" | grep -cF '"$FORGE"')" "1"
# U26 PASS — mr_list names the repository to both CLIs as an argument carrying the baked
# ORIGIN_URL, never lets a clone's own remotes (an upstream ranked above origin by gh)
# decide it, and its cwd is whatever the caller's was — never a scratch checkout.

# U28 — mr_list forwards the CLI's own stderr on failure, and the returned status is the CLI's own
mrsetup u28
Z="$TU/u28/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"
  echo "rate limited: try again later" > "$TU/stub/gh-list"
  rc=0; out=$(mr_list some-branch 2>"$TU/u28err") || rc=$?
  err="$(cat "$TU/u28err")"
  check "U28 rc propagated (stub's marker exit 1)" "$rc" "1"
  check "U28 stdout empty" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"
  check "U28 stderr carries the cause" "$(printf '%s' "$err" | grep -c 'rate limited: try again later')" "1"
  rm -f "$TU/stub/gh-list"
)
# U28 PASS — a forge failure's cause reaches the caller's stderr, not just a bare exit number.

# U29 — mr_list sorts ascending whatever order the CLI printed, both open
mrsetup u29
Z="$TU/u29/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"
  cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":9,"headRefOid":"nnn9999","baseRefName":"main","state":"OPEN","url":"https://github.com/acme/api/pull/9"},
 {"number":7,"headRefOid":"nnn7777","baseRefName":"main","state":"OPEN","url":"https://github.com/acme/api/pull/7"}]
JSON
  out=$(mr_list task-branch)
  check "U29 ascending 7 then 9, both open" "$(printf '%s\n' "$out" | awk -F'\t' '{print $1"-"$4}' | tr '\n' ',')" "7-open,9-open,"
  rm -f "$TU/stub/gh-list.out"
)
# U29 PASS — the CLI printed 9 before 7; the emitted rows read 7 then 9, the ascending
# contract, so a caller that reads a row by position reads the oldest.

# U30 — mr_list makes one CLI invocation per call, no cached replay; an unmatched $FORGE fails loudly
mrsetup u30
Z="$TU/u30/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"
  printf '[]' > "$TU/stub/gh-list.out"
  before=$(wc -l < "$TU/stub/gh.argv" 2>/dev/null | tr -d ' '); [ -n "$before" ] || before=0
  mr_list same-branch >/dev/null
  mr_list same-branch >/dev/null
  after=$(wc -l < "$TU/stub/gh.argv" | tr -d ' ')
  check "U30 two calls, two invocations" "$((after - before))" "2"
  rm -f "$TU/stub/gh-list.out"

  FORGE=bitbucket
  rc=0; out=$(mr_list x 2>"$TU/u30err") || rc=$?
  check "U30 unmatched \$FORGE: non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
  check "U30 unmatched \$FORGE: no rows" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"
  check "U30 unmatched \$FORGE: names the value" "$(grep -c 'bitbucket' "$TU/u30err")" "1"
)
# U30 PASS — no paging loop, no cache: a repeated call for the same head re-invokes the CLI.
# A $FORGE neither arm implements is a loud, non-zero, empty-output failure naming the value —
# never a silent "no requests".

# U31 — mr_list neutralizes GH_REPO/GITLAB_REPO/GH_HOST for the call, so $ORIGIN_URL is the sole candidate
mrsetup u31
Z="$TU/u31/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"
  export GH_REPO=someone-else/other GH_HOST=github.example.com GITLAB_REPO=someone-else/other
  printf '[]' > "$TU/stub/gh-list.out"
  rc=0; mr_list x >/dev/null || rc=$?
  check "U31 gh list still succeeds" "$([ "$rc" -eq 0 ] && echo yes || echo no)" "yes"
  check "U31 gh: CLI saw no GH_REPO/GITLAB_REPO/GH_HOST" "$(tail -1 "$TU/stub/gh.env")" "GH_REPO= GITLAB_REPO= GH_HOST="
  rm -f "$TU/stub/gh-list.out"
)
( zero_funcs "$Z"; FORGE=glab; ORIGIN_URL="https://gitlab.example.com/acme/api.git"
  export GH_REPO=someone-else/other GH_HOST=github.example.com GITLAB_REPO=someone-else/other
  printf '[]' > "$TU/stub/glab-list.out"
  rc=0; mr_list x >/dev/null || rc=$?
  check "U31 glab list still succeeds" "$([ "$rc" -eq 0 ] && echo yes || echo no)" "yes"
  check "U31 glab: CLI saw no GH_REPO/GITLAB_REPO/GH_HOST" "$(tail -1 "$TU/stub/glab.env")" "GH_REPO= GITLAB_REPO= GH_HOST="
  rm -f "$TU/stub/glab-list.out"
)
# U31 PASS — GH_REPO/GITLAB_REPO/GH_HOST are unset inside the call, so the argument
# naming $ORIGIN_URL is the sole candidate; neither call refuses.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
