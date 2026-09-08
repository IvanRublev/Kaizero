#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-012-release-and-claim-write-edge-cases — `release` with no path argument, and a `claim` whose
# `.owner` write fails.
# Needs real claude: no — a disposable driver process writes its own KAIZERO_SESSION_RECORD
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T25, $TESTROOT/T26
#
# `release <id>` with no path argument, and a claim whose `.owner` write fails must undo and
# refuse rather than believe it holds the task.

mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }

# T25 — `release <id>` with no path argument, and `usage:` shows it optional
T25="$TESTROOT/T25"; mkdir -p "$T25/code" "$T25/plan" "$T25/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T25/bin/claude"; chmod +x "$T25/bin/claude"
mkrepo "$T25/code"
( cd "$T25/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/EID.md
  printf -- '- [ ] EID exit me\n' > todo.md; git add todo.md tasks/EID.md; git commit -qm todo )
( cd "$T25/code"; PATH="$T25/bin:$PATH" KAIZERO_TASK_ID_PATTERN=. KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T25/plan/todo.md" >/dev/null 2>&1 || true )
ZERO25="$T25/plan/.git/zero.sh"
# the driver runs in its own bash subprocess (a real disposable session identity), so its results
# land in files the outer script reads back — check()'s FAILED/ERRORED live in this process only.
cat > "$T25/drive.sh" <<DRIVE
set -uo pipefail
cd "$T25/plan"
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1 KAIZERO_TASK_ID_PATTERN=.
"$ZERO25" claim EID >/dev/null
"$ZERO25" release EID; rc=\$?
echo "\$rc" > "$T25/exit.out"
"$ZERO25" 2>&1 | grep -c 'release N \[WT\]' > "$T25/usage.out"
DRIVE
bash "$T25/drive.sh"
# want 0 — no $3: unbound variable
check "T25 exit" "$(cat "$T25/exit.out")" "0"
check "T25 usage optional" "$(cat "$T25/usage.out")" "1"
# T25 PASS — release EID with no path argument runs instead of dying $3: unbound variable, and
# the usage line shows the path optional.

# T26 — a claim whose `.owner` cannot be written leaves no claim behind
# A first claim succeeds normally; its `.owner` is then hand-set to a dead owner (pid 999999,
# E-001's fabrication pattern) and chmod 000'd. The next claim takes the steal path, gets as far
# as re-acquiring the worktree, then fails at the write claim_owner attempts — it must undo and
# refuse rather than believe it holds the task.
T26="$TESTROOT/T26"; mkdir -p "$T26/code" "$T26/plan" "$T26/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T26/bin/claude"; chmod +x "$T26/bin/claude"
mkrepo "$T26/code"
( cd "$T26/plan"; git init -q -b main; git config user.email t@t.t; git config user.name test
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/WID.md
  printf -- '- [ ] WID write me\n' > todo.md; git add todo.md tasks/WID.md; git commit -qm todo )
( cd "$T26/code"; PATH="$T26/bin:$PATH" KAIZERO_TASK_ID_PATTERN=. KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$T26/plan/todo.md" >/dev/null 2>&1 || true )
ZERO26="$T26/plan/.git/zero.sh"
cat > "$T26/drive1.sh" <<DRIVE
set -uo pipefail
cd "$T26/plan"
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1 KAIZERO_TASK_ID_PATTERN=.
twt=\$("$ZERO26" claim WID)
echo "\$twt" > "$T26/wt1.out"
DRIVE
bash "$T26/drive1.sh"
wt1=$(cat "$T26/wt1.out")
own1=$(git -C "$T26/plan" worktree list --porcelain | awk -v b="refs/heads/main-task-WID" '/^worktree /{p=substr($0,10)} /^branch /{if(substr($0,8)==b){print p;exit}}')

printf '%s\n%s\n%s\n%s\n%s\n' 999999 fake "$(( $(date +%s) - 100 ))" A "$wt1" > "$own1/.owner"
chmod 000 "$own1/.owner"

cat > "$T26/drive2.sh" <<DRIVE2
set -uo pipefail
cd "$T26/plan"
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1 KAIZERO_TASK_ID_PATTERN=.
out=\$("$ZERO26" claim WID 2>/dev/null); rc=\$?
echo "\$rc" > "$T26/exit2.out"
[ -z "\$out" ] && echo yes > "$T26/nopath.out" || echo "NO (\$out)" > "$T26/nopath.out"
DRIVE2
bash "$T26/drive2.sh"
chmod 600 "$own1/.owner" 2>/dev/null || true
check "T26 exit" "$(cat "$T26/exit2.out")" "1"
# want yes — a failed write prints no path
check "T26 no path" "$(cat "$T26/nopath.out")" "yes"

cat > "$T26/drive3.sh" <<DRIVE3
set -uo pipefail
cd "$T26/plan"
REC="\$0.rec"
printf '%s\n%s\n%s\n' "\$\$" "\$(ps -o lstart= -p \$\$ | awk '{\$1=\$1;print}')" 1 > "\$REC"
export KAIZERO_SESSION_RECORD="\$REC" KAIZERO_SESSION_EPOCH=1 KAIZERO_TASK_ID_PATTERN=.
twt=\$("$ZERO26" claim WID); rc=\$?
echo "\$rc" > "$T26/exit3.out"
DRIVE3
bash "$T26/drive3.sh"
# want 0 — nothing left wedged
check "T26 reclaim exit" "$(cat "$T26/exit3.out")" "0"
# T26 PASS — the second claim WID (write blocked) exits 1 and prints no path on stdout; a third
# claim WID, once the write can succeed again, exits 0 — the failed write never left a claim
# wedged in place.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
