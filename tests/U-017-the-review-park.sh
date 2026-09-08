#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=310s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-017-the-review-park — parking on an open request, `KAIZERO_REVIEW_WAIT=0`, a box cleared
# mid-park, and nothing at `↑`.
# Needs real `claude`: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under `$TESTROOT`: `$TESTROOT/U-017-the-review-park`
# Wall-clock budget: its longest Run command is `timeout 30` — allow that command at least 30s
#
# `wait_for_reviews`/`wait_for_dependency_clear`'s MR-mode behaviours live in `kaizero.sh`'s
# own `run_loop`, not in the emitted `zero.sh` — `zero_funcs`/`KAIZERO_TEST_EMIT` can't reach
# them, so the cases below run the *real* doctor and the *real* restart loop: a real, fetchable,
# no-host bare origin (`mkorigin`) for the target, a plain `mkrepo` for the coordination repo, and
# a controllable stub `claude` rebuilt per case via `mkpath` (a snapshot copy, so each case's
# `$TU/bin/claude` must be written before its own `mkpath` call).
#
# The park itself: a run with nothing unchecked and a request open waits for reviewers
# instead of exiting, `0` never parks, a human clearing a box ends the park exactly as a merge
# does, and a todo with no `↑` box at all never enters it.

# Setup
TU="$TESTROOT/U-017-the-review-park"; mkdir -p "$TU/bin" "$TU/stub"
# MR mode is the default, so every fixture target needs an `origin` a forge resolves
# from or the launch refuses before the case's own subject is reached. A github URL, never fetched
# (TEST_EMIT skips the doctor; the real-doctor cases use `mkorigin` instead).
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git remote add origin "https://github.com/acme/$(basename "$1").git" ); }

# target repo cloned from a local bare origin — real, fetchable, no host. $1 = target dir.
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1"; git config user.email t@t.t; git config user.name test )
}

# stub claude: prints its argv (captured to see the banner precede it in the launch log) and exits.
printf '#!/usr/bin/env bash\nprintf "ARGV: %%s\\n" "$*"\nexit 0\n' > "$TU/bin/claude"; chmod +x "$TU/bin/claude"

# stub gh/glab: record argv+cwd, one failure marker per verb ($TU/stub/<prog>-<verb>) — and,
# for `auth status`, one PER HOSTNAME too ($TU/stub/<prog>-auth-status-<host>, host from
# --hostname, blank when the fixture's origin has none) — so a case can fail one host's login
# without touching another's. Exit 0 by default (auth status passes, matching what check 6 and
# the mid-run re-check both need).
# `list`/`create` gain two more per-verb files, read if present: `<prog>-<verb>.out`
# (cat'd to stdout before anything else — the canned JSON/URL a case wants mr_list/mr_create to
# reshape) and `<prog>-<verb>.rc` (its content, read as the exit code, instead of the marker
# logic below — so a case can return 0 with empty stdout, or non-zero with real stdout, neither
# of which the marker-only mechanism above can express).
#
# check 5 calls `<verb> --help` on the resolved forge and greps its output for each
# flag mr_list/mr_create pass — so `--help` answers with the real default flag list per
# prog+verb, unless `<prog>-<verb>-help.txt` exists, which is cat'd verbatim instead. It also
# probes `gh pr list --json` with no value (exactly `pr list --json`, no fourth arg) — the real
# CLI prints its field list on stderr and exits 1, so the stub does the same, from
# `gh-list-json.txt` if present else the real default field list.
for prog in gh glab; do
case "$prog" in
  gh)   listflags="--repo --head --state --limit --json"; createflags="--repo --head --base --title --body-file"
        authflags="--hostname" ;;
  glab) listflags="--repo --source-branch --all --output --per-page --order --sort"
        createflags="--repo --source-branch --target-branch --title --description --yes"
        authflags="--hostname" ;;
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
if [ "\$1 \${2:-}" = "pr list" ] && [ "\${3:-}" = "--json" ] && [ \$# -eq 3 ]; then
  jsonfile="$TU/stub/gh-list-json.txt"
  if [ -f "\$jsonfile" ]; then cat "\$jsonfile" >&2; else printf '%s\n' 'number headRefOid baseRefName state url' >&2; fi
  exit 1
fi
if [ "\$is_help" = 1 ] && [ -n "\$verb" ]; then
  helpfile="$TU/stub/$prog-\$verb-help.txt"
  if [ -f "\$helpfile" ]; then cat "\$helpfile"; exit 0; fi
  case "\$verb" in
    list) printf '%s\n' $listflags ;;
    create) printf '%s\n' $createflags ;;
    auth-status) printf '%s\n' $authflags ;;
  esac
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

# closed PATH sets — never the ambient $PATH, so a "missing" case is really missing regardless
# of what happens to be installed on the machine running this file, and a "present" case is
# always the stub, never a real forge CLI. $1 names the variant dir, the rest are the tools it
# gets ("claude"/"gh"/"glab" copy the stubs above; anything else symlinks the real binary — git,
# flock, timeout, jq are the only ones any case needs beyond /usr/bin:/bin's own coreutils).
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
ALLPATH="$(mkpath all claude flock git timeout gh glab jq)"           # everything present

export PATH="$ALLPATH" KAIZERO_FORGE=gh   # scenario-wide default; unset per-case for selection tests

# U32 — a run with nothing unchecked and a request open parks in `wait_for_reviews`: no claude launched, resumes and ends the instant the poll-tick sync reports the merge
mkorigin "$TU/u32code"; mkrepo "$TU/u32plan"
( cd "$TU/u32code"; git checkout -qb u32a-fix-thing; echo y > g; git add g; git commit -qm work
  git rev-parse HEAD > "$TU/u32a.sha"; git checkout -q main )
( cd "$TU/u32plan"; printf -- '- [\xe2\x86\x91] u32a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
u32sha=$(cat "$TU/u32a.sha")
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":9,"headRefOid":"$u32sha","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/9"}]
JSON
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u32launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u32launched"
P32=$(mkpath u32 claude flock git timeout gh glab jq)
( i=0; while ! grep -q 'Waiting for reviews' "$TU/u32.log" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":9,"headRefOid":"$u32sha","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/9"}]
JSON
) > "$TU/u32-peer.out" 2>&1 &
FLIP32=$!
( cd "$TU/u32code"; PATH="$P32" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 30 bash "$SCRIPT" "$TU/u32plan/todo.md" > "$TU/u32.log" 2>&1 )
check "U32 exit" "$?" "0"
check "U32 no claude launched" "$(wc -l < "$TU/u32launched" | tr -d ' ')" "0"
check "U32 shared status line" "$([ "$(grep -c 'Waiting for reviews · 1 open · 0 unchecked' "$TU/u32.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U32 wake line" "$(grep -c 'No requests left open' "$TU/u32.log")" "1"
check "U32 box now x" "$(git -C "$TU/u32plan" show HEAD:todo.md | grep -c '\[x\] u32a')" "1"
check "U32 run ends (proud)" "$(grep -c 'is proud' "$TU/u32.log")" "1"
wait "$FLIP32" 2>/dev/null || true
rm -f "$TU/stub/gh-list.out"
# - **U32 PASS** — the loop-top `sync-mrs` alone never resolves this: the fixture stages the
#   request `OPEN` from the start so the very first pass parks for real (proven by the status
#   line appearing before the flip), and only the poll-tick sync inside the park — not a human,
#   not the loop-top call — sees the merge and flips the box. No claude ever runs; `all_todos_done`
#   then ends the run on the next line, same as any other all-done run.

# U33 — `KAIZERO_REVIEW_WAIT=0` never parks: the run exits with the request still open, exactly as a plain run would
mkorigin "$TU/u33code"; mkrepo "$TU/u33plan"
( cd "$TU/u33code"; git checkout -qb u33a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u33plan"; printf -- '- [\xe2\x86\x91] u33a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":8,"headRefOid":"yyy","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/8"}]
JSON
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u33launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u33launched"
P33=$(mkpath u33 claude flock git timeout gh glab jq)
( cd "$TU/u33code"; PATH="$P33" KAIZERO_REVIEW_WAIT=0 timeout 20 bash "$SCRIPT" "$TU/u33plan/todo.md" > "$TU/u33.log" 2>&1 )
check "U33 exit" "$?" "0"
check "U33 no claude launched" "$(wc -l < "$TU/u33launched" | tr -d ' ')" "0"
check "U33 never parks" "$(grep -c 'Waiting for reviews' "$TU/u33.log")" "0"
check "U33 box unchanged (↑)" "$(git -C "$TU/u33plan" show HEAD:todo.md | grep -c '↑\] u33a')" "1"
rm -f "$TU/stub/gh-list.out"

# the ceiling elapsing (unlike REVIEW_WAIT=0) parks for real first, then falls through the same
# way — no wake line of its own, request left open, run ends normally.
mkorigin "$TU/u33bcode"; mkrepo "$TU/u33bplan"
( cd "$TU/u33bcode"; git checkout -qb u33ba-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u33bplan"; printf -- '- [\xe2\x86\x91] u33ba fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":13,"headRefOid":"zzz","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/13"}]
JSON
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u33blaunched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u33blaunched"
P33b=$(mkpath u33b claude flock git timeout gh glab jq)
( cd "$TU/u33bcode"; PATH="$P33b" KAIZERO_REVIEW_WAIT=3s KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=1h timeout 30 bash "$SCRIPT" "$TU/u33bplan/todo.md" > "$TU/u33b.log" 2>&1 )
check "U33b exit" "$?" "0"
check "U33b no claude launched" "$(wc -l < "$TU/u33blaunched" | tr -d ' ')" "0"
# unlike REVIEW_WAIT=0
check "U33b did park first" "$([ "$(grep -c 'Waiting for reviews' "$TU/u33b.log")" -ge 1 ] && echo yes || echo no)" "yes"
# ceiling elapsing prints nothing of its own
check "U33b no wake line" "$(grep -cE 'no requests left open|is claimable again' "$TU/u33b.log")" "0"
# request stays open
check "U33b box unchanged (↑)" "$(git -C "$TU/u33bplan" show HEAD:todo.md | grep -c '↑\] u33ba')" "1"
rm -f "$TU/stub/gh-list.out"
# - **U33 PASS** — `0` skips `wait_for_reviews`'s park outright, printing nothing; a set ceiling
#   (`U33b`) parks for real (the status line proves it), then elapses the same way — falling
#   through to `all_todos_done` silently, request left open — `0` and a ceiling elapsing both
#   return zero, but only a ceiling actually parked first.

# U34 — a human clearing a box to `[ ]` mid-park ends it exactly as a merge does: the run goes on to claim the reopened task, not exit
mkorigin "$TU/u34code"; mkrepo "$TU/u34plan"
( cd "$TU/u34code"; git checkout -qb u34a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u34plan"; printf -- '- [\xe2\x86\x91] u34a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":11,"headRefOid":"zzz","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/11"}]
JSON
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u34launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u34launched"
P34=$(mkpath u34 claude flock git timeout gh glab jq)
( i=0; while ! grep -q 'Waiting for reviews' "$TU/u34.log" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
  cd "$TU/u34plan"; sed -i.bak 's/\[.\] u34a/[ ] u34a/' todo.md; rm -f todo.md.bak
  git add todo.md; git commit -qm 'reviewer asked for changes, box reopened' ) > "$TU/u34-peer.out" 2>&1 &
FLIP34=$!
( cd "$TU/u34code"; PATH="$P34" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2h KAIZERO_MAX_LOOPS=1 timeout 30 bash "$SCRIPT" "$TU/u34plan/todo.md" > "$TU/u34.log" 2>&1 )
check "U34 exit" "$?" "0"
check "U34 claims the reopened task, not exit" "$(wc -l < "$TU/u34launched" | tr -d ' ')" "1"
check "U34 wake line names it" "$(grep -c 'u34a is claimable again' "$TU/u34.log")" "1"
wait "$FLIP34" 2>/dev/null || true
rm -f "$TU/stub/gh-list.out"
# - **U34 PASS** — `wait_for_reviews` re-evaluates its `unchecked` clause every tick regardless of
#   `open_requests`; the box going unchecked wakes the park (`KAIZERO_REVIEW_POLL` set far out
#   so only the human edit, not a stray poll, could have ended it), names the id, and the loop
#   proceeds to `wait_for_claimable` and launches — it does not fall into `all_todos_done`.

# U35 — every box `[⛔]`/`[?]`, none at `↑`: the wait returns at once and the run ends, same as any other all-done run
mkorigin "$TU/u35code"; mkrepo "$TU/u35plan"
( cd "$TU/u35plan"; printf -- '- [\xe2\x9b\x94] u35a declined\n- [?] u35b unclear\n' > todo.md; git add todo.md; git commit -qm todo )
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u35launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u35launched"
P35=$(mkpath u35 claude flock git timeout gh glab jq)
( cd "$TU/u35code"; PATH="$P35" timeout 20 bash "$SCRIPT" "$TU/u35plan/todo.md" > "$TU/u35.log" 2>&1 )
check "U35 exit" "$?" "0"
check "U35 no claude launched" "$(wc -l < "$TU/u35launched" | tr -d ' ')" "0"
check "U35 no park" "$(grep -c 'Waiting for reviews' "$TU/u35.log")" "0"
# - **U35 PASS** — `open_requests` is 0 (no `↑` box), so `wait_for_reviews`'s entry condition never
#   holds; it returns at once and `all_todos_done` ends the run on the next line.

# U75 — the claimable park routes back to the loop's top instead of exiting: a peer flipping the last held task to `[↑]` continues into the review park
mkorigin "$TU/u75code"; mkrepo "$TU/u75plan"
( cd "$TU/u75code"; git checkout -qb u75a-fix-thing; echo y > g; git add g; git commit -qm work
  git rev-parse HEAD > "$TU/u75a.sha"; git checkout -q main )
( cd "$TU/u75plan"; printf -- '- [ ] u75a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
u75sha=$(cat "$TU/u75a.sha")
# an OPEN PR at the matching sha, present from the start, so once the box flips to ↑ the loop-top
# sync-mrs that follows finds a legitimate, unresolved request and leaves it alone — no `[?]`,
# no commit, nothing to race the assertions below.
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":75,"headRefOid":"$u75sha","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/75"}]
JSON
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u75launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u75launched"
P75=$(mkpath u75 claude flock git timeout gh glab jq)

# a LIVE peer holding u75a: claim branch + worktree `.owner` + session marker, exactly what
# zero.sh's acquire writes and what held_todos/claimable_ids read back — on u75plan, the
# COORDINATION repo (`wait_for_claimable` reads $COORD_ROOT), not the target.
( cd "$TU/u75plan"
  sleep 600 & echo $! > "$TU/u75peer.pid"
  git worktree add -q -b main-task-u75a "$TU/u75wt" main
  printf '%s\n%s\n%s\n%s\n' "$(cat "$TU/u75peer.pid")" \
    "$(ps -o lstart= -p "$(cat "$TU/u75peer.pid")" | awk '{$1=$1;print}')" "$(date +%s)" "PEERINST" \
    > "$TU/u75wt/.owner"
  mkdir -p "$TU/u75plan/.git/session"
  printf '%s\n%s\n' "$(ps -o lstart= -p "$(cat "$TU/u75peer.pid")" | awk '{$1=$1;print}')" "u75a" \
    > "$TU/u75plan/.git/session/$(cat "$TU/u75peer.pid")" )

( i=0; while ! grep -q 'Waiting for a claimable Task . 1 held by peers' "$TU/u75.log" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
  # the peer hands u75a off (an MR opened) instead of landing it — the box goes straight to ↑,
  # never through [x], and the peer's own claim (worktree/.owner/session marker) is left in place
  # exactly as a real hand-off would leave it: `wait_for_claimable` must not care that it is now
  # stale, since it never gets asked again once unchecked_todos drops to 0.
  cd "$TU/u75plan"; printf -- '- [\xe2\x86\x91] u75a fix thing\n' > todo.md
  git add todo.md; git commit -qm 'peer hands off u75a' ) > "$TU/u75-peer.out" 2>&1 &
FLIP75=$!
cd "$TU/u75code"
PATH="$P75" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2h bash "$SCRIPT" "$TU/u75plan/todo.md" > "$TU/u75.log" 2>&1 &
WPID75=$!
i=0; while ! grep -q 'Waiting for reviews · 1 open · 0 unchecked' "$TU/u75.log" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
# not an exit straight out of the claimable park
check "U75 continued into review park" "$([ "$(grep -c 'Waiting for reviews · 1 open · 0 unchecked' "$TU/u75.log")" -ge 1 ] && echo yes || echo no)" "yes"
kill -TERM "$WPID75" 2>/dev/null
i=0; while kill -0 "$WPID75" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
kill -0 "$WPID75" 2>/dev/null && kill -KILL "$WPID75" 2>/dev/null
rc=0; wait "$WPID75" || rc=$?
# still parked, not already exited on its own
check "U75 exit" "$rc" "143"
check "U75 no claude launched" "$(wc -l < "$TU/u75launched" | tr -d ' ')" "0"
check "U75 closing report printed" "$([ "$(grep -c 'Execution stats' "$TU/u75.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U75 request stays open (up)" "$(git -C "$TU/u75plan" show HEAD:todo.md | grep -c '\[.\] u75a fix thing')" "1"
wait "$FLIP75" 2>/dev/null || true
kill "$(cat "$TU/u75peer.pid")" 2>/dev/null; wait "$(cat "$TU/u75peer.pid")" 2>/dev/null || true
git -C "$TU/u75plan" worktree remove --force "$TU/u75wt" 2>/dev/null || true
git -C "$TU/u75plan" branch -qD main-task-u75a 2>/dev/null || true
rm -f "$TU/stub/gh-list.out"
# - **U75 PASS** — `wait_for_claimable` returning "nothing unchecked" no longer breaks the loop
#   straight to the closer: it routes back to the loop's top, where `wait_for_reviews` gets its own
#   shot at the now-`↑` box and parks on the request the peer just opened, instead of the run
#   exiting the instant the last peer-held task stops being unchecked.

# U76 — absence check: routing "nothing unchecked" back to the loop's top turns no ending into a park — a zero-task list and an all-`[x]`/`[⛔]`/`[?]` list both still end at once, in MR mode and `--local-merge` alike
mkorigin "$TU/u76code"; mkrepo "$TU/u76plan"
( cd "$TU/u76plan"; printf '# Release Todo List\n\nno tasks yet.\n' > todo.md; git add todo.md; git commit -qm todo )
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u76launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u76launched"
P76=$(mkpath u76 claude flock git timeout gh glab jq)
start=$(date +%s)
( cd "$TU/u76code"; PATH="$P76" timeout 20 bash "$SCRIPT" "$TU/u76plan/todo.md" > "$TU/u76mr.log" 2>&1 )
# nothing to validate, nothing to claim, closer exits clean; not a spin
check "U76 mr zero-task exit" "$?" "0"
# no unbounded park on nothing
check "U76 mr zero-task elapsed" "$([ "$(( $(date +%s) - start ))" -lt 10 ] && echo yes || echo no)" "yes"
check "U76 mr zero-task no park line" "$(grep -c 'Waiting for reviews' "$TU/u76mr.log")" "0"
check "U76 mr zero-task no launch" "$(wc -l < "$TU/u76launched" | tr -d ' ')" "0"

( cd "$TU/u76plan"; printf -- '- [\xe2\x9b\x94] u76a declined\n- [?] u76b unclear\n' > todo.md; git add todo.md; git commit -qm todo )
: > "$TU/u76launched"
start=$(date +%s)
( cd "$TU/u76code"; PATH="$P76" timeout 20 bash "$SCRIPT" "$TU/u76plan/todo.md" > "$TU/u76mr2.log" 2>&1 )
check "U76 mr all-done exit" "$?" "0"
check "U76 mr all-done elapsed" "$([ "$(( $(date +%s) - start ))" -lt 10 ] && echo yes || echo no)" "yes"
check "U76 mr all-done no park line" "$(grep -c 'Waiting for reviews' "$TU/u76mr2.log")" "0"
check "U76 mr all-done no launch" "$(wc -l < "$TU/u76launched" | tr -d ' ')" "0"

# the same two lists, unchanged, under --local-merge — the mode-agnostic routing this slice adds
# to wait_for_claimable must change no ending outside MR mode.
( cd "$TU/u76plan"; printf '# Release Todo List\n\nno tasks yet.\n' > todo.md; git add todo.md; git commit -qm todo )
: > "$TU/u76launched"
start=$(date +%s)
( cd "$TU/u76code"; PATH="$P76" timeout 20 bash "$SCRIPT" --local-merge "$TU/u76plan/todo.md" > "$TU/u76lm.log" 2>&1 )
check "U76 lm zero-task exit" "$?" "0"
check "U76 lm zero-task elapsed" "$([ "$(( $(date +%s) - start ))" -lt 10 ] && echo yes || echo no)" "yes"
check "U76 lm zero-task no park line" "$(grep -c 'Waiting for reviews' "$TU/u76lm.log")" "0"

( cd "$TU/u76plan"; printf -- '- [\xe2\x9b\x94] u76a declined\n- [?] u76b unclear\n' > todo.md; git add todo.md; git commit -qm todo )
: > "$TU/u76launched"
start=$(date +%s)
( cd "$TU/u76code"; PATH="$P76" timeout 20 bash "$SCRIPT" --local-merge "$TU/u76plan/todo.md" > "$TU/u76lm2.log" 2>&1 )
check "U76 lm all-done exit" "$?" "0"
check "U76 lm all-done elapsed" "$([ "$(( $(date +%s) - start ))" -lt 10 ] && echo yes || echo no)" "yes"
check "U76 lm all-done no park line" "$(grep -c 'Waiting for reviews' "$TU/u76lm2.log")" "0"
check "U76 lm all-done no launch" "$(wc -l < "$TU/u76launched" | tr -d ' ')" "0"
# - **U76 PASS** — `wait_for_claimable`'s "nothing unchecked" case only routes back to the loop's
#   top when `open_requests` is at least 1 — with none open (a list the parser recognises zero
#   Tasks in, or one whose boxes are all `[⛔]`/`[?]`) it still returns 1, the original
#   break-to-closer path, in both MR mode and `--local-merge`: neither list ever parks, neither
#   spins, and both exit clean (0, nothing left to do) in about a second — the routing change is
#   invisible outside the one shape (nothing unchecked, something still at `↑`) it exists to fix.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
