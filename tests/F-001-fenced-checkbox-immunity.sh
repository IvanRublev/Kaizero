#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=122s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCENARIO_DIR/test-setup.sh"

# F-001-fenced-checkbox-immunity — fenced-checkbox immunity. A `- [ ]`/`- [x]` box inside a
# fenced code block is prose, not a task — proven for all_todos_done/dojo_proud, for
# `zero.sh done`/box_checked_on_base, and for `zero.sh merge`'s own tick.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/F-001-fenced-checkbox-immunity
# Wall-clock budget: its longest Run command is `timeout 30` — allow that command at least 30s
#
# Checkbox scans (all_todos_done, `zero.sh done`/box_checked_on_base, the merge guard) must
# judge task state only — a `- [ ]`/`- [x]` inside a fenced ``` code block is prose (an example
# issue in spec.md), not a task. Before the fix, one unchecked example box in a fence made
# all_todos_done return false forever, so dojo_proud never fired even with every real task done;
# a checked example box could also mis-report a task as landed. No real claude needed — a stub
# bootstraps zero.sh, then we drive the two checks directly.

TF="$TESTROOT/F-001-fenced-checkbox-immunity"; mkdir -p "$TF/repo" "$TF/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TF/bin/claude"; chmod +x "$TF/bin/claude"
cd "$TF/repo"
git init -q -b main; git config user.email t@t.t; git config user.name test
# todo with a FENCED example block (unchecked + checked example boxes) and real tasks all done
cat > todo.md <<'EOF'
# tasks

Example issue (prose, must be ignored):
```markdown
- [ ] EX example unchecked box
- [x] EXDONE example checked box
```

- [x] 1. real task done
- [x] 2. real task done
EOF
git add -A; git commit -qm init
PATH="$TF/bin:$PATH" timeout 30 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TF/boot.log" 2>&1 || true
ZERO="$(cd "$(git rev-parse --git-dir)" && pwd)/zero.sh"
check "F0 zero.sh built" "$([ -x "$ZERO" ] && echo yes || echo NO)" "yes"

# F1 — all_todos_done ignores fenced boxes → dojo_proud fires
cd "$TF/repo"
# every REAL task is [x]; the only [ ] is the fenced example. Fixed script → all-done → dojo_proud.
check "F1 dojo_proud" "$(grep -c 'surveys the frozen field' "$TF/boot.log")" "1"
# F1 PASS — dojo_proud = 1: the fenced - [ ] EX box did not block the all-done signal.

# F2 — zero.sh done ignores fenced boxes (box_checked_on_base)
cd "$TF/repo"
"$ZERO" "done" 1.
check "F2 real done id" "$?" "0"
"$ZERO" "done" EXDONE
check "F2 fenced [x] id" "$?" "1"
"$ZERO" "done" EX
check "F2 fenced [ ] id" "$?" "1"
# F2 PASS — real done id = 0, both fenced ids = 1: a checked example box never reports a task as
# landed.

# F3 — zero.sh merge's tick never flips a fenced box, even on an id collision
cd "$TF/repo"
cat > todo.md <<'EOF'
# tasks

Example issue (prose, must be ignored):
```markdown
- [ ] 3. decoy example box sharing the real task's id
- [x] EXDONE example checked box
```

- [x] 1. real task done
- [x] 2. real task done
- [ ] 3. real task pending
EOF
mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/3.md
git add -A; git commit -qm "F3 fixture"
# BUG 057: ensure_owner needs a valid KAIZERO_SESSION_RECORD — this shell IS the process the
# record names, so every "$ZERO" call below inherits it.
own_session "$TF/f3-rec"
WT3=$("$ZERO" claim 3.)
git -C "$WT3" commit -q --allow-empty -m "3. work"
"$ZERO" merge 3. "$WT3"; check "F3 merge exit" "$?" "0"
check "F3 real ticked" "$(grep -c '^- \[x\] 3\. real task pending' todo.md)" "1"
check "F3 decoy intact" "$(grep -c '^- \[ \] 3\. decoy example box' todo.md)" "1"
# F3 PASS — merge exit = 0, real ticked = 1, decoy intact = 1: the fenced decoy sharing the real
# task's id is never flipped, only the real line is.

# F5 — zero.sh merge and no-claim-mark mark the running instance safe to exit
cd "$TF/repo"
GC="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
SAFE="$GC/safe-to-exit-main-shared"   # INSTANCE_ID defaults to "shared" when KAIZERO_INSTANCE is unset
cat > todo.md <<'EOF'
- [ ] F5 x
EOF
mkdir -p tasks; printf -- '### Acceptance criteria\n- [ ] x\n' > tasks/F5.md
git add -A; git commit -qm "F5 fixture"
rm -f "$SAFE"
# BUG 057: ensure_owner needs a valid KAIZERO_SESSION_RECORD — this shell IS the process the
# record names, so every "$ZERO" call below inherits it.
own_session "$TF/f5-rec"
WT5=$("$ZERO" claim F5)
git -C "$WT5" commit -q --allow-empty -m "F5 work"
"$ZERO" merge F5 "$WT5"; check "F5 merge exit" "$?" "0"
# a landed task marks the running instance safe to exit
check "F5 safe-to-exit set" "$([ -s "$SAFE" ] && echo yes || echo NO)" "yes"
rm -f "$SAFE"
"$ZERO" no-claim-mark
# a confirmed-empty board marks it too
check "F5 no-claim safe" "$([ -s "$SAFE" ] && echo yes || echo NO)" "yes"
rm -f "$SAFE" "$GC/no-claim-shared"

# a no-claim write that fails must NOT mark safe-to-exit — the marker's own comment says "nothing
# claimable is CONFIRMED"; a lost write confirmed nothing, so the Stop hook must not be told it's
# safe to end this instance's session.
chmod 555 "$GC"
"$ZERO" no-claim-mark 2>/dev/null || true
# a failed no-claim write must not mark safe-to-exit
check "F5 failed write safe" "$([ -s "$SAFE" ] && echo yes || echo NO)" "NO"
chmod 755 "$GC"
# F5 PASS — merge exit = 0, safe-to-exit set = yes, no-claim safe = yes, failed write safe = NO.

# F4 — a [?] box is landed everywhere a [x] box is, not "unchecked"
cd "$TF/repo"
cat > todo.md <<'EOF'
- [?] 4. landed, needs review
- [x] 5. real task done
EOF
git add -A; git commit -qm "F4 fixture"
check "F4 unchecked count" "$("$ZERO" unchecked-todos)" "0"
"$ZERO" "done" 4.
check "F4 is_done ? = 0" "$?" "0"
PATH="$TF/bin:$PATH" timeout 30 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TF/f4.log" 2>&1 || true
# all-[?]-or-[x] counts as all done
check "F4 dojo_proud" "$(grep -c 'surveys the frozen field' "$TF/f4.log")" "1"
# F4 PASS — unchecked count = 0, is_done ? = 0, dojo_proud = 1: a [?] box is treated as landed
# by unchecked_todos, is_done, and all_todos_done alike, never as still-to-do.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
