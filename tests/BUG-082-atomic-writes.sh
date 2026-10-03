#!/usr/bin/env bash
# KAIZERO_TEST_ISOLATED=1
# KAIZERO_WALLCLOCK_BUDGET=240s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# BUG-082-atomic-writes — every file other processes execute or read is replaced whole (temp file
# + one `mv -f`), never rewritten in place: readers racing the rewrites see no prefix, no empty file.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/BUG-082-atomic-writes
# Wall-clock budget: a few minutes (readers race tight rewrite loops)
# Race note: the reader/writer loops below run in this scenario's own background jobs, so CPU
# contention from concurrent scenarios skews them — hence the isolated bucket.

TR="$TESTROOT/BUG-082-atomic-writes"; mkdir -p "$TR/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TR/bin/claude"; chmod +x "$TR/bin/claude"

# M1 — a launcher start emits the helpers through atomic_put, executable, no temp left behind
d="$TR/repo"; mkdir -p "$d/tasks"; cd "$d"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf -- '- [ ] TASK-1 x\n' > todo.md; printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/TASK-1.md
git add -A; git commit -qm init
KAIZERO_TEST_EMIT=1 PATH="$TR/bin:$PATH" bash "$SCRIPT" --local-merge todo.md -t x > "$TR/launch.out" 2>&1
G="$d/.git"
for f in zero.sh terminator.sh compact-exit-hook.sh hooks/prepare-commit-msg; do
  check "M1 $f emitted and executable" "$([ -x "$G/$f" ] && echo yes)" "yes"
  check "M1 $f parses" "$(bash -n "$G/$f" 2>&1 | wc -l | tr -d ' ')" "0"
done
check "M1 startup line unchanged" "$(grep -c "Wrote $G/zero.sh (base " "$TR/launch.out")" "1"
check "M1 no temp file left in the git dir or hooks" "$(ls "$G" "$G/hooks" | grep -c '\.tmp$')" "0"
check "M1 atomic_put is emitted into zero.sh, terminator.sh and the Stop hook" "$(grep -l '^atomic_put ()' "$G/zero.sh" "$G/terminator.sh" "$G/compact-exit-hook.sh" | wc -l | tr -d ' ')" "3"

# M2 — absence: no redirection opens the final path of an executable or a record for truncating
K="$REPO/kaizero.sh"
check "M2 no write onto the helper paths" "$(grep -cE '> *"\$gitdir/(zero|terminator)\.sh"|>>? *"\$STOP_HOOK"|> *"\$hook"' "$K")" "0"
check "M2 no write onto a record's final path" "$(grep -cE '(^|[^>])> *"((\$wt|\$1)/\.owner|\$INFLIGHT_FILE|\$SESSION_RECORD_FILE|\$EXIT_REASON_FILE|\$SAFE_TO_EXIT_FILE|\$mf|\$\(marker|\$\(safe_to_exit_file\)|\$(INSTANCE_DIR|dir)/\$INSTANCE_ID)' "$K")" "0"
check "M2 the no-op comment is gone" "$(grep -c 'racing last-writer-wins is a no-op' "$K")" "0"

# M3 — atomic_put against 4 readers: 300 rewrites of a 3,300-line script ending in a case statement
AP="$TR/atomic_put.sh"; sed -n '/^atomic_put() {/,/^}/p' "$K" > "$AP"
check "M3 atomic_put extracted" "$([ -s "$AP" ] && echo yes)" "yes"
. "$AP"
mkscript(){ { echo '#!/usr/bin/env bash'; echo 'set -e'; for i in $(seq 1 3300); do echo ": line$i"; done
              echo 'case "${1:-}" in ok) exit 0;; *) exit 1;; esac'; }; }
mkdir -p "$TR/m3"; Z="$TR/m3/zero.sh"; mkscript | atomic_put "$Z" "" +x
rm -f "$TR/m3/fail."*
( for i in $(seq 1 300); do mkscript | atomic_put "$Z" "" +x; done; touch "$TR/m3/done" ) & WP=$!
for r in 1 2 3 4; do
  ( n=0; bad=0; while [ ! -e "$TR/m3/done" ] && [ "$n" -lt 400 ]; do "$Z" ok >/dev/null 2>&1 || bad=$((bad+1)); n=$((n+1)); done; echo "$bad" > "$TR/m3/fail.$r" ) &
done
wait
check "M3 no reader ran a prefix or lacked the exec bit" "$(cat "$TR"/m3/fail.* | tr '\n' ' ')" "0 0 0 0 "

# M4 — inode changes per rewrite; temp is complete and has final mode at the moment of mv
mkdir -p "$TR/m4/bin"; cd "$TR/m4"
printf 'old\n' > f; i1=$(ls -i f | awk '{print $1}')
printf 'new complete\n' | atomic_put "$TR/m4/f" "" +x
i2=$(ls -i f | awk '{print $1}')
check "M4 final path has a new inode" "$([ "$i1" != "$i2" ] && echo yes)" "yes"
cat > "$TR/m4/bin/mv" <<EOF
#!/usr/bin/env bash
src=\${@: -2:1}
printf '%s|%s|%s\n' "\$(cat "\$src")" "\$([ -x "\$src" ] && echo x)" "\${src##*.}" >> "$TR/m4/mv.log"
exec /bin/mv "\$@"
EOF
chmod +x "$TR/m4/bin/mv"
PATH="$TR/m4/bin:$PATH" bash -c ". '$AP'; printf 'whole\n' | atomic_put '$TR/m4/g' '' +x"
check "M4 mv sees complete content, exec bit, .tmp name" "$(cat "$TR/m4/mv.log")" "whole|x|tmp"
check "M4 no temp left after success" "$(ls "$TR/m4" | grep -c '\.tmp$')" "0"

# M5 — failed write: previous file untouched, no temp left, nonzero status
mkdir -p "$TR/m5"; printf 'keep\n' > "$TR/m5/f"
( printf 'x\n' | atomic_put "$TR/m5/f" "$TR/m5/nodir/f" ) >/dev/null 2>&1; rc=$?
check "M5 failed write returns nonzero" "$([ "$rc" != 0 ] && echo yes)" "yes"
check "M5 previous content intact" "$(cat "$TR/m5/f")" "keep"
check "M5 no temp left after failure" "$(find "$TR/m5" -name '*.tmp' | wc -l | tr -d ' ')" "0"

# M6 — a temp left by a dead writer is removed by the next write; a live writer's temp is kept
mkdir -p "$TR/m6"; : > "$TR/m6/f.999999.tmp"; sleep 300 & LP=$!; : > "$TR/m6/f.$LP.tmp"
printf 'x\n' | atomic_put "$TR/m6/f"
check "M6 dead writer's temp removed" "$([ -e "$TR/m6/f.999999.tmp" ] && echo left || echo gone)" "gone"
check "M6 live writer's temp kept" "$([ -e "$TR/m6/f.$LP.tmp" ] && echo kept || echo gone)" "kept"
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null

# M7 — records: 4,000 rewrites, two readers doing acquire_task's read never see an empty record
mkdir -p "$TR/m7"; O="$TR/m7/.owner"; printf '1\n2\n3\n4\n5\n6\n' | atomic_put "$O" "$TR/m7.owner"
rm -f "$TR/m7/done" "$TR/m7/e."*
( for i in $(seq 1 4000); do printf '%s\n2\n3\n4\n5\n6\n' "$i" | atomic_put "$O" "$TR/m7.owner"; done; touch "$TR/m7/done" ) & WP=$!
for r in 1 2; do
  ( e=0; while [ ! -e "$TR/m7/done" ]; do pid=""; { read -r pid; } < "$O" 2>/dev/null; [ -n "$pid" ] || e=$((e+1)); done; echo "$e" > "$TR/m7/e.$r" ) &
done
wait
check "M7 readers never see an empty record" "$(cat "$TR"/m7/e.* | tr '\n' ' ')" "0 0 "
check "M7 temp sits outside the record's directory" "$(ls -A "$TR/m7" | grep -c 'tmp')" "0"

# M8 — the startup sweep removes a record's temp together with its base file
check "M8 sweep removes the sidecar temp" "$(grep -c 'rm -f "\$f" "\$f.lock" "\$f.tmp" "\$f"\.\*\.tmp' "$K")" "1"

cd "$TESTROOT"
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
