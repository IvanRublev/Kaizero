#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=440s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-018-the-park-and-blocked-dependencies — a dead token, a task unblocked by the poll tick, and
# the call sites that gate both.
# Needs real `claude`: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under `$TESTROOT`: `$TESTROOT/U-018-the-park-and-blocked-dependencies`
# Wall-clock budget: its longest Run command is `timeout 60` — allow that command at least 60s
#
# `wait_for_reviews`/`wait_for_dependency_clear`'s MR-mode behaviours live in `kaizero.sh`'s
# own `run_loop`, not in the emitted `zero.sh` — `zero_funcs`/`KAIZERO_TEST_EMIT` can't reach
# them, so the cases below run the *real* doctor and the *real* restart loop: a real, fetchable,
# no-host bare origin (`mkorigin`) for the target, a plain `mkrepo` for the coordination repo, and
# a controllable stub `claude` rebuilt per case via `mkpath` (a snapshot copy, so each case's
# `$TU/bin/claude` must be written before its own `mkpath` call).
#
# Where the park meets the rest of the loop: an expired token stops the run through the closer
# rather than relaunching claude to fail again, a task blocked on an `[↑]` prerequisite is claimed
# the moment the poll-tick sync unblocks it, and the absence checks name the call sites that gate
# both.

# Setup
TU="$TESTROOT/U-018-the-park-and-blocked-dependencies"; mkdir -p "$TU/bin" "$TU/stub"
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

# U36 — an expired token stops the run through the closer, exit 2, rather than relaunching claude every `RESTART_WAIT` to fail again
mkorigin "$TU/u36code"; mkrepo "$TU/u36plan"
# a hostless origin skips the auth-status probe entirely (check 6/forge_auth_ok's own rule) — this
# case needs the probe to actually run, so the origin is given a real host. `git remote get-url`
# (what kaizero.sh's own origin_parts reads) applies any insteadOf rewrite before returning, so
# an insteadOf-based trick still resolves back to a hostless local path — but git's file transport
# ignores a file:// URL's host entirely for the actual transfer, so a `file://<host>/<abs-path>`
# URL both keeps a real host in the resolved URL and fetches straight from mkorigin's local bare
# repo, no rewrite needed.
( cd "$TU/u36code"; git remote set-url origin "file://u36-gh.example$TU/u36code-origin.git" )
( cd "$TU/u36plan"; printf -- '- [ ] u36a task\n' > todo.md; git add todo.md; git commit -qm todo )
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/u36launched"\nexit 0\n' "$TU" > "$TU/bin/claude"; chmod +x "$TU/bin/claude"
: > "$TU/u36launched"
P36=$(mkpath u36 claude flock git timeout gh glab jq)
rm -f "$TU/stub/gh-auth-status-u36-gh.example"
# the token is good at startup (the launch-time doctor passes) and expires only mid-run — this
# fixture flips the SAME probe's stub only after the first claude has already launched once, so
# it is run_loop's own re-check, not the doctor's one-time startup check, that this proves.
( i=0; while [ "$(wc -l < "$TU/u36launched" 2>/dev/null | tr -d ' ')" -lt 1 ] && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
  echo "broken login" > "$TU/stub/gh-auth-status-u36-gh.example" ) > "$TU/u36-peer.out" 2>&1 &
FLIP36=$!
rc=0
( cd "$TU/u36code"; PATH="$P36" timeout 40 bash "$SCRIPT" "$TU/u36plan/todo.md" > "$TU/u36b.log" 2>&1 ) || rc=$?
check "U36 exit" "$rc" "2"
# no relaunch after the check breaks it
check "U36 exactly one launch" "$(wc -l < "$TU/u36launched" | tr -d ' ')" "1"
check "U36 message printed" "$(grep -c 'auth status failed' "$TU/u36b.log")" "1"
check "U36 report still printed" "$([ "$(grep -c 'Execution stats' "$TU/u36b.log")" -ge 1 ] && echo yes || echo no)" "yes"

wait "$FLIP36" 2>/dev/null || true
rm -f "$TU/stub/gh-auth-status-u36-gh.example"     # this host's own marker, clear before the unrelated-host case

# an unrelated host's own problem does not break this launch — same scoping as the doctor's own
# check 5 (U4), proven here against the mid-run re-check specifically.
echo "broken login for some other host" > "$TU/stub/gh-auth-status-unrelated.example.com"
( cd "$TU/u36code"; PATH="$P36" KAIZERO_MAX_LOOPS=1 timeout 40 bash "$SCRIPT" "$TU/u36plan/todo.md" > "$TU/u36c.log" 2>&1 )
check "U36 unrelated host does not break" "$?" "0"
rm -f "$TU/stub/gh-auth-status-unrelated.example.com"
# - **U36 PASS** — the pre-launch re-check breaks the loop the instant the token goes bad, through
#   the same `IDFAIL`/exit-2 closer `validate-ids` uses, so the report still prints; a problem
#   scoped to some other host never touches this launch.

# U37 — `wait_for_dependency_clear` (MR mode active): a task blocked on an `[↑]` prerequisite is claimed the moment the poll-tick sync unblocks it — no claude launches in between
mkorigin "$TU/u37code"; mkrepo "$TU/u37plan"
( cd "$TU/u37code"; git checkout -qb u37a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u37plan"; printf -- '- [\xe2\x86\x91] u37a fix thing\n- [ ] u37b needs u37a\n' > todo.md; git add todo.md; git commit -qm todo )
cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":21,"headRefOid":"aaa","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/21"}]
JSON
: > "$TU/u37launched"
cat > "$TU/bin/claude" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$TU/u37launched"
n=\$(wc -l < "$TU/u37launched" | tr -d ' ')
[ "\$n" -eq 1 ] && "$TU/u37plan/.git/zero.sh" no-claim-mark
exit 0
EOF
chmod +x "$TU/bin/claude"
P37=$(mkpath u37 claude flock git timeout gh glab jq)
( i=0; while ! grep -q 'Waiting for reviews' "$TU/u37.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
  u37sha=$(git -C "$TU/u37code" rev-parse u37a-fix-thing)
  cat > "$TU/stub/gh-list.out" <<JSON
[{"number":21,"headRefOid":"$u37sha","baseRefName":"main","state":"MERGED","url":"https://example.invalid/pr/21"}]
JSON
) > "$TU/u37-peer.out" 2>&1 &
FLIP37=$!
( cd "$TU/u37code"; PATH="$P37" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s KAIZERO_MAX_LOOPS=2 timeout 60 bash "$SCRIPT" "$TU/u37plan/todo.md" > "$TU/u37.log" 2>&1 )
check "U37 exit" "$?" "0"
# one that marked the block, one after the unblock, none between
check "U37 launches" "$(wc -l < "$TU/u37launched" | tr -d ' ')" "2"
check "U37 shared status line" "$([ "$(grep -c 'Waiting for reviews . 1 open . 1 unchecked' "$TU/u37.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U37 wake line" "$(grep -c 'u37b is claimable again' "$TU/u37.log")" "1"
wait "$FLIP37" 2>/dev/null || true
rm -f "$TU/stub/gh-list.out"
# - **U37 PASS** — the first session finds u37b's only free sibling task blocked by inspection
#   (step 2.a, simulated by the stub calling `no-claim-mark`) and marks it; the ceiling is
#   `KAIZERO_REVIEW_WAIT` (unset, unbounded) rather than `KAIZERO_DEPENDENCY_WAIT`, the
#   status line is the one `wait_for_reviews` shares, and only the poll-tick sync — not a human —
#   flips u37a's box, changing `no_claim_signature` and ending the park; the very next session
#   claims u37b, with no claude launched while it was blocked.

# U38 — absence checks: the pre-launch forge probe and the review-park poll tick share one auth-status literal (BUG-047), and `wait_for_dependency_clear` is unaffected under `--local-merge`
insideForge=$(sed -n "$(grep -n '^# --- forge' "$REPO/kaizero.sh" | cut -d: -f1),$(grep -n '^# --- end forge' "$REPO/kaizero.sh" | cut -d: -f1)p" "$REPO/kaizero.sh" | grep -cF '"$FORGE"')
check "U38 case-dispatch sites inside the forge section (mr_list + mr_create)" "$insideForge" "2"
check "U38 auth-status literal call sites in the whole file (doctor's check 5 + the shared forge_auth_ok helper)" "$(grep -c '"\$FORGE" auth status --hostname' "$REPO/kaizero.sh")" "2"
check "U38 run_loop's pre-launch re-check goes through the shared helper" "$([ "$(grep -c 'if ! mr_network_and_auth_ok; then break; fi' "$REPO/kaizero.sh")" -ge 1 ] && echo yes || echo no)" "yes"
check "U38 wait_for_reviews's poll goes through the shared helper" "$([ "$(sed -n '/^wait_for_reviews()/,/^wait_for_dependency_clear()/p' "$REPO/kaizero.sh" | grep -c 'mr_network_and_auth_ok')" -ge 1 ] && echo yes || echo no)" "yes"
check "U38 wait_for_dependency_clear's poll goes through the shared helper" "$([ "$(sed -n '/^wait_for_dependency_clear()/,/^tasks_verb()/p' "$REPO/kaizero.sh" | grep -c 'mr_network_and_auth_ok')" -ge 1 ] && echo yes || echo no)" "yes"

# the non-MR ceiling branch is unconditional on the active flag, so --local-merge exercises the same code path
check "U38 dependency_clear plain-wait branch present" "$(sed -n '/^wait_for_dependency_clear/,/^}/p' "$REPO/kaizero.sh" | grep -c 'DEPENDENCY_WAIT_SECS.*-gt 0.*return 0')" "1"
# - **U38 PASS** — `mr_list`/`mr_create` (039d) and the doctor's own probe (039c) are joined by two
#   more call sites — the pre-launch re-check and `wait_for_reviews`'s own poll tick, now also
#   reused by `wait_for_dependency_clear`'s own poll tick (BUG-039l, see U58/U60 in Scenario U-021)
#   — but neither calls the CLI's `auth status` bare any more: BUG-047 routes all three mid-run
#   sites through the shared `mr_network_and_auth_ok` helper, which judges reachability before
#   calling `forge_auth_ok`, so the whole file holds exactly two literal `auth status --hostname`
#   call sites (the doctor's check 5, and inside `forge_auth_ok` itself) rather than one per caller.
#   The active flag `wait_for_dependency_clear` computes fresh at entry (MR mode, an unbounded or
#   set `KAIZERO_REVIEW_WAIT`, and a request actually open) gates every behaviour this slice
#   adds, including that probe, so a plain run (Scenario P, unaffected by this slice) still takes its own
#   `KAIZERO_DEPENDENCY_WAIT` ceiling and prints its own line, with no forge CLI on its path.

# U77 — a set `KAIZERO_REVIEW_WAIT` ends `wait_for_dependency_clear` at that duration, not `KAIZERO_REVIEW_WAIT`'s unbounded default, and falls through to a fresh session
mkorigin "$TU/u77code"; mkrepo "$TU/u77plan"
( cd "$TU/u77code"; git checkout -qb u77a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u77plan"; printf -- '- [\xe2\x86\x91] u77a fix thing\n- [ ] u77b needs u77a\n' > todo.md; git add todo.md; git commit -qm todo )
cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":77,"headRefOid":"aaa","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/77"}]
JSON
: > "$TU/u77launched"
cat > "$TU/bin/claude" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$TU/u77launched"
n=\$(wc -l < "$TU/u77launched" | tr -d ' ')
[ "\$n" -eq 1 ] && "$TU/u77plan/.git/zero.sh" no-claim-mark
exit 0
EOF
chmod +x "$TU/bin/claude"
P77=$(mkpath u77 claude flock git timeout gh glab jq)
start=$(date +%s)
# u77a's PR stays OPEN the whole run — nothing ever unblocks u77b through sync — so the only way
# out of the park is the ceiling itself, not the merge-driven end U37 already covers.
( cd "$TU/u77code"; PATH="$P77" KAIZERO_REVIEW_WAIT=5s KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=30s KAIZERO_MAX_LOOPS=2 timeout 50 bash "$SCRIPT" "$TU/u77plan/todo.md" > "$TU/u77.log" 2>&1 )
check "U77 exit" "$?" "0"
# the 5s ceiling ended it, not KAIZERO_DEPENDENCY_WAIT's 10m default and not an unbounded park
check "U77 elapsed" "$(e=$(( $(date +%s) - start )); [ "$e" -ge 5 ] && [ "$e" -lt 49 ] && echo yes || echo no)" "yes"
# one that marked the block, a second once the ceiling falls through to a fresh session
check "U77 launches" "$(wc -l < "$TU/u77launched" | tr -d ' ')" "2"
check "U77 shared status line" "$([ "$(grep -c 'Waiting for reviews . 1 open . 1 unchecked' "$TU/u77.log")" -ge 1 ] && echo yes || echo no)" "yes"
# nothing ever unblocked; the second launch is the ceiling falling through, not a sync-driven claim
check "U77 no wake line" "$(grep -c 'is claimable again' "$TU/u77.log")" "0"
rm -f "$TU/stub/gh-list.out"
# - **U77 PASS** — with `KAIZERO_REVIEW_WAIT` set, `wait_for_dependency_clear`'s MR-review-active
#   ceiling is that duration rather than unbounded: the park ends at ~5s even though the sibling's
#   request never resolves, and falls through to a fresh session exactly as an elapsed
#   `KAIZERO_DEPENDENCY_WAIT` ceiling always has, rather than parking indefinitely on an open
#   request the way `wait_for_reviews`'s own default (U33's `KAIZERO_REVIEW_WAIT=0`/unset cases)
#   would. Re-verified directly against `kaizero.sh` after this file's own commit: exit 0,
#   elapsed 11s, 2 launches, shared status line 1, no wake line.

# U78 — absence check: with MR mode and no box at `[↑]`, `wait_for_dependency_clear` keeps `KAIZERO_DEPENDENCY_WAIT` as its own ceiling, its own line, and no sync in its loop — matching `--local-merge` exactly
mkorigin "$TU/u78code"; mkrepo "$TU/u78plan"
( cd "$TU/u78plan"; printf -- '- [ ] u78a x\n- [ ] u78b y\n' > todo.md; git add todo.md; git commit -qm todo )
: > "$TU/u78launched"
cat > "$TU/bin/claude" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$TU/u78launched"
n=\$(wc -l < "$TU/u78launched" | tr -d ' ')
[ "\$n" -eq 1 ] && "$TU/u78plan/.git/zero.sh" no-claim-mark
exit 0
EOF
chmod +x "$TU/bin/claude"
P78=$(mkpath u78 claude flock git timeout gh glab jq)
start=$(date +%s)
( cd "$TU/u78code"; PATH="$P78" KAIZERO_WAIT_TICK=1 KAIZERO_DEPENDENCY_WAIT=3s KAIZERO_MAX_LOOPS=2 timeout 50 bash "$SCRIPT" "$TU/u78plan/todo.md" > "$TU/u78mr.log" 2>&1 )
# never rc 124
check "U78 mr exit" "$?" "0"
# KAIZERO_DEPENDENCY_WAIT's own 3s ceiling, not KAIZERO_REVIEW_WAIT's unbounded default
check "U78 mr elapsed" "$(e=$(( $(date +%s) - start )); [ "$e" -ge 3 ] && [ "$e" -lt 49 ] && echo yes || echo no)" "yes"
# relaunches after 3s
check "U78 mr launches" "$(wc -l < "$TU/u78launched" | tr -d ' ')" "2"
check "U78 mr own line, not shared" "$([ "$(grep -c 'Waiting for a claimable Task (now blocked' "$TU/u78mr.log")" -ge 1 ] && echo yes || echo no)" "yes"
# no box at ↑, so the MR-review behaviours never turn on
check "U78 mr no review line" "$(grep -c 'Waiting for reviews . 0 open' "$TU/u78mr.log")" "0"

: > "$TU/u78launched"
git -C "$TU/u78plan" reset -q --hard HEAD
start=$(date +%s)
( cd "$TU/u78code"; PATH="$P78" KAIZERO_WAIT_TICK=1 KAIZERO_DEPENDENCY_WAIT=3s KAIZERO_MAX_LOOPS=2 timeout 50 bash "$SCRIPT" --local-merge "$TU/u78plan/todo.md" > "$TU/u78lm.log" 2>&1 )
check "U78 lm exit" "$?" "0"
# the same as MR mode above
check "U78 lm elapsed" "$(e=$(( $(date +%s) - start )); [ "$e" -ge 3 ] && [ "$e" -lt 49 ] && echo yes || echo no)" "yes"
check "U78 lm launches" "$(wc -l < "$TU/u78launched" | tr -d ' ')" "2"
# - **U78 PASS** — with nothing at `↑`, the MR-review behaviours never turn on regardless of
#   MR mode: `wait_for_dependency_clear` keeps `KAIZERO_DEPENDENCY_WAIT` as its ceiling, its own
#   `waiting for a claimable Task (now blocked …)` line, and no in-loop sync — a fixture of two
#   unchecked tasks with nothing at `↑`, `KAIZERO_DEPENDENCY_WAIT=3s`, relaunches after 3s and
#   exits 0 under `timeout 25` in both MR mode and `--local-merge`, never rc 124 and no `waiting for
#   reviews · 0 open` line in either.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
