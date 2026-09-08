#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=135s
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# O-001-link-into-task-worktrees — KAIZERO_LINK into task worktrees. Symlinks a gitignored
# directory into a task worktree, write-through, invisible to git via info/exclude, validated at
# startup before any claude launch.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/O-001-link-into-task-worktrees
#
# A worktree checks out tracked files only, so a gitignored spec directory a todo line points at
# is absent there and the session works from the title alone. KAIZERO_LINK symlinks it in.
# The link must be readable, must write through to the real file, and must stay invisible to git
# — a name/ ignore pattern matches a directory, not a symlink to one, so without an info/exclude
# entry the link rides along in the session's git add -A. Like Scenario I, claim needs a valid
# KAIZERO_SESSION_RECORD, so the driver writes one for itself before calling zero.sh.

# Setup
TO="$TESTROOT/O-001-link-into-task-worktrees"; mkdir -p "$TO/repo" "$TO/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TO/bin/claude"; chmod +x "$TO/bin/claude"
# real, fetchable, no-host bare origin for O5's two-repository MR layout (same shape as
# V-001-mr-mode-fresh-fetch's mkorigin). $1 = target dir.
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1"; git config user.email t@t.t; git config user.name test )
}
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
# O5's bootstrap: writes zero.sh into the coordination repo's git dir; never starts claude for
# real. KAIZERO_FORGE=gh: these fixtures' origin is a local bare path with no host.
boot(){ ( cd "$1"; PATH="$TO/bin:$PATH" KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$2" >/dev/null 2>&1 ); true; }
cd "$TO/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
printf 'tasks/\nsources/\n' > .gitignore
printf -- '- [ ] O1 a\n- [ ] O2 b\n- [ ] O3 c\n- [ ] O4 d\n- [ ] O8 read-vs-tick\n' > todo.md
git add -A; git commit -qm init
mkdir tasks sources
printf -- '- [ ] criterion one\n' > tasks/spec-O.md      # the spec the todo line points at
printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/O8.md   # resolvable by id, for O8 below
printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/O1.md   # resolvable by id, claim needs one
printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/O2.md   # resolvable by id, claim needs one
printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/O4.md   # resolvable by id, claim needs one
printf 'private\n' > sources/s.txt                         # gitignored, NOT listed in KAIZERO_LINK
PATH="$TO/bin:$PATH" timeout 30 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TO/boot.log" 2>&1 || true
# BUG 057: ensure_owner now reads KAIZERO_SESSION_RECORD, never a claude-named ancestor — the
# driver below writes its own record, naming itself, before its first zero.sh call.
cat > "$TO/drive.sh" <<'DRIVE'
REC="$0.rec"
printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
set -uo pipefail
cd "$TO/repo"
ZERO="$(cd "$(git rev-parse --git-dir)" && pwd)/zero.sh"
FAILED=0; ERRORED=0

# O1 — listed name is linked, readable, and write-through; unlisted name is not linked
wt=$(KAIZERO_LINK=tasks "$ZERO" claim O1)
# linked, not copied
check "O1 is symlink" "$([ -L "$wt/tasks" ] && echo yes || echo NO)" "yes"
check "O1 readable" "$(cat "$wt/tasks/spec-O.md" 2>/dev/null)" "- [ ] criterion one"
sed -i'' -e 's/- \[ \]/- [x]/' "$wt/tasks/spec-O.md"
# no commit, no merge
check "O1 write-through" "$(cat "$TO/repo/tasks/spec-O.md")" "- [x] criterion one"
# the exclude covers the symlink
check "O1 status empty" "$([ -z "$(git -C "$wt" status --short)" ] && echo yes || echo NO)" "yes"
git -C "$wt" add -A
# the link never reaches a commit
check "O1 add -A stages" "$(git -C "$wt" status --short | grep -c 'tasks')" "0"
# only listed names are linked
check "O1 unlisted absent" "$([ -e "$wt/sources" ] && echo NO || echo yes)" "yes"
# info/exclude is the COMMON dir's, shared by every worktree
check "O1 exclude entry" "$(grep -c '^/tasks$' "$(git -C "$wt" rev-parse --git-path info/exclude)")" "1"
"$ZERO" release O1 >/dev/null 2>&1   # one task per session: free the slot before O2's own claim
# O1 PASS — is symlink, readable, write-through, status empty, add -A stages, unlisted absent
# and exclude entry all report their want value.

# O2 — unset variable links nothing at all
wt2=$("$ZERO" claim O2)
# default is off
check "O2 no link" "$([ -e "$wt2/tasks" ] && echo NO || echo yes)" "yes"
"$ZERO" release O2 >/dev/null 2>&1   # one task per session: free the slot before O4's own claim
# O2 PASS — no link reports its want value.

# O3 — link_ignored itself no longer re-checks the list: a bad entry cannot reach it, because
# startup refused the run (see O6). Its only remaining guard is the occupied-name test.
# validation lives at startup, once
check "O3 guards" "$(sed -n '/^link_ignored() {/,/^}/p' "$ZERO" | grep -c '\-e "\$root/\$p"\|case "\$p" in')" "0"
# O3 PASS — guards reports its want value: validation lives at startup, once.

# O4 — a second claim appends no duplicate exclude entry and leaves the link alone
wt4=$(KAIZERO_LINK=tasks "$ZERO" claim O4)
EX4="$(git -C "$wt4" rev-parse --git-path info/exclude)"
KAIZERO_LINK=tasks "$ZERO" claim O4 >/dev/null 2>&1 || true
# claiming twice appends once
check "O4 exclude dupes" "$(grep -c '^/tasks$' "$EX4")" "1"
check "O4 link intact" "$([ -L "$wt4/tasks" ] && echo yes || echo NO)" "yes"
# the -L half of the guard, called directly — a second `claim` of a task this session already
# holds returns 1 before ever reaching link_ignored (see I2), so it cannot exercise this. A
# DANGLING link is -L true but -e false: without the -L test the ln -s dies "File exists" on BSD
# and GNU alike, and set -e inside acquire_task takes the whole claim down with it.
sed -n '/^link_ignored() {/,/^}/p' "$ZERO" > "$TO/li.sh"
rm -f "$wt4/tasks"; ln -s "$TO/gone" "$wt4/tasks"
( set -euo pipefail; . "$TO/li.sh"; KAIZERO_LINK=tasks link_ignored "$wt4" ); rc=$?
# the -L guard skips the name instead of failing on ln -s
check "O4 dangling exit" "$rc" "0"
check "O4 dangling kept" "$([ -L "$wt4/tasks" ] && [ ! -e "$wt4/tasks" ] && echo yes || echo NO)" "yes"
# O4 PASS — exclude dupes, link intact, dangling exit and dangling kept all report their want value.

# O8 — todo-list's appended Task-file path is read-only and COORD_ROOT-absolute: readable with no
# KAIZERO_LINK and no $wt at all; ticking it is a separate operation, still gated on
# KAIZERO_LINK exactly as O2 above already proves.
o8line=$("$ZERO" todo-list | grep '^- \[ \] O8 ')
o8path=$(printf '%s' "$o8line" | awk '{print $NF}')
# COORD_ROOT-absolute, no $wt needed
check "O8 path absolute" "$([ "$o8path" = "$TO/repo/tasks/O8.md" ] && echo yes || echo NO)" "yes"
# read directly, KAIZERO_LINK unset in this shell
check "O8 readable no link" "$(cat "$o8path" 2>/dev/null | head -1)" "### Acceptance criteria"

[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE

# O1 — listed name is linked, readable, and write-through; unlisted name is not linked
# drive.sh writes its own BUG 057 session record naming itself before its first zero.sh call.
# This one invocation runs the whole drive.sh — O2 through O4 below read back what it already
# printed, not a second run.
# shellcheck disable=SC2097,SC2098
TO="$TO" bash "$TO/drive.sh"
DRC=$?
[ "$DRC" = 0 ] || FAILED=1

# O2/O3/O4/O8 — checked inside drive.sh, above

# O5 — characterization: the two-repository MR layout links nothing at all, and the target repository's own exclude file and config are left untouched
mkorigin "$TO/o5code"; mkrepo "$TO/o5plan"
( cd "$TO/o5plan"; printf 'tasks/\n' > .gitignore
  printf -- '- [ ] O5 task\n' > todo.md; git add -A; git commit -qm init
  mkdir tasks; printf -- '- [ ] c\n' > tasks/spec-O5.md
  printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/O5.md )   # resolvable by id, claim needs one
boot "$TO/o5code" "$TO/o5plan/todo.md"
EXCLUDE5="$(cd "$TO/o5code" && git rev-parse --git-path info/exclude | sed "s#^#$TO/o5code/#")"
cp "$EXCLUDE5" "$TO/o5-exclude-pre"

cat > "$TO/o5drive.sh" <<'DRIVE'
set -uo pipefail
cd "$TO/o5plan"
REC="$TO/o5-session"; printf '%s\n%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')" 1 > "$REC"
export KAIZERO_SESSION_RECORD="$REC" KAIZERO_SESSION_EPOCH=1
FAILED=0; ERRORED=0
wt=$(KAIZERO_LINK=tasks bash .git/zero.sh claim O5); rc=$?
check "O5 claim exit" "$rc" "0"
check "O5 no link -e" "$([ -e "$wt/tasks" ] && echo NO || echo yes)" "yes"
check "O5 no link -L" "$([ -L "$wt/tasks" ] && echo NO || echo yes)" "yes"
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ]
DRIVE
# shellcheck disable=SC2097,SC2098
TO="$TO" bash "$TO/o5drive.sh"
DRC5=$?
[ "$DRC5" = 0 ] || FAILED=1
check "O5 exclude untouched" "$(cmp -s "$EXCLUDE5" "$TO/o5-exclude-pre" && echo yes || echo NO)" "yes"
check "O5 no worktreeConfig ext" "$(git -C "$TO/o5code" config --get extensions.worktreeConfig >/dev/null 2>&1 && echo NO || echo yes)" "yes"
check "O5 no core.excludesFile" "$(git -C "$TO/o5code" config --local --get core.excludesFile >/dev/null 2>&1 && echo NO || echo yes)" "yes"
# O5 PASS — the claim completes with KAIZERO_LINK=tasks set, the task worktree carries no
# tasks entry at all (neither -e nor -L), $TO/o5code's own info/exclude is byte-identical to its
# pre-claim copy, and no ignore-scoping git config was written there.

# O6 — a bad KAIZERO_LINK refuses the run at startup, before any claude
cd "$TO/repo"
export STUB_LAUNCHED="$TO/launched"; : > "$STUB_LAUNCHED"
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "$STUB_LAUNCHED"\nexit 0\n' > "$TO/bin/cz-stub"; chmod +x "$TO/bin/cz-stub"
mkdir -p "$TO/stub"; cp "$TO/bin/cz-stub" "$TO/stub/claude"
run_bad(){ PATH="$TO/stub:$PATH" KAIZERO_LINK="$1" timeout 30 env KAIZERO_MAX_LOOPS=1 \
  bash "$SCRIPT" --local-merge todo.md -t x > "$TO/bad-$2.log" 2>&1; echo $?; }
check "O6 missing exit" "$(run_bad 'nosuchdir' missing)" "1"
check "O6 missing names it" "$(grep -c "KAIZERO_LINK entry 'nosuchdir' does not exist at" "$TO/bad-missing.log")" "1"
check "O6 nested exit" "$(run_bad 'tasks/nested' nested)" "1"
check "O6 nested names it" "$(grep -c "KAIZERO_LINK entry 'tasks/nested' is not a top-level name" "$TO/bad-nested.log")" "1"
# a good entry does not excuse a bad one
check "O6 one bad kills" "$(run_bad 'tasks,nosuchdir' mixed)" "1"
# refused before the first session, so no tokens
check "O6 no launches" "$(wc -l < "$STUB_LAUNCHED" | tr -d ' ')" "0"
# O6 PASS — missing exit = 1, nested exit = 1, one bad kills = 1, each with its naming line = 1,
# and no launches = 0.

# O7 — --help names the variable, so it is discoverable without the README
H="$(bash "$SCRIPT" -h)"
check "O7 env block" "$(printf '%s' "$H" | grep -c 'Environment (all variables are in README.md):')" "1"
# the comma-separated form
check "O7 names the var" "$(printf '%s' "$H" | grep -c 'KAIZERO_LINK=name\[,name')" "1"
check "O7 says default" "$(printf '%s' "$H" | grep -c 'into every Task worktree. Unset by default')" "1"
# O7 PASS — all three = 1.

# O9 — two-repo mode: the appended path is $COORD_ROOT-absolute, not $TARGET_ROOT-relative
mkrepo9(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mkrepo9 "$TO/code9"; mkrepo9 "$TO/plan9"
( cd "$TO/plan9"; printf -- '- [ ] O9 x\n' > todo.md; mkdir tasks
  printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/O9.md; git add -A; git commit -qm todo )
( cd "$TO/code9"; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$TO/plan9/todo.md" >/dev/null 2>&1 )
ZERO9="$TO/plan9/.git/zero.sh"
o9line=$(cd "$TO/code9" && "$ZERO9" todo-list | grep '^- \[ \] O9 ')
o9path=$(printf '%s' "$o9line" | awk '{print $NF}')
plan9_p="$(cd "$TO/plan9" && pwd -P)"
# COORD_ROOT=plan9, launched from TARGET_ROOT=code9, cwd is neither; $TO itself may sit behind a
# symlinked tmp mount, so compare against plan9's own physical path
check "O9 path is COORD_ROOT" "$([ "$o9path" = "$plan9_p/tasks/O9.md" ] && echo yes || echo NO)" "yes"
# O9 PASS — path is COORD_ROOT = yes.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
