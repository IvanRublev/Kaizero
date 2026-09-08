#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=780s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-021-breaking-the-park — a todo broken during the park, SIGTERM, and a forge token that dies
# mid-park.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-021-breaking-the-park
# Wall-clock budget: its longest Run command is `timeout 70` — allow that command at least 70s
#
# wait_for_reviews/wait_for_dependency_clear's MR-mode behaviours live in kaizero.sh's own
# run_loop, not in the emitted zero.sh — zero_funcs/KAIZERO_TEST_EMIT can't reach them, so the
# cases below run the real doctor and the real restart loop: a real, fetchable, no-host bare
# origin (mkorigin) for the target, a plain mkrepo for the coordination repo, and a controllable
# stub claude rebuilt per case via mkpath (a snapshot copy, so each case's $TU/bin/claude must be
# written before its own mkpath call).
#
# The three ways a park ends badly and still ends once: a human breaking the todo's ids DURING the
# park (no box rewritten, the run stopped through the exit-2 closer), a SIGTERM that reaches the
# single closer with the requests left open, and a token that dies inside the park rather than
# before it. A fourth case, U59 (and its wait_for_dependency_clear-side twin, U64), is the one way
# a park does NOT end: a login probe that fails once and clears again before the shared re-check's
# own retry window is exhausted.

### Setup
TU="$TESTROOT/U-021-breaking-the-park"; mkdir -p "$TU/bin" "$TU/stub"
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

### U55 — an in-wait `sync-mrs` is gated on `validate-ids`: a todo a human breaks DURING a park gets no box rewritten, the park ends, and the loop's own check stops the run through the exit-2 closer
mkorigin "$TU/u55code"; mkrepo "$TU/u55plan"
( cd "$TU/u55code"; git checkout -qb u55a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u55plan"; printf -- '- [\xe2\x86\x91] u55a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
u55sha=$(git -C "$TU/u55code" rev-parse u55a-fix-thing)
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":55,"headRefOid":"$u55sha","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/55"}]
JSON
P55=$(mkpath u55 claude flock git timeout gh glab jq)

# control: this exact fixture (same sha, MERGED), unblocked, writes a `zero sync u55a` commit and
# self-ends the moment it does — proving the 0-count assertion below is non-vacuous: an eternally
# OPEN/mismatched-sha PR could never produce one regardless of whether sync ran at all.
( cd "$TU/u55code"; PATH="$P55" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 40 bash "$SCRIPT" "$TU/u55plan/todo.md" > "$TU/u55ctrl.log" 2>&1 )
check "U55 control: fixture can sync" "$(git -C "$TU/u55plan" log --oneline --grep='zero sync u55a' | wc -l | tr -d ' ')" "1"
git -C "$TU/u55plan" reset -q --hard HEAD~1
# the control run's own successful sync deleted u55a-fix-thing on a MERGED verdict — recreate it
# at the same sha for the real run below, which needs a local branch to hold the box at ↑.
git -C "$TU/u55code" branch u55a-fix-thing "$u55sha"
# the real run must reach a PARK before the box can resolve — an already-MERGED PR at loop-top
# resolves on the very first pass, before wait_for_reviews (and this case's own corruption) is
# ever reached, exactly as the control run above just demonstrated. So the real run starts with
# the PR still OPEN (no commit possible yet, park reached normally) and FLIP55 below flips it to
# the SAME MERGED+matching-sha data the control run used, at the same moment it injects the
# corruption — an in-wait sync that reached this data unblocked would produce the very commit the
# control run proved it can.
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":55,"headRefOid":"$u55sha","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/55"}]
JSON

printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u55launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u55launched"
P55=$(mkpath u55 claude flock git timeout gh glab jq)
( i=0; while ! grep -q 'Waiting for reviews' "$TU/u55.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":55,"headRefOid":"$u55sha","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/55"}]
JSON
  cd "$TU/u55plan"
  # a human breaks the todo mid-park: a second line sharing u55a's leading id token. Landed
  # (`[x]`), not `[ ]` — a plain box here would itself become newly-claimable and race
  # wait_for_reviews's own fast unchecked-count re-check ahead of the slower validate-ids poll
  # this case means to exercise.
  printf -- '- [\xe2\x86\x91] u55a fix thing\n- [x] u55a duplicate landed\n' > todo.md
  git add todo.md; git commit -qm 'operator accidentally duplicated the id' ) &
FLIP55=$!
rc=0
( cd "$TU/u55code"; PATH="$P55" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 60 bash "$SCRIPT" "$TU/u55plan/todo.md" > "$TU/u55.log" 2>&1 ) || rc=$?
check "U55 exit" "$rc" "2"
check "U55 no claude launched" "$(wc -l < "$TU/u55launched" | tr -d ' ')" "0"
check "U55 validate-ids message" "$(grep -c 'Task id validation failed' "$TU/u55.log")" "1"
check "U55 names the duplicate" "$([ "$(grep -c 'duplicate-id u55a' "$TU/u55.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U55 report still printed" "$([ "$(grep -c 'Execution stats' "$TU/u55.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U55 no box rewritten by sync" "$(git -C "$TU/u55plan" log --oneline --grep='zero sync' | wc -l | tr -d ' ')" "0"
wait "$FLIP55" 2>/dev/null || true
rm -f "$TU/stub/gh-list.out"
# U55 PASS — the poll-tick's own validate-ids gate catches a todo broken mid-park exactly as the
# loop-top call does: the in-wait sync never runs (no zero sync u55a commit — the control run
# above proves this exact fixture would write one the moment a poll tick reaches sync-mrs
# unblocked), the park ends, and the loop stops through the same IDFAIL/exit-2 closer, report
# still printed, no claude launched.

### U56 — `SIGTERM` during a review park breaks to the single closer: exit 143, closing report printed, requests stay open
mkorigin "$TU/u56code"; mkrepo "$TU/u56plan"
( cd "$TU/u56code"; git checkout -qb u56a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u56plan"; printf -- '- [\xe2\x86\x91] u56a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":56,"headRefOid":"zzz","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/56"}]
JSON
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u56launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u56launched"
P56=$(mkpath u56 claude flock git timeout gh glab jq)
cd "$TU/u56code"
PATH="$P56" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2h bash "$SCRIPT" "$TU/u56plan/todo.md" > "$TU/u56.log" 2>&1 &
WPID=$!
i=0; while ! grep -q 'Waiting for reviews' "$TU/u56.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
check "U56 parked before signal" "$([ "$(grep -c 'Waiting for reviews' "$TU/u56.log")" -ge 1 ] && echo yes || echo no)" "yes"
kill -TERM "$WPID" 2>/dev/null
i=0; while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
kill -0 "$WPID" 2>/dev/null && kill -KILL "$WPID" 2>/dev/null
rc=0; wait "$WPID" || rc=$?
check "U56 exit" "$rc" "143"
check "U56 no claude launched" "$(wc -l < "$TU/u56launched" | tr -d ' ')" "0"
check "U56 closing report printed" "$([ "$(grep -c 'Execution stats' "$TU/u56.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U56 request stays open (up)" "$(git -C "$TU/u56plan" show HEAD:todo.md | grep -c '↑\] u56a')" "1"
rm -f "$TU/stub/gh-list.out"
# U56 PASS — the same TERM path every other wait breaks to (STOP=1 on the trap, checked at the
# top of wait_for_reviews's loop): the park ends without ever launching claude, the closing
# report still prints, and the open request is left exactly as it was for the human.

### U58 — a token that dies DURING a review park stops the run through the closer, exit 2, instead of `sync-mrs` swallowing the failure and spinning forever
mkorigin "$TU/u58code"; mkrepo "$TU/u58plan"
( cd "$TU/u58code"; git checkout -qb u58a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u58plan"; printf -- '- [\xe2\x86\x91] u58a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
u58sha=$(git -C "$TU/u58code" rev-parse u58a-fix-thing)
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":58,"headRefOid":"$u58sha","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/58"}]
JSON
P58=$(mkpath u58 claude flock git timeout gh glab jq)

# control: this exact fixture (same sha, MERGED), unblocked, writes a `zero sync u58a` commit and
# self-ends the moment it does — proving the 0-count assertion below is non-vacuous.
( cd "$TU/u58code"; PATH="$P58" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 40 bash "$SCRIPT" "$TU/u58plan/todo.md" > "$TU/u58ctrl.log" 2>&1 )
check "U58 control: fixture can sync" "$(git -C "$TU/u58plan" log --oneline --grep='zero sync u58a' | wc -l | tr -d ' ')" "1"
git -C "$TU/u58plan" reset -q --hard HEAD~1
# the control run's own successful sync deleted u58a-fix-thing on a MERGED verdict — recreate it
# at the same sha for the real run below, which needs a local branch to hold the box at ↑.
git -C "$TU/u58code" branch u58a-fix-thing "$u58sha"
# a hostless origin (mkorigin's default) makes forge_auth_ok's own `[ -n "$ORIGIN_HOST" ] ||
# return 0` skip the probe entirely — this case needs it to actually fire, so the real run's
# origin is given a real host the same way U36 fixed it: git's file:// transport ignores the host
# for the actual transfer, but `git remote get-url`/origin_parts still see it.
git -C "$TU/u58code" remote set-url origin "file://u58-gh.example$TU/u58code-origin.git"
# and, as in U55: an already-MERGED PR resolves on loop-top's very first pass, before this case's
# own corruption is ever injected — start OPEN, flip to the control run's MERGED data only once
# FLIP58 fires, so an unblocked in-wait sync would have produced exactly the commit the control
# run above proved this data can produce.
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":58,"headRefOid":"$u58sha","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/58"}]
JSON

printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u58launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u58launched"
P58=$(mkpath u58 claude flock git timeout gh glab jq)
rm -f "$TU/stub/gh-auth-status-u58-gh.example"
( i=0; while ! grep -q 'Waiting for reviews' "$TU/u58.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":58,"headRefOid":"$u58sha","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/58"}]
JSON
  echo "broken login" > "$TU/stub/gh-auth-status-u58-gh.example" ) &
FLIP58=$!
rc=0
( cd "$TU/u58code"; PATH="$P58" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 60 bash "$SCRIPT" "$TU/u58plan/todo.md" > "$TU/u58.log" 2>&1 ) || rc=$?
check "U58 exit" "$rc" "2"
check "U58 no claude launched" "$(wc -l < "$TU/u58launched" | tr -d ' ')" "0"
check "U58 auth status message" "$(grep -c 'auth status failed' "$TU/u58.log")" "1"
check "U58 report still printed" "$([ "$(grep -c 'Execution stats' "$TU/u58.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U58 no sync commit after break" "$(git -C "$TU/u58plan" log --oneline --grep='zero sync' | wc -l | tr -d ' ')" "0"
wait "$FLIP58" 2>/dev/null || true
rm -f "$TU/stub/gh-auth-status-" "$TU/stub/gh-list.out"
# U58 PASS — wait_for_reviews's own poll tick now re-runs the same $FORGE auth status probe the
# pre-launch re-check uses, ahead of sync-mrs — a token that dies mid-park is caught there
# instead of sync-mrs's `|| true` swallowing every failure silently forever; the park ends
# through the same IDFAIL/exit-2 closer validate-ids uses, report still printed, no claude
# launched, no zero sync u58a commit past the break (the control run above proves this exact
# fixture would have written one had sync-mrs been reached).

### U59 — a network blip that clears within `forge_auth_ok`'s own retries never reaches the closer
mkorigin "$TU/u59code"; mkrepo "$TU/u59plan"
( cd "$TU/u59code"; git checkout -qb u59a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u59plan"; printf -- '- [\xe2\x86\x91] u59a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":59,"headRefOid":"zzz","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/59"}]
JSON
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u59launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u59launched"
P59=$(mkpath u59 claude flock git timeout gh glab jq)
rm -f "$TU/stub/gh-auth-status-"
( i=0; while ! grep -q 'Waiting for reviews' "$TU/u59.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
  echo "connection reset" > "$TU/stub/gh-auth-status-"
  sleep 6   # piped to a file, wait_for_reviews's own loop only iterates once per WAIT_TICK
            # (5s) — a window shorter than that can clear before the next iteration's
            # forge_auth_ok call ever observes it, exercising the retry-absorb path on
            # only ~2 in 5 runs; longer than WAIT_TICK guarantees the next iteration always sees it
  rm -f "$TU/stub/gh-auth-status-" ) &
FLIP59=$!
cd "$TU/u59code"
PATH="$P59" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s bash "$SCRIPT" "$TU/u59plan/todo.md" > "$TU/u59.log" 2>&1 &
WPID=$!
i=0; while [ "$i" -lt 120 ] && ! grep -q 'auth status failed\|execution stats' "$TU/u59.log" 2>/dev/null; do sleep 0.5; i=$((i+1)); done
kill -TERM "$WPID" 2>/dev/null
i=0; while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
kill -0 "$WPID" 2>/dev/null && kill -KILL "$WPID" 2>/dev/null
wait "$WPID" 2>/dev/null || true
check "U59 no claude launched" "$(wc -l < "$TU/u59launched" | tr -d ' ')" "0"
check "U59 auth status message" "$(grep -c 'auth status failed' "$TU/u59.log")" "0"
check "U59 still parking after blip" "$([ "$(grep -c 'Waiting for reviews' "$TU/u59.log")" -ge 2 ] && echo yes || echo no)" "yes"
wait "$FLIP59" 2>/dev/null || true
rm -f "$TU/stub/gh-auth-status-" "$TU/stub/gh-list.out"
# U59 PASS — forge_auth_ok's retries (three tries, two seconds apart) absorb a login probe that
# fails once and clears again before they're exhausted: no "auth status failed" message, no
# closer, the park keeps polling past the blip exactly as it would have with no blip at all — the
# fleet stays up through an outage that used to make the run fatal.

### U60 — a token that dies DURING a `wait_for_dependency_clear` park (a task blocked on an `[↑]` prerequisite, MR mode) stops the run through the closer, exit 2, instead of spinning forever on the blocked sibling
mkorigin "$TU/u60code"; mkrepo "$TU/u60plan"
( cd "$TU/u60code"; git checkout -qb u60a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u60plan"; printf -- '- [\xe2\x86\x91] u60a fix thing\n- [ ] u60b needs u60a\n' > todo.md; git add todo.md; git commit -qm todo )
u60sha=$(git -C "$TU/u60code" rev-parse u60a-fix-thing)
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":60,"headRefOid":"$u60sha","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/60"}]
JSON

# control: a byte-identical clone of u60plan, unblocked (no marker planted, auth healthy) — the
# park's own poll tick reaches sync-mrs and writes `zero sync u60a`, proving this exact fixture
# (same PR JSON, same sha) is capable of the commit the broken run below claims never happens.
cp -r "$TU/u60plan" "$TU/u60plan-ctrl"
: > "$TU/u60ctrllaunched"
cat > "$TU/bin/claude" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$TU/u60ctrllaunched"
n=\$(wc -l < "$TU/u60ctrllaunched" | tr -d ' ')
[ "\$n" -eq 1 ] && "$TU/u60plan-ctrl/.git/zero.sh" no-claim-mark
exit 0
EOF
chmod +x "$TU/bin/claude"
P60ctrl=$(mkpath u60ctrl claude flock git timeout gh glab jq)
( cd "$TU/u60code"; PATH="$P60ctrl" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s KAIZERO_MAX_LOOPS=2 timeout 40 bash "$SCRIPT" "$TU/u60plan-ctrl/todo.md" > "$TU/u60ctrl.log" 2>&1 )
check "U60 control: fixture can sync" "$(git -C "$TU/u60plan-ctrl" log --oneline --grep='zero sync u60a' | wc -l | tr -d ' ')" "1"
zap "$TU/u60plan-ctrl"
# the control run's own successful sync deleted u60a-fix-thing on a MERGED verdict (both runs
# share $TU/u60code) — recreate it at the same sha for the real run below.
git -C "$TU/u60code" branch u60a-fix-thing "$u60sha"
# a hostless origin (mkorigin's default) makes forge_auth_ok's own `[ -n "$ORIGIN_HOST" ] ||
# return 0` skip the probe entirely — this case needs it to actually fire once parked on u60b, so
# the real run's origin is given a real host the same way U36/U58 did: git's file:// transport
# ignores the host for the actual transfer, but `git remote get-url`/origin_parts still see it.
git -C "$TU/u60code" remote set-url origin "file://u60-gh.example$TU/u60code-origin.git"
# the real run's own loop-top sync-mrs would otherwise resolve u60a on its very first pass — same
# MERGED data as the control above — before wait_for_dependency_clear is ever reached for u60b,
# leaving nothing at ↑ by the time it parks. Reset to OPEN so u60a stays a genuine open request
# for the whole run, exactly as U62/U64's siblings do, so this case's park is MR-review-active.
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":60,"headRefOid":"$u60sha","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/60"}]
JSON

: > "$TU/u60launched"
cat > "$TU/bin/claude" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$TU/u60launched"
n=\$(wc -l < "$TU/u60launched" | tr -d ' ')
[ "\$n" -eq 1 ] && "$TU/u60plan/.git/zero.sh" no-claim-mark
exit 0
EOF
chmod +x "$TU/bin/claude"
P60=$(mkpath u60 claude flock git timeout gh glab jq)
rm -f "$TU/stub/gh-auth-status-u60-gh.example"
( i=0; while ! grep -q 'Waiting for reviews' "$TU/u60.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
  echo "broken login" > "$TU/stub/gh-auth-status-u60-gh.example" ) &
FLIP60=$!
rc=0
( cd "$TU/u60code"; PATH="$P60" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 60 bash "$SCRIPT" "$TU/u60plan/todo.md" > "$TU/u60.log" 2>&1 ) || rc=$?
check "U60 exit" "$rc" "2"
check "U60 exactly one launch" "$(wc -l < "$TU/u60launched" | tr -d ' ')" "1"
check "U60 auth status message" "$(grep -c 'auth status failed' "$TU/u60.log")" "1"
check "U60 report still printed" "$([ "$(grep -c 'Execution stats' "$TU/u60.log")" -ge 1 ] && echo yes || echo no)" "yes"
# u60a stays OPEN for the whole run (see the reset above), so neither its own box nor u60b's
# should ever get a sync commit here — the token dies before either could resolve.
check "U60 no sync commit after break" "$(git -C "$TU/u60plan" log --oneline --grep='zero sync' | wc -l | tr -d ' ')" "0"
wait "$FLIP60" 2>/dev/null || true
rm -f "$TU/stub/gh-auth-status-u60-gh.example" "$TU/stub/gh-list.out"
# U60 PASS — wait_for_dependency_clear's own poll tick, while its active flag is on (an open
# request keeps u60a genuinely at [↑] for the whole run), now re-runs the same $FORGE auth status
# probe wait_for_reviews's poll and the pre-launch re-check use, ahead of sync-mrs — a token that
# dies while parked on a blocked sibling is caught there instead of spinning on the blocked
# marker forever; the park ends through the same IDFAIL/exit-2 closer, report still printed,
# exactly one claude launch (the one that marked the block), no zero sync u60a commit past the
# break (the control run above proves this exact fixture would have written one had sync-mrs
# been reached).

### U61 — a transient, non-auth `sync-mrs` failure (`gh pr list` itself fails, login healthy) does not stop a `wait_for_reviews` park
mkorigin "$TU/u61code"; mkrepo "$TU/u61plan"
( cd "$TU/u61code"; git checkout -qb u61a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u61plan"; printf -- '- [\xe2\x86\x91] u61a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
: > "$TU/u61launched"
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u61launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
P61=$(mkpath u61 claude flock git timeout gh glab jq)
rm -f "$TU/stub/gh-list" "$TU/stub/gh-auth-status-"
echo "connection reset" > "$TU/stub/gh-list"
( cd "$TU/u61code"; PATH="$P61" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 56 bash "$SCRIPT" "$TU/u61plan/todo.md" > "$TU/u61.log" 2>&1 ) || true
check "U61 no claude launched" "$(wc -l < "$TU/u61launched" | tr -d ' ')" "0"
check "U61 auth status message" "$(grep -c 'auth status failed' "$TU/u61.log")" "0"
check "U61 still parking" "$([ "$(grep -c 'Waiting for reviews' "$TU/u61.log")" -ge 2 ] && echo yes || echo no)" "yes"
rm -f "$TU/stub/gh-list"
# U61 PASS — forge_auth_ok alone cannot distinguish a dead token from a `gh pr list` blip: with
# login healthy and only `list` failing, the probe passes, `sync-mrs` fails and is swallowed by
# its own `|| true` exactly as before this fix, no "auth status failed" line appears, and the
# park keeps polling.

### U62 — a transient, non-auth `sync-mrs` failure (`gh pr list` fails, login healthy) does not stop a `wait_for_dependency_clear` park
mkorigin "$TU/u62code"; mkrepo "$TU/u62plan"
( cd "$TU/u62code"; git checkout -qb u62a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u62plan"; printf -- '- [\xe2\x86\x91] u62a fix thing\n- [ ] u62b needs u62a\n' > todo.md; git add todo.md; git commit -qm todo )
: > "$TU/u62launched"
cat > "$TU/bin/claude" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$TU/u62launched"
n=\$(wc -l < "$TU/u62launched" | tr -d ' ')
[ "\$n" -eq 1 ] && "$TU/u62plan/.git/zero.sh" no-claim-mark
exit 0
EOF
chmod +x "$TU/bin/claude"
P62=$(mkpath u62 claude flock git timeout gh glab jq)
rm -f "$TU/stub/gh-list" "$TU/stub/gh-auth-status-"
echo "connection reset" > "$TU/stub/gh-list"
( cd "$TU/u62code"; PATH="$P62" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 70 bash "$SCRIPT" "$TU/u62plan/todo.md" > "$TU/u62.log" 2>&1 ) || true
# the block, none after; still parked when timeout hits
check "U62 exactly one launch" "$(wc -l < "$TU/u62launched" | tr -d ' ')" "1"
check "U62 auth status message" "$(grep -c 'auth status failed' "$TU/u62.log")" "0"
check "U62 still parking" "$([ "$(grep -c 'Waiting for reviews' "$TU/u62.log")" -ge 2 ] && echo yes || echo no)" "yes"
rm -f "$TU/stub/gh-list"
# U62 PASS — same distinction as U61, proven at the sibling park: a `list`-only failure with
# login healthy never reaches the `auth status failed` message, and the block stays parked on the
# marker instead of ending.

### U63 — absence checks: the shared probe count stays two, both park poll ticks gate `sync-mrs` on it, and the unbounded default is untouched
check "U63 forge auth-status literal sites" "$(grep -cF '"$FORGE" auth status --hostname "$ORIGIN_HOST"' "$REPO/kaizero.sh")" "2"
check "U63 wait_for_reviews's poll gates on mr_network_and_auth_ok before sync-mrs" "$(awk '/^wait_for_reviews\(\)/,/^}/' "$REPO/kaizero.sh" | grep -c 'mr_network_and_auth_ok')" "1"
check "U63 wait_for_dependency_clear's poll gates on mr_network_and_auth_ok before sync-mrs" "$(awk '/^wait_for_dependency_clear\(\)/,/^}/' "$REPO/kaizero.sh" | grep -c 'mr_network_and_auth_ok')" "1"
check "U63 REVIEW_WAIT_SECS default still unbounded (empty), unchanged from HEAD" "$(grep -c '^REVIEW_WAIT_SECS=\"\"$' "$REPO/kaizero.sh")" "1"
# U63 PASS — wait_for_dependency_clear's poll tick reuses the exact same mr_network_and_auth_ok
# gate wait_for_reviews's poll and the pre-launch re-check already call — BUG-047's shared
# network+auth split, which itself calls forge_auth_ok — so the literal "$FORGE" auth status
# --hostname text still appears exactly twice in the file (the doctor's own inline probe, and
# forge_auth_ok's own body) — a shared function, not a third copy of the command;
# REVIEW_WAIT_SECS's empty (unbounded) default is untouched.

### U64 — a network blip during a `wait_for_dependency_clear` park (a task blocked on an `[↑]` prerequisite, MR mode) clears within `mr_network_and_auth_ok`'s own re-check and never reaches the closer (BUG-047)
mkorigin "$TU/u64code"; mkrepo "$TU/u64plan"
( cd "$TU/u64code"; git checkout -qb u64a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u64plan"; printf -- '- [\xe2\x86\x91] u64a fix thing\n- [ ] u64b needs u64a\n' > todo.md; git add todo.md; git commit -qm todo )
u64sha=$(git -C "$TU/u64code" rev-parse u64a-fix-thing)
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":64,"headRefOid":"$u64sha","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/64"}]
JSON
: > "$TU/u64launched"
cat > "$TU/bin/claude" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$TU/u64launched"
n=\$(wc -l < "$TU/u64launched" | tr -d ' ')
[ "\$n" -eq 1 ] && "$TU/u64plan/.git/zero.sh" no-claim-mark
exit 0
EOF
chmod +x "$TU/bin/claude"
P64=$(mkpath u64 claude flock git timeout gh glab jq)
rm -f "$TU/stub/gh-auth-status-"
( i=0; while ! grep -q 'Waiting for reviews' "$TU/u64.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
  echo "connection reset" > "$TU/stub/gh-auth-status-"
  sleep 9   # longer than wait_for_dependency_clear's own WAIT_TICK (5s) poll granularity plus
            # margin for the first poll landing right at a 5s boundary — guarantees the poll
            # that fires once per outer tick always lands inside the window
  rm -f "$TU/stub/gh-auth-status-" ) &
FLIP64=$!
cd "$TU/u64code"
PATH="$P64" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s bash "$SCRIPT" "$TU/u64plan/todo.md" > "$TU/u64.log" 2>&1 &
WPID=$!
i=0; while [ "$i" -lt 300 ] && [ "$(grep -c 'Waiting for reviews' "$TU/u64.log" 2>/dev/null)" -lt 2 ] && ! grep -q 'auth status failed' "$TU/u64.log" 2>/dev/null; do sleep 0.5; i=$((i+1)); done
kill -TERM "$WPID" 2>/dev/null
i=0; while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
kill -0 "$WPID" 2>/dev/null && kill -KILL "$WPID" 2>/dev/null
wait "$WPID" 2>/dev/null || true
check "U64 exactly one launch" "$(wc -l < "$TU/u64launched" | tr -d ' ')" "1"
check "U64 auth status message" "$(grep -c 'auth status failed' "$TU/u64.log")" "0"
check "U64 still parking after blip" "$([ "$(grep -c 'Waiting for reviews' "$TU/u64.log")" -ge 2 ] && echo yes || echo no)" "yes"
wait "$FLIP64" 2>/dev/null || true
rm -f "$TU/stub/gh-auth-status-" "$TU/stub/gh-list.out"
# U64 PASS — wait_for_dependency_clear's poll tick routes through the same mr_network_and_auth_ok
# U59 exercises on wait_for_reviews's side: a login probe that fails once with a network-shaped
# message and clears again inside the re-check's own window never prints "auth status failed" and
# never reaches the closer — the park (still blocked on u64b's unmet u64a prerequisite) keeps
# polling past the blip exactly as U60's own park does when no blip ever lands, and no second
# claude session launches beyond the one that recorded the block. Verified against a deliberately
# reverted copy of this call site (the pre-BUG-047 bare, non-absorbing auth check) first: that
# copy fails this exact case (auth status message: 1, still parking after blip: 1), proving the
# assertions actually distinguish broken from fixed behavior before the real script (green here)
# satisfies them.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
