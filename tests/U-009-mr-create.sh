#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-009-mr-create — URL-only output, head/base read back from argv, and the argv it builds for
# either CLI.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-009-mr-create
# Wall-clock budget: its longest Run command is timeout 20 — allow that command at least 20s
#
# The second of the two forge calls: mr_create prints the request URL and nothing else,
# its head and base are read back from argv rather than inferred from that URL, a successful call
# that printed no ^https?:// line is refused, and the argv it builds carries every state, the
# 100-cap, --yes for glab's non-interactive submit, and no reviewer/label/draft/fork flag.
# zero_funcs sources everything above zero.sh's own dispatch, so the functions below become
# callable without a subcommand that does not exist; mrsetup gives them a single real repo
# standing in for both roles — all they need is a real COORD_GITDIR and a real TARGET_ROOT —
# and the stub gh/glab supplies the canned JSON, the URL and the exit code each case wants
# back.

# Setup
TU="$TESTROOT/U-009-mr-create"; mkdir -p "$TU/bin" "$TU/stub"
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

# U23 — mr_create: URL-only output (both CLIs), head/base read back from argv, not inferred from the URL
mrsetup u23
Z="$TU/u23/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"
  printf 'https://github.com/acme/api/pull/9\n' > "$TU/stub/gh-create.out"
  rc=0; out=$(mr_create feature-x "Title X" /dev/null) || rc=$?
  check "U23 gh rc" "$rc" "0"
  check "U23 gh prints URL only" "$out" "https://github.com/acme/api/pull/9"
  check "U23 gh head explicit" "$(tail -1 "$TU/stub/gh.argv" | grep -c -- '--head feature-x')" "1"
  check "U23 gh base explicit" "$(tail -1 "$TU/stub/gh.argv" | grep -c -- '--base main')" "1"
  rm -f "$TU/stub/gh-create.out"
)
( zero_funcs "$Z"; FORGE=glab; ORIGIN_URL="https://gitlab.example.com/acme/api.git"
  printf 'Creating merge request for feature-y into main in acme/api\n!11 feature-y\nhttps://gitlab.example.com/acme/api/-/merge_requests/11\n' \
    > "$TU/stub/glab-create.out"
  rc=0; out=$(mr_create feature-y "Title Y" /dev/null) || rc=$?
  check "U23 glab rc" "$rc" "0"
  check "U23 glab multi-line reduced" "$out" "https://gitlab.example.com/acme/api/-/merge_requests/11"
  check "U23 glab source explicit" "$(tail -1 "$TU/stub/glab.argv" | grep -c -- '--source-branch feature-y')" "1"
  check "U23 glab target explicit" "$(tail -1 "$TU/stub/glab.argv" | grep -c -- '--target-branch main')" "1"
  rm -f "$TU/stub/glab-create.out"
)
# U23 PASS.

# U24 — mr_create refuses a successful call that printed no ^https?:// line, output on stderr
mrsetup u24
Z="$TU/u24/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"
  printf 'some unexpected line with no url\n' > "$TU/stub/gh-create.out"
  rc=0; out=$(mr_create branch-z T /dev/null 2>"$TU/u24err") || rc=$?
  check "U24 rc non-zero on missing URL line" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
  check "U24 stdout empty" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"
  check "U24 stderr carries the CLI's output" "$(grep -c 'some unexpected line with no url' "$TU/u24err")" "1"
  rm -f "$TU/stub/gh-create.out"
)
# U24 PASS.

# U25 — every-state + 100-cap argv, --yes (glab non-interactive submit), no reviewer/label/draft/fork flag
mrsetup u25
Z="$TU/u25/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"
  printf '[]' > "$TU/stub/gh-list.out"
  mr_list any-branch >/dev/null
  check "U25 gh list: every state (--state all)" "$(tail -1 "$TU/stub/gh.argv" | grep -c -- '--state all')" "1"
  check "U25 gh list: 100 cap (--limit 100)" "$(tail -1 "$TU/stub/gh.argv" | grep -c -- '--limit 100')" "1"

  printf 'https://github.com/acme/api/pull/1\n' > "$TU/stub/gh-create.out"
  mr_create any-branch T /dev/null >/dev/null
  argv="$(tail -1 "$TU/stub/gh.argv")"
  check "U25 gh create: no reviewer/label/draft/fill/web/milestone/assignee flag" "$(printf '%s' "$argv" | grep -cE -- '--(reviewer|label|draft|fill|web|milestone|assignee)')" "0"
  rm -f "$TU/stub/gh-list.out" "$TU/stub/gh-create.out"
)
( zero_funcs "$Z"; FORGE=glab; ORIGIN_URL="https://gitlab.example.com/acme/api.git"
  printf '[]' > "$TU/stub/glab-list.out"
  mr_list any-branch >/dev/null
  argv="$(tail -1 "$TU/stub/glab.argv")"
  check "U25 glab list: every state (--all)" "$(printf '%s' "$argv" | grep -c -- '--all')" "1"
  check "U25 glab list: 100 cap (--per-page 100)" "$(printf '%s' "$argv" | grep -c -- '--per-page 100')" "1"
  check "U25 glab list: newest-first (--order/--sort)" "$(printf '%s' "$argv" | grep -c -- '--order created_at --sort desc')" "1"

  printf 'https://gitlab.example.com/acme/api/-/merge_requests/2\n' > "$TU/stub/glab-create.out"
  mr_create any-branch T /dev/null >/dev/null
  argv="$(tail -1 "$TU/stub/glab.argv")"
  check "U25 glab create: --yes (non-interactive submit)" "$(printf '%s' "$argv" | grep -c -- '--yes')" "1"
  check "U25 glab create: no reviewer/label/draft/fill/web/milestone/assignee flag" "$(printf '%s' "$argv" | grep -cE -- '--(reviewer|label|draft|fill|web|milestone|assignee)')" "0"
  rm -f "$TU/stub/glab-list.out" "$TU/stub/glab-create.out"
)
# U25 PASS.

# U27 — mr_create names the repository explicitly (--repo/-R), never the caller's cwd; stdin closed; a single $FORGE dispatch
mrsetup u27
( cd "$TU/u27"; git remote add upstream "$TU/u27-upstream-unreachable.git" )
Z="$TU/u27/.git/zero.sh"
before="$(pwd)"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"
  printf 'https://github.com/acme/api/pull/1\n' > "$TU/stub/gh-create.out"
  mr_create branch-x T /dev/null >/dev/null
  check "U27 gh create --repo carries ORIGIN_URL" "$(tail -1 "$TU/stub/gh.argv" | grep -c -- "--repo $ORIGIN_URL")" "1"
  check "U27 gh create cwd unchanged, upstream never read" "$([ "$(tail -1 "$TU/stub/gh.cwd")" = "$before" ] && echo yes || echo no)" "yes"
  rm -f "$TU/stub/gh-create.out"
)
( zero_funcs "$Z"; FORGE=glab; ORIGIN_URL="https://gitlab.example.com/acme/api.git"
  printf 'https://gitlab.example.com/acme/api/-/merge_requests/1\n' > "$TU/stub/glab-create.out"
  mr_create branch-x T /dev/null >/dev/null
  check "U27 glab create --repo carries ORIGIN_URL" "$(tail -1 "$TU/stub/glab.argv" | grep -c -- "--repo $ORIGIN_URL")" "1"
  rm -f "$TU/stub/glab-create.out"
)
check "U27 mr_create reads stdin from /dev/null (both CLIs)" "$(sed -n '/^mr_create()/,/^}/p' "$Z" | grep -c '</dev/null')" "2"
check "U27 mr_create dispatches \$FORGE exactly once" "$(sed -n '/^mr_create()/,/^}/p' "$Z" | grep -cF '"$FORGE"')" "1"
# U27 PASS — mr_create names the repository to both CLIs as an argument carrying the baked
# ORIGIN_URL, never a scratch checkout's own remotes; its cwd is whatever the caller's was.

# U32 — mr_create: an unmatched $FORGE fails loudly, naming the value
mrsetup u32
Z="$TU/u32/.git/zero.sh"
( zero_funcs "$Z"; FORGE=bitbucket; ORIGIN_URL="https://bitbucket.example.com/acme/api.git"
  rc=0; out=$(mr_create x T /dev/null 2>"$TU/u32err") || rc=$?
  check "U32 non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
  check "U32 no url printed" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"
  check "U32 names the value" "$(grep -c 'bitbucket' "$TU/u32err")" "1"
)
# U32 PASS — a $FORGE mr_create does not implement is a loud, non-zero, empty-output
# failure naming the value.

# U33 — mr_create neutralizes GH_REPO/GITLAB_REPO/GH_HOST for the call, so $ORIGIN_URL is the sole candidate
mrsetup u33
Z="$TU/u33/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"
  export GH_REPO=someone-else/other GH_HOST=github.example.com GITLAB_REPO=someone-else/other
  printf 'https://github.com/acme/api/pull/1\n' > "$TU/stub/gh-create.out"
  rc=0; mr_create branch-x T /dev/null >/dev/null || rc=$?
  check "U33 gh create still succeeds" "$([ "$rc" -eq 0 ] && echo yes || echo no)" "yes"
  check "U33 gh: CLI saw no GH_REPO/GITLAB_REPO/GH_HOST" "$(tail -1 "$TU/stub/gh.env")" "GH_REPO= GITLAB_REPO= GH_HOST="
  rm -f "$TU/stub/gh-create.out"
)
( zero_funcs "$Z"; FORGE=glab; ORIGIN_URL="https://gitlab.example.com/acme/api.git"
  export GH_REPO=someone-else/other GH_HOST=github.example.com GITLAB_REPO=someone-else/other
  printf 'https://gitlab.example.com/acme/api/-/merge_requests/1\n' > "$TU/stub/glab-create.out"
  rc=0; mr_create branch-x T /dev/null >/dev/null || rc=$?
  check "U33 glab create still succeeds" "$([ "$rc" -eq 0 ] && echo yes || echo no)" "yes"
  check "U33 glab: CLI saw no GH_REPO/GITLAB_REPO/GH_HOST" "$(tail -1 "$TU/stub/glab.env")" "GH_REPO= GITLAB_REPO= GH_HOST="
  rm -f "$TU/stub/glab-create.out"
)
# U33 PASS — GH_REPO/GITLAB_REPO/GH_HOST are unset inside the call, so the argument
# naming $ORIGIN_URL is the sole candidate; neither call refuses.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
