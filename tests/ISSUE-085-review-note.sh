#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"


# --- Setup ---
TU="$TESTROOT/ISSUE-085-review-note"; mkdir -p "$TU/bin" "$TU/stub"
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


# ISSUE-085-review-note — every `[?]` the request sync writes carries a `> Branches review needed`
# line at the end of the Task file's Acceptance criteria section, committed with the box, its
# timestamp read from the shell clock by Kaizero itself.

mrsetup n1
( cd "$TU/n1"
  mkdir -p tasks
  for i in n85a n85b n85c n85d; do printf '### Acceptance criteria\n\n- [ ] first\n\n> Acceptance criteria gate: passed 2026-10-01 10:00+0000\n' > "tasks/$i.md"; done
  git checkout -qb n85a-fix-thing;  echo y > g; git add g; git commit -qm work
  git checkout -qb n85a-other main; echo z > h; git add h; git commit -qm work2
  git checkout -qb n85c-widget main; echo w > i; git add i; git commit -qm work3
  git checkout -qb n85d-gadget main; echo v > j; git add j; git commit -qm work4
  git checkout -q main
  printf '# todo\n\n- [\xe2\x86\x91] n85a two branches\n- [\xe2\x86\x91] n85b no branch\n- [\xe2\x86\x91] n85c no request\n- [ ] n85d elsewhere\n' > todo.md
  git add -A; git commit -qm "mark all inflight"
)
Z="$TU/n1/.git/zero.sh"
( zero_funcs "$Z"; FORGE=gh; ORIGIN_URL="https://github.com/acme/api.git"; MR_MODE=1
  printf '[]' > "$TU/stub/gh-list.out"
  out=$(sync_mrs)
  # n85d: the request merged into a base other than the target
  sed -i.bak 's/^- \[ \] n85d/- [↑] n85d/' "$TU/n1/todo.md"; rm -f "$TU/n1/todo.md.bak"
  git -C "$TU/n1" add todo.md; git -C "$TU/n1" commit -qm "n85d inflight"
  printf '[{"number":7,"headRefOid":"abc","baseRefName":"release","state":"MERGED","url":"https://x/pull/7"}]' > "$TU/stub/gh-list.out"
  out=$(sync_mrs)
  for id in n85a n85b n85c n85d; do
    tf="$TU/n1/tasks/$id.md"
    check "N1 $id box [?]" "$(box_symbol_on_base "$id")" "?"
    check "N1 $id one review line" "$(grep -c '^> Branches review needed ' "$tf")" "1"
    ts=$(sed -n 's/^> Branches review needed \([0-9-]* [0-9:]*[+-][0-9]*\) .*/\1/p' "$tf")
    check "N1 $id timestamp within a minute of the clock" "$(python3 - "$ts" <<'PY'
import sys, datetime
t = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%d %H:%M%z")
print("ok" if abs((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()) < 120 else "off")
PY
)" "ok"
    # at the end of the section: after the gate-note quote block, no blank line between
    check "N1 $id line follows the gate note" "$(grep -B1 '^> Branches review needed' "$tf" | head -1 | cut -c1-30)" "> Acceptance criteria gate: pa"
    check "N1 $id committed with the box" "$(git -C "$TU/n1" log --format=%H --diff-filter=M -n1 -- "tasks/$id.md" | head -1 | xargs -I{} git -C "$TU/n1" show --name-only --format= {} | sort | tr '\n' ' ')" "tasks/$id.md todo.md "
  done
  check "N1 no-branch cause" "$(grep -c 'no local branch for the id$' "$TU/n1/tasks/n85b.md")" "1"
  check "N1 two-branch cause" "$(grep -c 'two local branches for the id$' "$TU/n1/tasks/n85a.md")" "1"
  check "N1 no-request cause" "$(grep -c 'no request for branch n85c-widget$' "$TU/n1/tasks/n85c.md")" "1"
  check "N1 merged-elsewhere cause" "$(grep -c 'request https://x/pull/7 merged into release, not main$' "$TU/n1/tasks/n85d.md")" "1"
  rm -f "$TU/stub/gh-list.out"
  [ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
) || FAILED=1

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
