#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-034-sync-mrs-the-three-not-answered-causes — the three `[?]` causes `sync_mrs` cannot answer.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-034-sync-mrs-the-three-not-answered-causes
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# The three causes `sync_mrs` cannot answer land `[?]`: two local branches for one id, no local
# branch at all, and a branch with no request. `zero_funcs` sources everything above `zero.sh`'s own
# dispatch, so the functions below become callable without a subcommand that does not exist;
# `mrsetup` gives them a single real repo standing in for both roles — all they need is a real
# `COORD_GITDIR` and a real `TARGET_ROOT` — and the stub `gh`/`glab` supplies the canned JSON, the
# URL and the exit code each case wants back.

# --- Setup ---
TU="$TESTROOT/U-034-sync-mrs-the-three-not-answered-causes"; mkdir -p "$TU/bin" "$TU/stub"
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

# U39 — `sync_mrs`'s three `[?]` causes: two branches for an id, none, and a branch with no
# request at all
mrsetup u39
( cd "$TU/u39"
  git checkout -qb u39a-fix-thing;  echo y > g; git add g; git commit -qm work
  git checkout -qb u39a-other main; echo z > h; git add h; git commit -qm work2
  git checkout -qb u39c-widget main; echo w > i; git add i; git commit -qm work3
  git checkout -q main
  printf '# todo\n\n- [\xe2\x86\x91] u39a two branches\n- [\xe2\x86\x91] u39b no branch\n- [\xe2\x86\x91] u39c no request\n' > todo.md
  git add todo.md; git commit -qm "mark all inflight"
)
Z="$TU/u39/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  printf '[]' > "$TU/stub/gh-list.out"
  out=$(sync_mrs)
  check "U39 two-branch -> [?]" "$(box_symbol_on_base u39a)" "?"
  check "U39 two-branch line" "$(printf '%s\n' "$out" | grep -c 'sync u39a: two local branches for the id')" "1"
  check "U39 no-branch -> [?]" "$(box_symbol_on_base u39b)" "?"
  check "U39 no-branch line" "$(printf '%s\n' "$out" | grep -c 'sync u39b: no local branch for the id')" "1"
  check "U39 no-request -> [?]" "$(box_symbol_on_base u39c)" "?"
  check "U39 no-request line" "$(printf '%s\n' "$out" | grep -c 'sync u39c: no request for branch')" "1"
  # a request is opened by a Hand off, never by a landing
  check "U39 hint names the hand off" "$(printf '%s\n' "$out" | grep -c 'let the next hand off open it')" "1"
  check "U39 branches all kept" "$(git -C "$TARGET_ROOT" for-each-ref --format='%(refname:short)' 'refs/heads/u39*' | wc -l | tr -d ' ')" "3"
  rm -f "$TU/stub/gh-list.out"
  [ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
) || FAILED=1
# U39 PASS — the three `[?]` causes U29-U30 left unproven all land the box and leave every
# branch untouched.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
