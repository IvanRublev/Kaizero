#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=90s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# ISSUE-085-prompt-and-docs — the generated session prompt of both builders carries the BLOCKED
# paragraph, the `park` exits, the box legend and the only-`[x]`-unblocks rule; the README, the
# `merge` comment and the prompts no longer call `?` "Landed, needs human review".
# Needs real claude: no — a stub `claude` prints its argv, which holds the prompt
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/ISSUE-085-prompt-and-docs

TU="$TESTROOT/ISSUE-085-prompt-and-docs"; mkdir -p "$TU/bin"
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\nprintf "ARGV: %%s\\n" "$*"\nexit 0\n' > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
mkrepo(){ mkdir -p "$1"; ( cd "$1" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git remote add origin "https://github.com/acme/$(basename "$1").git" ); }
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1" || exit 1; git config user.email t@t.t; git config user.name test )
}
cat > "$TU/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1 ${2:-}" = "pr list" ] && [ "${3:-}" = "--json" ] && [ $# -eq 3 ]; then printf '%s\n' 'number headRefOid baseRefName state url' >&2; exit 1; fi
for a in "$@"; do [ "$a" = --help ] && { printf '%s\n' --repo --head --state --limit --json --base --title --body-file --hostname; exit 0; }; done
exit 0
STUB
chmod +x "$TU/bin/gh"
for t in flock git timeout jq; do ln -sf "$(command -v "$t")" "$TU/bin/$t"; done
export PATH="$TU/bin:/usr/bin:/bin" KAIZERO_FORGE=gh

# prompt_of <mode> <name> — the prompt a launch hands claude, mode = local | mr
prompt_of(){
  if [ "$1" = local ]; then
    mkrepo "$TU/$2"; ( cd "$TU/$2"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo
      KAIZERO_MAX_LOOPS=1 timeout 20 bash "$SCRIPT" --local-merge todo.md -t x 2>&1 )
  else
    mkorigin "$TU/$2"; mkrepo "$TU/$2plan"; ( cd "$TU/$2plan"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo )
    ( cd "$TU/$2"; KAIZERO_MAX_LOOPS=1 timeout 20 bash "$SCRIPT" "$TU/$2plan/todo.md" -t x 2>&1 )
  fi
}

for mode in local mr; do
  out=$(prompt_of "$mode" "p-$mode")
  check "$mode BLOCKED paragraph present" "$(printf '%s\n' "$out" | grep -c 'BLOCKED — a Task is blocked when no action inside its worktree')" "1"
  check "$mode Blocked line format" "$(printf '%s\n' "$out" | grep -c '> Blocked YYYY-MM-DD HH:MM±HHMM <cause>; evidence: <observed>; unblocks when: <condition>')" "1"
  check "$mode park exit 0" "$(printf '%s\n' "$out" | grep -c 'exit 0 → blocked')" "1"
  check "$mode park command named" "$(printf '%s\n' "$out" | grep -c 'zero.sh park task_id')" "2"
  check "$mode legend [x]" "$(printf '%s\n' "$out" | grep -c '\[x\] = Landed')" "1"
  check "$mode legend [🚧]" "$(printf '%s\n' "$out" | grep -c '\[🚧\] = blocked')" "1"
  check "$mode legend [?]" "$(printf '%s\n' "$out" | grep -c '\[?\] = branches review needed')" "1"
  check "$mode legend other symbols" "$(printf '%s\n' "$out" | grep -c 'any other symbol = not Landed and not claimable')" "1"
  check "$mode Landed line holds the [x] ids" "$(printf '%s\n' "$out" | grep -c 'a `Landed:` line with the `\[x\]` ids')" "1"
  check "$mode only [x] unblocks" "$(printf '%s\n' "$out" | grep -c 'Only `\[x\]` unblocks')" "1"
  check "$mode no placeholder left" "$(printf '%s\n' "$out" | grep -c '@@')" "0"
  check "$mode no review-convention wording" "$(printf '%s\n' "$out" | grep -c 'Landed, needs human review\|Landed code awaiting review')" "0"
  check "$mode BLOCKED and park text carry no ⛔" "$(printf '%s\n' "$out" | sed -n '/BLOCKED — a Task is blocked/,/END YOUR TURN\./p;/PARK (a blocked Task/,/then stop\./p' | grep -c '⛔')" "0"
done

# docs and comments — the README documents both boxes with their lines; the old convention is gone
check "README documents [🚧]" "$(grep -c '\[🚧\]' "$REPO/README.md" | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes"
check "README documents the Blocked line" "$(grep -c '^> Blocked ' "$REPO/README.md")" "1"
check "README names [?] as Branches review needed" "$(grep -c '`\[?\]` | Branches review needed' "$REPO/README.md")" "1"
check "README documents the review-needed line" "$(grep -c '`> Branches review needed YYYY-MM-DD HH:MM±HHMM <cause>`' "$REPO/README.md")" "1"
check "README carries no review convention for ?" "$(grep -c 'needs human review\|Landed code awaiting review' "$REPO/README.md")" "0"
check "kaizero.sh carries no review convention for ?" "$(grep -c 'needs human review\|Landed code awaiting review' "$REAL_SCRIPT")" "0"

cd "$TESTROOT"
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
