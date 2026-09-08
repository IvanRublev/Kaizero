#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-016-sync-mrs-and-a-human-edit-mid-pass — a box cleared to `[ ]` between the read and the
# write is left untouched.
# Needs real `claude`: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under `$TESTROOT`: `$TESTROOT/U-016-sync-mrs-and-a-human-edit-mid-pass`
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# The one interference a lock cannot cover: a human clearing the box to `[ ]` between `sync_mrs`'s
# read and its write. The pass leaves that box alone rather than writing the answer it had already
# resolved. `zero_funcs` sources everything above `zero.sh`'s own dispatch, so the functions below
# become callable without a subcommand that does not exist; `mrsetup` gives them a single real
# repo standing in for both roles — all they need is a real `COORD_GITDIR` and a real
# `TARGET_ROOT` — and the stub `gh`/`glab` supplies the canned JSON, the URL and the exit code
# each case wants back.

# Setup
TU="$TESTROOT/U-016-sync-mrs-and-a-human-edit-mid-pass"; mkdir -p "$TU/bin" "$TU/stub"
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

# U51 — a human clearing the box to `[ ]` between `sync_mrs`'s read and its write is left untouched
mrsetup u51
( cd "$TU/u51"
  git checkout -qb u51a-fix-thing; echo y > g; git add g; git commit -qm work
  git checkout -q main
  printf '# todo\n\n- [\xe2\x86\x91] u51a fix thing\n' > todo.md
  git add todo.md; git commit -qm "mark u51a inflight"
)
Z="$TU/u51/.git/zero.sh"
cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":80,"headRefOid":"aaa","baseRefName":"main","state":"CLOSED","url":"https://x/80"}]
JSON
rm -f "$TU/u51ready" "$TU/u51go" "$TU/u51gitcount"
mkdir -p "$TU/u51bin"
realgit=$(type -P git)
# 039h real-subcommand conversion: `bash "$Z" sync-mrs` is a separate process, so an in-shell
# `box_symbol_on_base` override (as the old in-process version used) never reaches it. A `git`
# stub ahead of it on PATH intercepts the exact call `box_symbol_on_base`/`ids_with_box`/
# `todo_lines` all share (`git -C <root> show main:todo.md`) and pauses only on the THIRD such
# call in one sync_mrs pass — sweep_mr_bodies' todo_lines is #1, ids_with_box('↑') is #2, and
# box_symbol_on_base's step-3 re-read (the one this case targets) is #3 — then execs the real
# git for every call, intercepted or not, so nothing else about the pass is touched.
cat > "$TU/u51bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = -C ] && [ "\$3" = show ] && [ "\$4" = "main:todo.md" ]; then
  n=\$(( \$(cat "$TU/u51gitcount" 2>/dev/null || echo 0) + 1 ))
  echo "\$n" > "$TU/u51gitcount"
  if [ "\$n" -eq 3 ]; then
    : > "$TU/u51ready"
    while [ ! -f "$TU/u51go" ]; do sleep 0.05; done
  fi
fi
exec "$realgit" "\$@"
EOF
chmod +x "$TU/u51bin/git"
( PATH="$TU/u51bin:$PATH" FORGE=gh ORIGIN_URL="https://github.com/acme/api.git" MR_MODE=1 \
    bash "$Z" sync-mrs > "$TU/u51.out" 2>"$TU/u51.err" ) &
pid=$!
i=0; while [ ! -f "$TU/u51ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
check "U51 sync reached the re-read" "$([ -f "$TU/u51ready" ] && echo yes || echo no)" "yes"
# the human takes the task back, editing the same coordination checkout directly — sync_mrs's
# own child process is paused (not mid-git-operation) at this point, so this is race-free.
( cd "$TU/u51"
  sed -i.bak 's/\[.\] u51a/[ ] u51a/' todo.md; rm -f todo.md.bak
  git add todo.md; git commit -qm "human takes the task back" )
: > "$TU/u51go"
wait "$pid"
u51final=$(bash "$Z" box-symbol-on-base u51a)
check "U51 box left at the human's edit" "$([ "$u51final" = " " ] && echo unchecked || echo "'$u51final'")" "unchecked"
rm -f "$TU/stub/gh-list.out"
# - **U51 PASS** — the re-read happens after `MERGE_LOCK` is held and `$COORD_BASE` is checked out
#   fresh, so the human's direct commit lands on the same ref sync's own re-read sees; `[ "$cur" =
#   "↑" ] || continue` (sync_mrs's own per-line skip) skips a box no longer `↑`, and the human's `[ ]` survives untouched —
#   the task is claimable again on the next pass. The symmetric case, a box cleared *before* step
#   1's scan, needs no separate test: it is the same `ids_with_box '↑'` filter U29's "no `↑` left"
#   case already exercises — an id not in that set is never looked at at all.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
