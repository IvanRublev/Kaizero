#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=85s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-006-the-mr-prompts-own-steps — step d.'s forge-specific templates, and the inverted step
# 2.a.iv where only [x] unblocks.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-006-the-mr-prompts-own-steps
#
# The two steps the MR prompt does not share with the local-merge one: step d., whose wording
# and templates follow the forge and whose $wt is the task worktree rather than $TARGET_ROOT or
# a remote, and step 1's legend with the inverted step 2.a.iv, where [↑], [⛔] and [?] are all
# already spoken for and only [x] unblocks a dependent task. Two fixture repositories, plan
# (coordination, holds the todo) and code (target) — plus a local bare origin for the target,
# which has no host, so KAIZERO_FORGE is set for the whole scenario, the escape hatch it
# exists for.

TU="$TESTROOT/U-006-the-mr-prompts-own-steps"; mkdir -p "$TU/bin" "$TU/stub"
# MR mode is the default, so every fixture target needs an origin a forge resolves
# from or the launch refuses before the case's own subject is reached. A github URL, never fetched
# (TEST_EMIT skips the doctor; the real-doctor cases use mkorigin instead).
mkrepo(){ mkdir -p "$1"; ( cd "$1" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git remote add origin "https://github.com/acme/$(basename "$1").git" ); }
mktodo(){ ( cd "$1" || exit 1; echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }

# target repo cloned from a local bare origin — real, fetchable, no host. $1 = target dir.
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1" || exit 1; git config user.email t@t.t; git config user.name test )
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

# U17 — MR prompt step d.: forge-specific templates, one whole block, $twt (not $TARGET_ROOT/remote)
mkorigin "$TU/u17gh"; mkrepo "$TU/u17ghplan"; mktodo "$TU/u17ghplan"
outgh=$( ( cd "$TU/u17gh" || exit 1; KAIZERO_FORGE=gh KAIZERO_MAX_LOOPS=1 timeout 20 bash "$SCRIPT" "$TU/u17ghplan/todo.md" -t x 2>&1 ) )
# want >=4
check "U17 gh: pull request wording" "$([ "$(echo "$outgh" | grep -c 'pull request')" -ge 4 ] && echo yes || echo no)" "yes"
check "U17 gh: no merge request wording" "$(echo "$outgh" | grep -c 'merge request')" "0"
check "U17 gh: no merge (pull) phrase" "$(echo "$outgh" | grep -c 'merge (pull) request')" "0"
check "U17 gh: lists github template path" "$(echo "$outgh" | grep -c '.github/PULL_REQUEST_TEMPLATE.md')" "1"
check "U17 gh: no gitlab template path" "$(echo "$outgh" | grep -c '.gitlab/merge_request')" "0"
# want >=1
check "U17 gh: mr-body-path named" "$([ "$(echo "$outgh" | grep -c 'mr-body-path task_id')" -ge 1 ] && echo yes || echo no)" "yes"
check "U17 gh: \$wt named for template search" "$(echo "$outgh" | grep -c 'task worktree \$wt')" "1"
check "U17 gh: no @@ placeholder left" "$(echo "$outgh" | grep -c '@@')" "0"

mkorigin "$TU/u17gl"; mkrepo "$TU/u17glplan"; mktodo "$TU/u17glplan"
outgl=$( ( cd "$TU/u17gl" || exit 1; KAIZERO_FORGE=glab KAIZERO_MAX_LOOPS=1 timeout 20 bash "$SCRIPT" "$TU/u17glplan/todo.md" -t x 2>&1 ) )
check "U17 glab: merge request wording" "$([ "$(echo "$outgl" | grep -c 'merge request')" -ge 4 ] && echo yes || echo no)" "yes"
check "U17 glab: no pull request wording" "$(echo "$outgl" | grep -c 'pull request')" "0"
check "U17 glab: lists gitlab template path" "$(echo "$outgl" | grep -c '.gitlab/merge_request_templates')" "1"
check "U17 glab: no github template path" "$(echo "$outgl" | grep -c '.github/PULL_REQUEST_TEMPLATE')" "0"
check "U17 glab: no @@ placeholder left" "$(echo "$outgl" | grep -c '@@')" "0"
# a github origin's prompt says "pull request" throughout, names only the
# .github/…PULL_REQUEST_TEMPLATE… paths, and points the template search at $wt; a gitlab origin's
# says "merge request" throughout and names only the .gitlab/merge_request_template… paths;
# neither carries the other forge's wording or paths, and no @@…@@ placeholder survives.

# U18 — MR prompt step 1 legend, the inverted step 2.a.iv, and step e.'s wording
mkorigin "$TU/u18"; mkrepo "$TU/u18plan"; mktodo "$TU/u18plan"
out18=$( ( cd "$TU/u18" || exit 1; KAIZERO_FORGE=gh KAIZERO_MAX_LOOPS=1 timeout 20 bash "$SCRIPT" "$TU/u18plan/todo.md" -t x 2>&1 ) )
# legend and iv's own blockers
check "U18 legend+iv name [↑]" "$(echo "$out18" | grep -c '\[↑\]')" "2"

check "U18 legend+iv name [⛔]" "$(echo "$out18" | grep -c '\[⛔\]')" "2"
check "U18 legend+iv name [?]" "$(echo "$out18" | grep -c '\[?\]')" "2"
check "U18 2.a.iv: only [x] unblocks" "$(echo "$out18" | grep -c 'Only .\[x\]. unblocks')" "1"
check "U18 2.a.iv: zero-prompt wording gone" "$(echo "$out18" | grep -c 'anything but .\[ \]. never blocks')" "0"
check "U18 step e names zero.sh mr" "$(echo "$out18" | grep -c 'zero.sh mr task_id')" "1"
check "U18 step e: no symbol to choose" "$(echo "$out18" | grep -c 'no symbol to choose')" "1"
check "U18 step e: exit 5 routing kept" "$(echo "$out18" | grep -c 'exit 5 → do what stderr says, retry once, then stop')" "1"
check "U18 step e: exit 2 is a stop, reported" "$(echo "$out18" | grep -c 'STOP IMMEDIATELY and report it')" "1"
check "U18 step e: not read as a conflict" "$(echo "$out18" | grep -c 'CODE CONFLICT')" "0"
check "U18 step e: no worktree hunt" "$(echo "$out18" | grep -c 'go looking for a worktree')" "1"
# the legend names [↑], [⛔] and [?] all as already spoken for and not claimable, and step 2.a.iv
# spells the same three symbols again among its own blockers; step 2.a.iv unblocks on [x] alone
# and drops the zero prompt's "anything but [ ]" wording; step e. names zero.sh mr with no
# symbol, keeps the 0/5 exit routing, and reads exit 2 as a stop to report rather than a
# conflict to resolve.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
