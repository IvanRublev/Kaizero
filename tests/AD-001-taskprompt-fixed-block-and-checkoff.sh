#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=110s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# AD-001-taskprompt-fixed-block-and-checkoff — both prompt builders always emit the fixed step-c
# instruction block (tick-commit, both gates), --taskprompt only appends alterations after it, and
# `zero.sh commit_ac_checkoff` commits a Task file's own checkoff directly onto COORD_BASE.
# Needs real claude: no — a stub claude echoes its own argv and exits.
# Tools beyond the shared prerequisites: none.
# Folder under $TESTROOT: $TESTROOT/AD-001-taskprompt-fixed-block-and-checkoff, $TESTROOT/AD1,
# $TESTROOT/AD2
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s.
# Cross-references named in the body below: Scenario T-006 -> tests/T-006-one-prompt-text-for-both-layouts.sh

# Setup
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktodo(){ ( cd "$1"; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }

# AD1 — the fixed block, with and without --taskprompt   [$TESTROOT/AD1]   (stub claude)
#
# The stub echoes its own argv (same trick as Scenario T-006), so the exact prompt text is
# captured verbatim across three launches — no flag, -t TEXT, --taskprompt=TEXT — and checked
# structurally.
AD1="$TESTROOT/AD1"; mkdir -p "$AD1/repo" "$AD1/bin"
cat > "$AD1/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
printf 'ARGV: %s\n' "$*"
exit 0
EOF
chmod +x "$AD1/bin/claude"
mkrepo "$AD1/repo"; mktodo "$AD1/repo"

( cd "$AD1/repo"; PATH="$AD1/bin:$PATH" timeout 20 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md > "$AD1/noflag.log" 2>&1 )
( cd "$AD1/repo"; PATH="$AD1/bin:$PATH" timeout 20 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t "Use TDD strictly." > "$AD1/flag.log" 2>&1 )
( cd "$AD1/repo"; PATH="$AD1/bin:$PATH" timeout 20 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md --taskprompt="Use TDD strictly." > "$AD1/eqflag.log" 2>&1 )

order(){ awk '
  /YYYY-MM-DD HH:MM.HHMM <short evidence>/{z=NR}
  /commit that checkoff/{a=NR}
  /ACCEPTANCE CRITERIA GATE/{b=NR}
  /AGENTIC SELF-REVIEW GATE/{c=NR}
  /Acceptance criteria gate: passed/{d=NR}
  /Agentic self-review gate: passed/{e=NR}
  END{ if (z && a && b && c && d && e && z<a && a<b && b<c && c<d && d<e) print "yes"; else print "NO" }
' "$1"; }
check "AD1 fixed block, in order" "$(order "$AD1/noflag.log")" "yes"
# one evidence-line instruction, before the checkoff commit
check "AD1 per-tick evidence line" "$(grep -c '> YYYY-MM-DD HH:MM.HHMM <short evidence>' "$AD1/noflag.log")" "1"
check "AD1 no @@ placeholder left" "$(grep -c '@@' "$AD1/noflag.log")" "0"
check "AD1 exception clause present once" "$(grep -c 'one exception to' "$AD1/noflag.log")" "1"
# not "no code-review/ponytail named": the AGENTIC SELF-REVIEW GATE's own fixed text
# (kaizero.sh's build_zero_prompt/build_mr_prompt) intentionally names "/code-review" as its
# built-in fallback when a setup defines no review/verify gate of its own — that's designed
# behavior on the no-flag path this case exercises, not a leak to guard against.
check "AD1 no 'skip review' language" "$(grep -c 'skip review' "$AD1/noflag.log")" "0"

block(){ awk '/Implement the task following your setup/{f=1} f{print} f&&/^   d\. MERGE:|DESCRIBE:/{exit}' "$1"; }
block "$AD1/noflag.log" > "$AD1/block.txt"
check "AD1 no 'land' verb in the block" "$(grep -ci '\bland\b' "$AD1/block.txt")" "0"
# stated once, earlier in step c
check "AD1 tick not restated in block" "$(grep -c '\[ \]\`→\`\[x\]\`' "$AD1/block.txt")" "0"
check "AD1 no fixed iteration count" "$(grep -c 'up to [0-9]* time' "$AD1/block.txt")" "0"
# no stray line between the block's last line and step d/DESCRIBE
check "AD1 next line after block is d/DESCRIBE" "$(awk '/commit_ac_checkoff task_id`\./{n++; if(n==2){getline; print; exit}}' "$AD1/noflag.log" | grep -c '^   d\. MERGE:\|DESCRIBE:')" "1"
check "AD1 taskprompt appended after (-t)" "$(awk '/commit_ac_checkoff task_id`\./{n++; if(n==2){getline; print; exit}}' "$AD1/flag.log" | grep -c 'Use TDD strictly\.')" "1"
check "AD1 fixed block still whole (-t)" "$(grep -c 'commit that checkoff' "$AD1/flag.log")" "1"

body(){ awk '/You are ONE/{f=1} f{sub(/.*You are ONE/,"You are ONE"); print} /the closing report\./{f=0}' "$1"; }
body "$AD1/flag.log" > "$AD1/flag.body"; body "$AD1/eqflag.log" > "$AD1/eq.body"
# the -t and --taskprompt=TEXT forms render identically
check "AD1 -t and --taskprompt= agree" "$(diff "$AD1/flag.body" "$AD1/eq.body" >/dev/null 2>&1 && echo yes || echo NO)" "yes"
# AD1 PASS — with no --taskprompt, the per-tick evidence-line instruction, the tick-and-commit
# instruction and both named gates (Acceptance Criteria, Agentic Self-Review) and their two dated
# notes appear, in that order, with no leftover @@...@@ marker; the Task-file exception clause
# appears exactly once; the block names no fixed iteration count and never says "skip review";
# the block never uses the verb "land" and never restates the
# tick instruction (stated once, earlier in step c); the block's last line is immediately followed
# by step d/DESCRIBE, no stray line between. With -t "Use TDD strictly." that text is appended
# right after the block, which stays whole; the equal-sign form renders the identical prompt body.

# AD2 — commit_ac_checkoff: destination, scope, idempotency, error path   [$TESTROOT/AD2]   (no claude)
AD2="$TESTROOT/AD2/same"; mkdir -p "$AD2"
mkrepo "$AD2"; mktodo "$AD2"
( cd "$AD2"; mkdir -p tasks
  printf '## TASK G1\n### Acceptance criteria\n- [ ] a thing\n' > tasks/G1.md
  git add tasks/G1.md; git commit -qm "add G1 task file" )

check "AD2 usage names the subcommand" "$(grep -c 'commit_ac_checkoff N' "$REAL_SCRIPT")" "1"

( cd "$AD2"; KAIZERO_TEST_EMIT=1 bash "$SCRIPT" --local-merge todo.md >/dev/null 2>&1 || true )
ZERO="$AD2/.git/zero.sh"
check "AD2 emitted zero.sh has it too" "$(grep -c 'commit_ac_checkoff)' "$ZERO")" "1"

( cd "$AD2"
  sed -i.bak 's/- \[ \] a thing/- [x] a thing/' tasks/G1.md; rm -f tasks/G1.md.bak
  echo "peer dirt, must not be swept in" >> f
  out=$("$ZERO" commit_ac_checkoff G1 2>&1); rc=$?
  check "AD2 first call exit" "$rc" "0"
  check "AD2 first call no error output" "${#out}" "0"
  check "AD2 commit lands on main" "$(git log -1 --format=%s)" "commit_ac_checkoff G1"
  check "AD2 branch stays main" "$(git symbolic-ref --short HEAD)" "main"
  check "AD2 commit touches only G1.md" "$(git show --stat -1 --format='' | head -1 | awk '{print $1}')" "tasks/G1.md"
  # f is still dirty, not committed
  check "AD2 peer dirty file untouched" "$(git status --short | grep -c '^ M f$')" "1"

  before=$(git rev-parse HEAD)
  out2=$("$ZERO" commit_ac_checkoff G1 2>&1); rc2=$?
  check "AD2 idempotent retry exit" "$rc2" "0"
  check "AD2 idempotent retry, no new commit" "$([ "$before" = "$(git rev-parse HEAD)" ] && echo yes || echo NO)" "yes"

  out3=$("$ZERO" commit_ac_checkoff NOPE 2>&1); rc3=$?
  check "AD2 missing-id exit" "$rc3" "6"
  check "AD2 missing-id message" "$(printf '%s' "$out3" | grep -c 'missing-task-file NOPE')" "1"
)
# AD2 PASS — commit_ac_checkoff is named in zero.sh's usage line, both in the source and in an
# emitted zero.sh; ticking tasks/G1.md and calling commit_ac_checkoff G1 commits that file alone,
# directly on the base branch (main), with no error output; a concurrently dirty unrelated file
# (f) is left uncommitted; a second call with nothing new to commit exits 0 and adds no commit;
# an unresolvable id exits 6 with the standard missing-task-file message.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
