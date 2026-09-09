#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=135s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-005-the-emitted-zero-sh — the four baked values, %q-escaped like their neighbours, and the
# emitter both modes share.
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-005-the-emitted-zero-sh
#
# The text a launch writes into .git/zero.sh: exactly four values baked into it, %q-escaped like
# their neighbours and written in both modes, and one emitter behind both prompts whose output
# differs only on those four lines. Two fixture repositories, plan (coordination, holds the
# todo) and code (target) — plus a local bare origin for the target, which has no host, so
# KAIZERO_FORGE is set for the whole scenario, the escape hatch it exists for.

TU="$TESTROOT/U-005-the-emitted-zero-sh"; mkdir -p "$TU/bin" "$TU/stub"
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

# U12 — the four baked values, %q escaping, and TB
mkrepo "$TU/u12code"; mkrepo "$TU/u12plan"; mktodo "$TU/u12plan"
out=$( ( cd "$TU/u12code" || exit 1; KAIZERO_TEST_EMIT=1 timeout 20 bash "$SCRIPT" --local-merge "$TU/u12plan/todo.md" 2>&1 ) )
Z="$TU/u12plan/.git/zero.sh"
check "U12 no-mr MR_MODE=0" "$(grep -c '^MR_MODE=0' "$Z")" "1"
check "U12 no-mr FORGE=''" "$(grep -c "^FORGE=''" "$Z")" "1"
check "U12 no-mr ORIGIN_URL=''" "$(grep -c "^ORIGIN_URL=''" "$Z")" "1"
check "U12 no-mr TB=refs/heads" "$(grep -c '^TB=refs/heads/main' "$Z")" "1"

mkorigin "$TU/u12t"
mkrepo "$TU/u12plan2"; mktodo "$TU/u12plan2"
( cd "$TU/u12t" || exit 1; git remote set-url origin "https://git.example.com/a b/it's.git" )
out=$( ( cd "$TU/u12t" || exit 1; KAIZERO_TEST_EMIT=1 KAIZERO_FORGE=gh timeout 20 bash "$SCRIPT" "$TU/u12plan2/todo.md" 2>&1 ) )
Z2="$TU/u12plan2/.git/zero.sh"
check "U12 mr MR_MODE=1" "$(grep -c '^MR_MODE=1' "$Z2")" "1"
check "U12 mr TB=refs/remotes" "$(grep -c '^TB=refs/remotes/origin/main' "$Z2")" "1"
check "U12 mr FORGE=gh" "$(grep -c '^FORGE=gh' "$Z2")" "1"
# the doctor never ran to populate it
check "U12 mr under TEST_EMIT: ORIGIN_URL='' " "$(grep -c "^ORIGIN_URL=''" "$Z2")" "1"
check "U12 emitted zero.sh parses" "$(bash -n "$Z2" 2>&1; echo $?)" "0"
check "U12 emitted zero.sh shellchecks clean" "$( "$SHELLCHECK" -e SC2016 "$Z2" >/dev/null 2>&1; echo $?)" "0"
# exactly four values, %q-escaped like their neighbours, written in both modes (empty
# FORGE/ORIGIN_URL under --local-merge); TB is refs/heads/<base> under the flag and
# refs/remotes/origin/<base> without it; a space-and-quote-carrying origin still parses and
# lints clean.

# U19 — the shared emitter: zero.sh differs only on the four baked lines
mkorigin "$TU/u19"; mkrepo "$TU/u19plan"; mktodo "$TU/u19plan"
( cd "$TU/u19" || exit 1; KAIZERO_MAX_LOOPS=1 timeout 20 bash "$SCRIPT" --local-merge "$TU/u19plan/todo.md" -t x >/dev/null 2>&1 )
cp "$TU/u19plan/.git/zero.sh" "$TU/u19-zero-nomr.sh"

( cd "$TU/u19" || exit 1; KAIZERO_FORGE=gh KAIZERO_MAX_LOOPS=1 timeout 20 bash "$SCRIPT" "$TU/u19plan/todo.md" -t x >/dev/null 2>&1 )
cp "$TU/u19plan/.git/zero.sh" "$TU/u19-zero-mr.sh"

diffout=$(diff "$TU/u19-zero-nomr.sh" "$TU/u19-zero-mr.sh")
diffvars=$(echo "$diffout" | grep -oE '^[<>] (MR_MODE|FORGE|TB|ORIGIN_URL)=' | sed -E 's/^[<>] //;s/=$//' | sort -u | tr '\n' ' ')
check "U19 differs only on the 4 baked lines" "$diffvars" "FORGE MR_MODE ORIGIN_URL TB "
check "U19 diff is exactly 8 lines (4 vars x old+new)" "$(echo "$diffout" | grep -c '^[<>]')" "8"
check "U19 both parse" "$(bash -n "$TU/u19-zero-nomr.sh" && bash -n "$TU/u19-zero-mr.sh"; echo $?)" "0"
# build_zero_prompt and build_mr_prompt emit byte-identical zero.sh apart from the four values
# the doctor bakes; the shared emitter (write_zero_sh) never drifts into two copies as the
# prompts diverge.

# U20 — %q escaping proven on a launch whose doctor actually ran
# a real, fetchable origin whose path carries a space and a single quote — not KAIZERO_TEST_EMIT,
# so the doctor actually runs and ORIGIN_URL is its own check-2 read, not left empty.
mkdir -p "$TU/u20 se'ed"; ( cd "$TU/u20 se'ed" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init )
git clone -q --bare "$TU/u20 se'ed" "$TU/u20 or'igin.git"
git clone -q "$TU/u20 or'igin.git" "$TU/u20t"
( cd "$TU/u20t" || exit 1; git config user.email t@t.t; git config user.name test )
mkrepo "$TU/u20plan"; mktodo "$TU/u20plan"
# a gh stub whose --help lists everything check 8 asserts — U-005's own gh stub
# predates that check and would otherwise refuse this launch on an unrelated flag mismatch.
mkdir -p "$TU/u20bin"
printf '#!/usr/bin/env bash\nif [ "$3" = --help ] || [ "$4" = --help ]; then printf "%%s\\n" --repo --head --state --limit --json --base --title --body-file --hostname; exit 0; fi\nif [ "$1 $2 $3" = "pr list --json" ]; then printf "number headRefOid baseRefName state url\\n" >&2; exit 1; fi\nexit 0\n' > "$TU/u20bin/gh"
chmod +x "$TU/u20bin/gh"
( cd "$TU/u20t" || exit 1; PATH="$TU/u20bin:$PATH" KAIZERO_FORGE=gh KAIZERO_MAX_LOOPS=1 timeout 20 bash "$SCRIPT" "$TU/u20plan/todo.md" -t x >/dev/null 2>&1 )
Z3="$TU/u20plan/.git/zero.sh"
expected="$(cd "$TU/u20t" && git remote get-url origin)"
baked="$(grep '^ORIGIN_URL=' "$Z3" | sed 's/^ORIGIN_URL=//')"
eval "gotval=$baked"
# shellcheck disable=SC2154
[ "$gotval" = "$expected" ]
# shellcheck disable=SC2319
check "U20 baked ORIGIN_URL is byte-identical to the origin's reduced URL" "$?" "0"
check "U20 emitted zero.sh parses" "$(bash -n "$Z3" 2>&1; echo $?)" "0"
check "U20 emitted zero.sh shellchecks clean" "$( "$SHELLCHECK" -e SC2016 "$Z3" >/dev/null 2>&1; echo $?)" "0"
# a doctor-ran launch bakes ORIGIN_URL with %q, byte-identical when sourced back, and the
# emitted script still parses and shellchecks clean with a space and a quote in it.

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
