#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=85s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# T-008-zero-sh-from-either-root — every zero.sh verb answers identically from the
# coordination root, from the target root, and under an inherited git environment variable aimed
# at the target.
# Needs real claude: no — a disposable driver process writes its own KAIZERO_SESSION_RECORD
# for the claim/merge case; every other case calls zero.sh directly
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/T-008-zero-sh-from-either-root
# Wall-clock budget: its longest Run command is `timeout 20` — allow that command at least 20s
#
# This scenario's own proof: the emitted zero.sh is baked for one coordination repository, so
# neither the caller's cwd nor an inherited GIT_DIR/GIT_COMMON_DIR/GIT_WORK_TREE/GIT_INDEX_FILE
# misdirects a call. Two fixture repositories, code (target) and plan (coordination, holds the
# todo) — SAME_REPO=0, the case that exposed the bug (with one repository, -C and cwd always
# agreed).

# Setup
TT="$TESTROOT/T-008-zero-sh-from-either-root"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktodo(){ ( cd "$1"; echo '- [ ] G7 noop' > todo.md; git add todo.md; git commit -qm todo ); }
emit(){ ( cd "$1"; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$2" 2>&1 ); }

mkrepo "$TT/code"; mkrepo "$TT/plan"; mktodo "$TT/plan"
emit "$TT/code" "$TT/plan/todo.md" >/dev/null
ZS="$TT/plan/.git/zero.sh"

# zs <root> <verb...> -> that verb's stdout, run with cwd $root, no inherited git env.
zs(){ local root=$1; shift; ( cd "$root" && bash "$ZS" "$@" ); }
# zs_env <root> <VAR> <value> <verb...> -> same, with one git env var exported first.
zs_env(){ local root=$1 var=$2 val=$3; shift 3; ( cd "$root" && export "$var=$val" && bash "$ZS" "$@" ); }

# closed PATH with every prerequisite EXCEPT flock — proves the emitted script no longer
# discovers its locking tool off this PATH (baked at emission time instead).
NOFLOCK="$TT/noflock"; mkdir -p "$NOFLOCK"
for t in git timeout bash sh cat mv rm mkdir sed awk grep chmod ls cut tr head tail sort wc \
         printf true false date find stat ps uuidgen dirname ln basename readlink pwd sleep kill od; do
  p=$(type -P "$t") || { echo "REFUSING: '$t' not found — cannot build $NOFLOCK" >&2; exit 1; }
  ln -sf "$p" "$NOFLOCK/$t"
done

# T25 — read-only verbs answer identically from either root, and under each inherited git env var
( cd "$TT/plan"; sed -i.bak 's/\[ \] G7/[x] G7/' todo.md; rm -f todo.md.bak; git add todo.md; git commit -qm "done" )

base=$(zs "$TT/plan" "done" G7; echo "rc=$?")
tgt=$(zs "$TT/code" "done" G7; echo "rc=$?")
check "T25 done: coord == target" "$([ "$base" = "$tgt" ] && echo yes || echo "no ($base / $tgt)")" "yes"
for var in GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE; do
  val="$TT/code/.git"; [ "$var" = GIT_WORK_TREE ] && val="$TT/code"; [ "$var" = GIT_INDEX_FILE ] && val="$TT/code/.git/index"
  under=$(zs_env "$TT/code" "$var" "$val" "done" G7; echo "rc=$?")
  check "T25 done under $var aimed at target" "$([ "$under" = "$tgt" ] && echo yes || echo "no ($under)")" "yes"
done

sig_base=$(zs "$TT/plan" no-claim-signature)
sig_tgt=$(zs "$TT/code" no-claim-signature)
check "T25 no-claim-signature: coord == target" "$([ "$sig_base" = "$sig_tgt" ] && echo yes || echo no)" "yes"
check "T25 no-claim-signature carries a real sha" "$(printf '%s' "$sig_base" | awk '{print (length($1)==40) ? "yes" : "no"}')" "yes"
for var in GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE; do
  val="$TT/code/.git"; [ "$var" = GIT_WORK_TREE ] && val="$TT/code"; [ "$var" = GIT_INDEX_FILE ] && val="$TT/code/.git/index"
  under=$(zs_env "$TT/code" "$var" "$val" no-claim-signature)
  check "T25 no-claim-signature under $var" "$([ "$under" = "$sig_tgt" ] && echo yes || echo no)" "yes"
done

vid_base=$(zs "$TT/plan" validate-ids; echo "rc=$?")
vid_tgt=$(zs "$TT/code" validate-ids; echo "rc=$?")
check "T25 validate-ids: coord == target" "$([ "$vid_base" = "$vid_tgt" ] && echo yes || echo no)" "yes"
check "T25 validate-ids clean" "$([ "$vid_base" = "rc=0" ] && echo yes || echo no)" "yes"

tb_base=$(zs "$TT/plan" target-branch G7 'a title')
tb_tgt=$(zs "$TT/code" target-branch G7 'a title')
check "T25 target-branch: coord == target" "$([ "$tb_base" = "$tb_tgt" ] && echo yes || echo no)" "yes"

sym_base=$(zs "$TT/plan" box-symbol-on-base G7)
sym_tgt=$(zs "$TT/code" box-symbol-on-base G7)
# want yes, both 'x'
check "T25 box-symbol-on-base: coord == target" "$([ "$sym_base" = "$sym_tgt" ] && echo yes || echo no)" "yes"

( cd "$TT/code"; git branch G7-a-title-branch )
tbi_base=$(zs "$TT/plan" target-branches-for-id G7)
tbi_tgt=$(zs "$TT/code" target-branches-for-id G7)
# want yes, both name G7-a-title-branch
check "T25 target-branches-for-id: coord == target" "$([ "$tbi_base" = "$tbi_tgt" ] && echo yes || echo no)" "yes"

( cd "$TT/plan"; printf -- '- [ ] G9 fresh unchecked\n' >> todo.md; git add todo.md; git commit -qm addG9 )
tl_base=$(zs "$TT/plan" todo-list)
tl_tgt=$(zs "$TT/code" todo-list)
check "T25 todo-list: coord == target" "$([ "$tl_base" = "$tl_tgt" ] && echo yes || echo no)" "yes"
check "T25 todo-list finds the unchecked task" "$(printf '%s\n' "$tl_base" | grep -c 'G9 fresh unchecked')" "1"
# T25 PASS — done, no-claim-signature, validate-ids, target-branch and
# box-symbol-on-base all answer byte-identically from the coordination root, the target root,
# and under each of the four inherited git environment variables aimed at the target; at HEAD the
# GIT_DIR- and GIT_COMMON_DIR-inheriting calls answered differently (an empty
# no-claim-signature sha, done reporting 1 for a ticked box).

# T26 — locking tool absent from PATH: claim and merge still complete, under MERGE_LOCK
( cd "$TT/plan"; printf -- '- [ ] G8 noop\n' >> todo.md
  mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/G8.md
  git add -A; git commit -qm addtask )

# claim and merge below must share ONE session identity — own_run's disposable script would give
# each its own pid, and merge_task refuses a .owner recorded pid that doesn't match its own
# caller's (exit 6, "not your task") — own_session here, once, is inherited by both subshells.
own_session "$TT/t26-session"
claim_out=$( ( cd "$TT/plan" && bash "$ZS" claim G8 ) 2>&1); claim_rc=$?
wt_path=$(printf '%s\n' "$claim_out" | tail -1)
check "T26 claim under a flock-less PATH succeeds" "$([ "$claim_rc" -eq 0 ] && [ -d "$wt_path" ] && echo yes || echo no)" "yes"

( cd "$wt_path"; echo work > g8.txt; git add g8.txt; git commit -qm 'did G8' )
merge_out=$( ( cd "$TT/code" && PATH="$NOFLOCK" bash "$ZS" merge G8 "$wt_path" ) 2>&1 ); merge_rc=$?
check "T26 merge under a flock-less PATH succeeds" "$([ "$merge_rc" -eq 0 ] && echo yes || echo no)" "yes"
check "T26 merge reports the cleaned line" "$(printf '%s\n' "$merge_out" | grep -c 'worktrees + branches cleaned')" "1"
check "T26 no leftover coordination worktree" "$(git -C "$TT/plan" worktree list | grep -c task-G8)" "0"
check "T26 no leftover coordination branch" "$(git -C "$TT/plan" branch --list 'main-task-G8' | wc -l | tr -d ' ')" "0"
check "T26 box landed \`[x]\` on the coordination base" "$(git -C "$TT/plan" show main:todo.md | grep -c '\[x\] G8 noop')" "1"
# T26 PASS — the emitted script bakes its locking tool's resolved path at emission time
# (when the launcher's own doctor already proved it present), so a fleet whose agent Bash-tool
# PATH lacks flock still serializes claim/merge correctly; at HEAD both verbs would fail
# with "flock: command not found".

# T27 — absence checks: the coordination git dir is baked, never re-derived, and the caller's git environment is cleared
lo=$(grep -n "^# --- forge" "$SCRIPT" | cut -d: -f1)
check "T27 COORD_GITDIR baked, not derived" "$(grep -c 'COORD_GITDIR="\$(' "$ZS")" "0"
check "T27 no rev-parse --git-common-dir in zero.sh" "$(grep -c 'rev-parse --git-common-dir' "$ZS")" "0"
check "T27 ambient git env cleared before first git call" "$(grep -c '^unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE' "$ZS")" "1"
check "T27 FLOCK_BIN baked absolute" "$(awk -F= '/^FLOCK_BIN=/{print ($2 ~ /^\//) ? "yes" : "no"}' "$ZS")" "yes"
check "T27 no bare 'cd' anywhere in zero.sh" "$(grep -cE '(^|[^_[:alnum:]])cd([[:space:]]|$)' "$ZS")" "0"
check "T27 the forge scratch-checkout helper is gone" "$(grep -c 'ensure_forge_cwd' "$ZS")" "0"
check "T27 mr_list/mr_create name --repo" "$(grep -E '^\s+(if )?(out=|out="\$\()' "$ZS" | grep -c -- '--repo "\$ORIGIN_URL"')" "4"
# T27 PASS — COORD_GITDIR and FLOCK_BIN are baked assignments only, the emitted script
# contains no cd at all and no residual forge scratch-checkout helper, and both forge calls
# name the repository explicitly rather than resolving it from that checkout's cwd.

# T28 — a non-ASCII task id sanitizes to the same slug under LC_ALL=C and under LC_ALL=en_US.UTF-8
mkrepo "$TT/uni"
( cd "$TT/uni"; printf -- '- [ ] SMTH-\xc3\xa91 noop\n' > todo.md; git add todo.md; git commit -qm todo )
( cd "$TT/uni" && KAIZERO_TASK_ID_PATTERN=. KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge todo.md >/dev/null 2>&1 )
ZU="$TT/uni/.git/zero.sh"
ln=$(grep -nF 'case "${1:-}" in' "$ZU" | head -1 | cut -d: -f1)
tmp="$(mktemp)"; head -n "$((ln - 1))" "$ZU" > "$tmp"
slug_c=$(LC_ALL=C bash -c '. "'"$tmp"'"; sanitize_id "SMTH-é1"')
slug_utf8=$(LC_ALL=en_US.UTF-8 bash -c '. "'"$tmp"'"; sanitize_id "SMTH-é1"')
rm -f "$tmp"
check "T28 sanitize_id byte-identical across locales" "$([ "$slug_c" = "$slug_utf8" ] && echo yes || echo "no ($slug_c / $slug_utf8)")" "yes"
# T28 PASS — sanitize_id forces LC_ALL=C on its own tr calls, so a non-ASCII id maps to
# the same branch/worktree slug regardless of the launching environment's locale; at HEAD the two
# locales produced different slugs (SMTH---1 vs SMTH--1), so two peers on one coordination
# point launched under different locales would each fork a different branch for the same claim.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
