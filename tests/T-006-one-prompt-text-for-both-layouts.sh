#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=85s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-006-one-prompt-text-for-both-layouts — the same prompt whether the roles are one repository
# or two, and the SAME_REPO absence check.
# Needs real claude: no — no claude is launched (claude still has to be on PATH: run_doctor tests
# `command -v claude` before any startup guard runs)
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T-006-one-prompt-text-for-both-layouts, $TESTROOT/T, $TESTROOT/T21
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# One prompt text serves both layouts. The stub echoes its own argv, so the
# exact prompt text claude is handed can be compared between a one-repository run and a
# two-repository one, with the SAME_REPO absence check beside it.

# Setup
TT="$TESTROOT/T-006-one-prompt-text-for-both-layouts"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktodo(){ ( cd "$1"; echo '- [ ] G1 noop' > todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/G1.md
  git add -A; git commit -qm todo ); }

# T21 — one prompt text for both cases, and the SAME_REPO absence check [$TESTROOT/T] (stub claude)
#
# The stub echoes its own argv (same trick as Scenario L), so the exact prompt text claude is
# launched with is captured verbatim — once per repository count — and diffed structurally
# instead of eyeballed.
# want 7 — definition, the same-repository MR refusal, bake line, banner, and exactly the 3
# heredoc consultations: acquire_target, teardown_target, merge_task
check "T21 SAME_REPO count" "$(grep -c 'SAME_REPO' "$REAL_SCRIPT")" "7"
# no network verbs, unconditionally: dropped — the source now carries legitimate
# fetch/gh/origin/push words gated behind MR mode. U-001-mr-mode-launch-refusals's own absence check takes over this
# job — stubs that fail the run if called prove none of them fire under --local-merge.

T21="$TESTROOT/T21"; mkdir -p "$T21/same" "$T21/code" "$T21/plan" "$T21/bin"
cat > "$T21/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
printf 'ARGV: %s\n' "$*"
exit 0
EOF
chmod +x "$T21/bin/claude"
mkrepo "$T21/same"; mktodo "$T21/same"
mkrepo "$T21/code"; mkrepo "$T21/plan"; mktodo "$T21/plan"

( cd "$T21/same"; PATH="$T21/bin:$PATH" timeout 20 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$T21/same.log" 2>&1 )
( cd "$T21/code"; PATH="$T21/bin:$PATH" timeout 20 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge "$T21/plan/todo.md" -t x > "$T21/two.log" 2>&1 )

check "T21 same: no @@ placeholder left" "$(grep -c '@@' "$T21/same.log")" "0"
check "T21 same: todo is absolute" "$(grep -c "from $T21/same/todo.md in PARALLEL" "$T21/same.log")" "1"
check "T21 same: zero.sh is absolute" "$(grep -c "absolute path, $T21/same/.git/zero.sh" "$T21/same.log")" "1"
check "T21 two: no @@ placeholder left" "$(grep -c '@@' "$T21/two.log")" "0"
check "T21 two: todo is absolute" "$(grep -c "from $T21/plan/todo.md in PARALLEL" "$T21/two.log")" "1"
check "T21 two: zero.sh is absolute" "$(grep -c "absolute path, $T21/plan/.git/zero.sh" "$T21/two.log")" "1"
# the whole multi-line prompt body is one raw argv, so it lands on the log as many real
# newlines, not one line — body pulls it out from "You are ONE" (the argv prefix before it,
# --name's random nickname, is excluded) through the algorithm's own fixed closing sentence
# (stable text, unlike the random-nickname report lines that follow it in the log).
body(){ awk '/You are ONE/{f=1} f{sub(/.*You are ONE/,"You are ONE"); print} /the closing report\./{f=0}' "$1"; }
body "$T21/same.log" > "$T21/same.body"
body "$T21/two.log" > "$T21/two.body"
n_same_body="$(wc -l < "$T21/same.body" | tr -d ' ')"
check "T21 same body >= 60 lines" "$([ "$n_same_body" -ge 60 ] && echo yes || echo NO)" "yes"
# one text, only the baked path differs
check "T21 same == two, prompt bodies" "$(diff <(sed "s#$T21/same#@R@#g" "$T21/same.body") <(sed "s#$T21/plan#@R@#g" "$T21/two.body") >/dev/null 2>&1 && echo yes || echo NO)" "yes"
check "T21 exit-5 routing text present" "$(grep -c 'exit 5 → do what stderr says, retry once, then stop' "$T21/same.log")" "1"
check "T21 exit-2 routing text present" "$(grep -c 'exit 2 → a CODE CONFLICT' "$T21/same.log")" "1"
check "T21 only \$wt named in prompt" "$(grep -o '\$[A-Za-z_][A-Za-z_0-9]*' "$T21/same.body" | sort -u | tr '\n' ' ')" '$wt '
check "T21 no 'twt' in prompt" "$(grep -c 'twt' "$T21/same.body")" "0"

# invalid-symbol regression: was exit 2 (misread by the agent as a conflict), now exit 5 (a land-
# gate refusal the agent should retry, not hand off as a conflict).
ZERO21="$T21/plan/.git/zero.sh"
cat > "$T21/drive.sh" <<DRIVE
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1
set -uo pipefail
FAILED=0; ERRORED=0
cd "$T21/plan"
t1=\$("$ZERO21" claim G1)
echo work > "\$t1/f.txt"; git -C "\$t1" add f.txt; git -C "\$t1" commit -qm work
out=\$("$ZERO21" merge G1 "\$t1" "xy" 2>&1); rc=\$?
# a land-gate refusal, not a conflict
check "T21 invalid symbol exit" "\$rc" "5"
[ "\$FAILED" = 0 ] && [ "\$ERRORED" = 0 ]
DRIVE
bash "$T21/drive.sh" || FAILED=1


# T21 PASS — the SAME_REPO token appears on exactly 7 lines in kaizero.sh; both
# launches leave no @@…@@ placeholder unresolved;
# each resolves its own todo reference and its zero.sh call to an absolute path; the two
# captured prompt bodies (each at least 60 lines) are identical once each launch's own root is
# normalized out — one text, not two; the exit-5/exit-2 routing sentences are present verbatim;
# the only shell variable the prompt names is $wt and twt never appears in it; and merge's
# invalid-symbol guard now raises exit 5, matching the land gate's own refusal family instead of
# the conflict one.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
