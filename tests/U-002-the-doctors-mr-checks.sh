#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=60s
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-002-the-doctors-mr-checks — checks 1-8 in turn, the host-scoped auth probe, the forge it
# resolves, and check 5's forge flag/field surface (TASK-049).
# Needs real claude: no — a stub claude on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-002-the-doctors-mr-checks
#
# run_doctor mr's own checks, each driven until it is the one that fails. Two fixture
# repositories, plan (coordination, holds the todo) and code (target) — plus a local bare origin
# for the target, which has no host, so KAIZERO_FORGE is set for the whole scenario, the
# escape hatch it exists for. Cases that assert forge selection set the fixture's origin URL to
# a matching string instead of relying on the bare remote — with no host to derive there, check
# 5's --hostname argument is empty, and the stubs accept that.

TU="$TESTROOT/U-002-the-doctors-mr-checks"; mkdir -p "$TU/bin" "$TU/stub"

# target repo cloned from a local bare origin — real, fetchable, no host. $1 = target dir.
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1" || exit 1; git config user.email t@t.t; git config user.name test )
}

# a plain coordination repo — separate from any target, holding only a todo.md. Needed by U19's
# real (non---doctor) launch: MR mode refuses a todo.md living inside the target it would also
# push from.
mkrepo(){ mkdir -p "$1"; ( cd "$1" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo '- [ ] G1 noop' > todo.md; git add todo.md; git commit -qm todo ); }

# stub claude: prints its argv (captured to see the banner precede it in the launch log) and exits.
printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\nprintf "ARGV: %%s\\n" "$*"\nexit 0\n' > "$TU/bin/claude"; chmod +x "$TU/bin/claude"

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
# prog+verb, unless `<prog>-<verb>-help.txt` exists, which is cat'd verbatim instead (a case
# proving a renamed/missing flag refuses this way). It also probes `gh pr list --json` with no
# value (exactly `pr list --json`, no fourth arg) — the real CLI prints its field list on stderr
# and exits 1, so the stub does the same, from `gh-list-json.txt` if present (a case dropping one
# field there) else the real default field list.
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
NOFORGE="$(mkpath noforge claude flock git timeout jq)"                # gh/glab both missing
NOJQ="$(mkpath nojq claude flock git timeout gh glab)"                 # jq missing, forge present

# doctor(): standalone bare --doctor from $1 (the target root) — the generic checks, the same
# origin/forge decision a launch makes, then exactly checks 1-8; no coordination repo, no todo,
# needed (none of these checks wants one).
# $PATH/$KAIZERO_FORGE inherited from the caller's env (the scenario-wide export below, or a
# per-case override prefixed onto the call: `PATH=... doctor "$dir"`).
doctor(){ ( cd "$1" || exit 1; rc=0; out=$(timeout 20 bash "$SCRIPT" --doctor 2>&1) || rc=$?; echo "$out"; echo "RC=$rc" ); }

export PATH="$ALLPATH" KAIZERO_FORGE=gh   # scenario-wide default; unset per-case for selection tests

# U3 — doctor checks fail in turn, each naming itself
mkorigin "$TU/u3"
out=$(doctor "$TU/u3"); check "U3 clean pass (everything present)" "$(echo "$out" | grep -c 'RC=0')" "1"
check "U3 check 5 prints before-call info naming the base-branch probe" "$(echo "$out" | grep -c "Testing 'main' presence on origin")" "1"

out=$(PATH="$NOFORGE" KAIZERO_FORGE=gh doctor "$TU/u3")
check "U3 forge CLI missing" "$(echo "$out" | grep -c 'gh CLI not found on PATH')" "1"

# jq missing, forge CLI present: check 4 catches it separately, same on a github- and a
# gitlab-shaped origin (one jq reshapes both forges' JSON — the forge dispatcher's job, this slice only proves
# the check itself doesn't play favorites).
out=$(PATH="$NOJQ" doctor "$TU/u3")
check "U3 jq missing (github-shaped forge default)" "$(echo "$out" | grep -c 'Jq not found on PATH')" "1"
( cd "$TU/u3" || exit 1; git remote set-url origin "https://gitlab.example.com/acme/api.git" )
out=$(PATH="$NOJQ" KAIZERO_FORGE=glab doctor "$TU/u3")
check "U3 jq missing (gitlab origin, no override)" "$(echo "$out" | grep -c 'Jq not found on PATH')" "1"
( cd "$TU/u3" || exit 1; git remote set-url origin "$TU/u3-origin.git" )
# a missing git, forge CLI, or jq each refuse with their own message; jq's check fires the same
# way regardless of which forge the origin resolves to.

# U4 — the auth probe is scoped to the origin's host
# "unrelated host": this fixture's origin is the scenario's usual local path (real, fetchable,
# no host — check 5 is called with --hostname ''), so a marker keyed to some OTHER host string
# can never match it — proving a problem on an unrelated host does not refuse THIS launch.
mkorigin "$TU/u4"
echo "broken login for some OTHER host" > "$TU/stub/gh-auth-status-unrelated.example.com"
out=$(doctor "$TU/u4")
check "U4 unrelated-host problem does not refuse" "$(echo "$out" | grep -c 'RC=0')" "1"
rm -f "$TU/stub/gh-auth-status-unrelated.example.com"

# "this host": a real hostname on the origin, so the probe IS scoped to it; check 5 runs before
# check 6 (the fetch), so this fixture's origin need not be reachable — the refusal fires first.
mkdir -p "$TU/u4b"; ( cd "$TU/u4b" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
  git commit -q --allow-empty -m init; git remote add origin "https://github.example.com/acme/api.git" )
echo "no login for THIS host" > "$TU/stub/gh-auth-status-github.example.com"
out=$(doctor "$TU/u4b")
check "U4 this-host problem refuses, naming host+fix" "$(echo "$out" | grep -c 'gh auth status failed for github.example.com — run gh auth login --hostname github.example.com')" "1"
rm -f "$TU/stub/gh-auth-status-github.example.com"

# hostless origin (a local bare repository has no host to scope the probe to): check 5 must be
# SKIPPED, not called with an empty --hostname — arm the blank-host failure marker and prove it
# is never read.
mkorigin "$TU/u4c"
echo "should never be read" > "$TU/stub/gh-auth-status-"
out=$(doctor "$TU/u4c")
check "U4 hostless origin skips check 5, still RC=0" "$(echo "$out" | grep -c 'RC=0')" "1"
check "U4 hostless skip says why" "$(echo "$out" | grep -c 'no host to scope an auth check to')" "1"
check "U4 no message carries a bare --hostname" "$(echo "$out" | grep -c -- '--hostname *$')" "0"
rm -f "$TU/stub/gh-auth-status-"

# BUG-058j: check 4's live network call prints an informational line before it runs, naming the
# host, and a short result line after — so a slow host reads as "still checking" not a silent hang.
out=$(doctor "$TU/u4b")
check "U4 check 4 prints before-call info naming the host" "$(echo "$out" | grep -c 'Testing gh authentication for github.example.com')" "1"
check "U4 check 4 prints an after-call ok result line" "$(echo "$out" | grep -c 'gh authentication for github.example.com: ok')" "1"

# absence check: no recorded auth status invocation, anywhere in this scenario so far, carries
# an empty --hostname value or omits --hostname.
check "U4 no recorded auth-status call has a blank/missing --hostname" "$(grep -h 'auth status' "$TU/stub"/*.argv 2>/dev/null | grep -Ev -- '--help' | grep -cv -- '--hostname [^ ]')" "0"
# --hostname scopes the probe: a marker for an unrelated host never refuses this launch, and a
# marker for THIS host refuses it, naming the host and the login command — never the bare auth
# status a stale or unrelated entry could otherwise misfire on; an origin with no host at all
# skips the probe instead of calling it unscoped.

# U5 — the doctor warns and continues: behind, then ahead
mkorigin "$TU/u5"
( cd "$TU/u5-seed" || exit 1; git commit -q --allow-empty -m advance )
git --git-dir="$TU/u5-origin.git" fetch -q "$TU/u5-seed" main:main   # advance the bare origin directly (no push)
out=$(doctor "$TU/u5")
check "U5 behind: informational, not a refusal" "$(echo "$out" | grep -c 'is behind origin/main')" "1"
check "U5 behind: still RC=0" "$(echo "$out" | grep -c 'RC=0')" "1"

mkorigin "$TU/u5b"
( cd "$TU/u5b" || exit 1; git commit -q --allow-empty -m 'local work' )
out=$(doctor "$TU/u5b")
check "U5 ahead: warning naming the commit count" "$(echo "$out" | grep -c 'Warning:.*has 1 commit(s) origin does not')" "1"
check "U5 ahead: still RC=0" "$(echo "$out" | grep -c 'RC=0')" "1"

# a local base sharing no commit at all with origin/<base> — an ordinary repository committed
# before anyone created its origin. merge-base has no common ancestor to report; check 7 must
# still warn (never abort with no message) and the launch must still reach RC=0.
mkdir -p "$TU/u5c-seed"; ( cd "$TU/u5c-seed" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
  git commit -q --allow-empty -m seed )
git clone -q --bare "$TU/u5c-seed" "$TU/u5c-origin.git"
mkdir -p "$TU/u5c"; ( cd "$TU/u5c" || exit 1; git init -q -b main; git config user.email t@t.t; git config user.name test
  git commit -q --allow-empty -m unrelated; git remote add origin "$TU/u5c-origin.git" )
out=$(doctor "$TU/u5c")
check "U5 no shared history: warns rather than aborting" "$(echo "$out" | grep -ic 'warning:')" "1"
check "U5 no shared history: still RC=0" "$(echo "$out" | grep -c 'RC=0')" "1"
# both directions inform/warn rather than refuse; tasks fork from origin/<base> regardless, so
# neither gates the launch; a local base sharing no commit at all with origin/<base> warns the
# same way rather than aborting the doctor with no message.

# U6 — forge selection: github, gitlab, override, and an unresolvable host
rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"
mkorigin "$TU/u6g"; ( cd "$TU/u6g" || exit 1; git remote set-url origin "https://github.com/acme/api.git" )
out=$(KAIZERO_FORGE= doctor "$TU/u6g")
check "U6 github -> gh" "$(grep -c 'auth status --hostname' "$TU/stub/gh.argv" 2>/dev/null)" "1"

rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"
mkorigin "$TU/u6l"; ( cd "$TU/u6l" || exit 1; git remote set-url origin "https://gitlab.example.com/acme/api.git" )
out=$(KAIZERO_FORGE= doctor "$TU/u6l")
check "U6 gitlab -> glab" "$(grep -c 'auth status --hostname' "$TU/stub/glab.argv" 2>/dev/null)" "1"

rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"
mkorigin "$TU/u6o"; ( cd "$TU/u6o" || exit 1; git remote set-url origin "https://git.example.com/acme/api.git" )
out=$(KAIZERO_FORGE=glab doctor "$TU/u6o")
check "U6 override -> glab regardless of host" "$(grep -c 'auth status --hostname' "$TU/stub/glab.argv" 2>/dev/null)" "1"
rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"

mkorigin "$TU/u6u"; ( cd "$TU/u6u" || exit 1; git remote set-url origin "https://git.example.com/acme/api.git" )
out=$(KAIZERO_FORGE= doctor "$TU/u6u")
check "U6 unresolvable, no override -> refuses naming host and URL" "$(echo "$out" | grep -c "Unsupported forge 'git.example.com' (origin: https://git.example.com/acme/api.git)")" "1"

mkorigin "$TU/u6p"; ( cd "$TU/u6p" || exit 1; git remote set-url origin "$TU/u6p-origin.git" )
out=$(KAIZERO_FORGE= doctor "$TU/u6p")
check "U6 local path, no override -> refuses (no host at all)" "$(echo "$out" | grep -c 'Unsupported forge')" "1"

mkorigin "$TU/u6f"; ( cd "$TU/u6f" || exit 1; git remote set-url origin "file://$TU/u6f-origin.git" )
out=$(KAIZERO_FORGE= doctor "$TU/u6f")
check "U6 file:// URL, no override -> refuses (no host at all)" "$(echo "$out" | grep -c 'Unsupported forge')" "1"

# KAIZERO_FORGE is accepted only as gh or glab — a value command -v resolves (an absolute path
# to a gh stub) must still be refused, naming the value, not taken on trust as a third forge.
rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"
mkorigin "$TU/u6v"
out=$(KAIZERO_FORGE="$TU/bin/gh" doctor "$TU/u6v")
check "U6 invalid override (a path) refuses, naming the value" "$(echo "$out" | grep -c "KAIZERO_FORGE='$TU/bin/gh'")" "1"
check "U6 invalid override never reaches all-prerequisites-OK" "$(echo "$out" | grep -c 'All prerequisites OK')" "0"
check "U6 invalid override: no fetch, no forge call recorded" "$([ -f "$TU/stub/gh.argv" ] && wc -l < "$TU/stub/gh.argv" | tr -d ' ' || echo 0)" "0"

# an insteadOf rewrite makes the judged host one the operator never configured — the refusal
# names the rewritten host AND the URL actually configured on the remote.
mkorigin "$TU/u6r"; ( cd "$TU/u6r" || exit 1
  git remote set-url origin "https://github.com/acme/api.git"
  git config "url.https://internal.proxy/gh/.insteadOf" "https://github.com/" )
out=$(KAIZERO_FORGE= doctor "$TU/u6r")
check "U6 insteadOf refusal names the rewritten host" "$(echo "$out" | grep -c 'internal.proxy')" "1"
check "U6 insteadOf refusal names the configured URL" "$(echo "$out" | grep -c 'https://github.com/acme/api.git')" "1"
# gh for a github origin, glab for a gitlab one, KAIZERO_FORGE overrides either, and a host
# that resolves to neither — including a local path and a file:// URL, which have no host at
# all — refuses as an unsupported forge, naming the host and the (reduced) URL, in the same
# words a real launch uses.

# U7 — host parsing: userinfo and :port stripped, and the credential never leaks
mkorigin "$TU/u7"; ( cd "$TU/u7" || exit 1; git remote set-url origin "git@gitlab.example.com:2222/group/sub/proj.git" )
out=$(KAIZERO_FORGE=glab doctor "$TU/u7")
check "U7 --hostname stripped of :port" "$(tail -1 "$TU/stub/glab.argv" 2>/dev/null | grep -c 'auth status --hostname gitlab.example.com$')" "1"
rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"

mkorigin "$TU/u7c"; ( cd "$TU/u7c" || exit 1; git remote set-url origin "https://user:TOKEN@github.example.com/acme/api.git" )
out=$(KAIZERO_FORGE=gh doctor "$TU/u7c")
# even git's own connection-failure stderr, once check 6's fetch to this fake host fails, never echoes it
check "U7 credential absent from every message" "$(echo "$out" | grep -c 'TOKEN')" "0"
rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"

# a bracketed IPv6 literal survives whole, port stripped only for a non-https scheme.
mkorigin "$TU/u7v6"; ( cd "$TU/u7v6" || exit 1; git remote set-url origin "ssh://git@[2001:db8::1]:22/acme/api.git" )
out=$(KAIZERO_FORGE=gh doctor "$TU/u7v6")
check "U7 IPv6 literal kept whole, port dropped" "$(tail -1 "$TU/stub/gh.argv" 2>/dev/null | grep -c 'auth status --hostname \[2001:db8::1\]$')" "1"
rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"

# https port is part of the host's identity to the CLI (glab keys hosts host:port).
mkorigin "$TU/u7ph"; ( cd "$TU/u7ph" || exit 1; git remote set-url origin "https://gitlab.example.com:8443/group/proj.git" )
out=$(KAIZERO_FORGE=glab doctor "$TU/u7ph")
check "U7 https port kept in probed host" "$(tail -1 "$TU/stub/glab.argv" 2>/dev/null | grep -c 'auth status --hostname gitlab.example.com:8443$')" "1"
rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"

# an ssh port is not part of the host's identity, unlike an https one.
mkorigin "$TU/u7ps"; ( cd "$TU/u7ps" || exit 1; git remote set-url origin "ssh://git@gitlab.example.com:2222/group/sub/proj.git" )
out=$(KAIZERO_FORGE=glab doctor "$TU/u7ps")
check "U7 ssh port dropped from probed host" "$(tail -1 "$TU/stub/glab.argv" 2>/dev/null | grep -c 'auth status --hostname gitlab.example.com$')" "1"
rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"

# a userless scp remote (no user@) still resolves its host.
mkorigin "$TU/u7s"; ( cd "$TU/u7s" || exit 1; git remote set-url origin "gitlab.example.com:acme/api.git" )
out=$(KAIZERO_FORGE=glab doctor "$TU/u7s")
check "U7 userless scp form resolves host" "$(tail -1 "$TU/stub/glab.argv" 2>/dev/null | grep -c 'auth status --hostname gitlab.example.com$')" "1"
rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"

# the forge test and --hostname are case-insensitive.
mkorigin "$TU/u7u"; ( cd "$TU/u7u" || exit 1; git remote set-url origin "https://GitHub.com/acme/api.git" )
out=$(KAIZERO_FORGE= doctor "$TU/u7u")
check "U7 uppercase host resolves gh, lowercased --hostname" "$(tail -1 "$TU/stub/gh.argv" 2>/dev/null | grep -c 'auth status --hostname github.com$')" "1"
rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"

# out-of-scope absence sweep: the doctor lists and creates no request, builds no repository of
# its own, runs exactly one fetch, and leaves the operator's own base untouched.
mkorigin "$TU/u7z"; ( cd "$TU/u7z" || exit 1; git commit -q --allow-empty -m 'local work' )
before_tip="$(git -C "$TU/u7z" rev-parse HEAD)"; before_branch="$(git -C "$TU/u7z" symbolic-ref --short HEAD)"
out=$(doctor "$TU/u7z")
after_tip="$(git -C "$TU/u7z" rev-parse HEAD)"; after_branch="$(git -C "$TU/u7z" symbolic-ref --short HEAD)"
# check 8 legitimately probes pr list --help/pr create --help/pr list --json — only a call
# WITHOUT --help and without the bare --json probe would be a real list/create.
check "U7z no request listed or created" "$(grep -Ev -- '--help|^pr list --json$' "$TU/stub/gh.argv" 2>/dev/null | grep -cE '^pr (list|create)')" "0"
check "U7z operator's own base tip untouched" "$([ "$before_tip" = "$after_tip" ] && echo yes || echo no)" "yes"
check "U7z operator's own branch untouched" "$([ "$before_branch" = "$after_branch" ] && echo yes || echo no)" "yes"
check "U7z working tree clean afterwards" "$([ -z "$(cd "$TU/u7z" && git status --porcelain)" ] && echo yes || echo no)" "yes"
# --hostname never carries a :port; no message anywhere carries the token; a bracketed IPv6
# literal survives whole; an https port is kept in the probed host, an ssh port is not; a
# userless scp remote still resolves its host; the forge test and --hostname are
# case-insensitive.


# U8 — check 5: a renamed forge flag refuses before a launch
# gh pr list's --help stops listing --json (a rename), simulated by the helpfile override — one
# flag per line, a real --help's definition-line shape, not a joined transcript. Proves check 5
# catches it before a launch, not only in .github/smoke.sh's CI-only probe.
printf -- '--repo\n--head\n--state\n--limit\n' > "$TU/stub/gh-list-help.txt"
out=$(doctor "$TU/u3")
check "U8 renamed flag refuses, naming the tool and flag" "$(echo "$out" | grep -c "gh pr list --help does not list '--json'")" "1"
check "U8 renamed flag names the fix version" "$(echo "$out" | grep -c "present in gh >= 2.18.0")" "1"
rm -f "$TU/stub/gh-list-help.txt"

out=$(doctor "$TU/u3")
check "U8 clean flag surface still passes" "$(echo "$out" | grep -c 'RC=0')" "1"
# a flag missing from the forge CLI's own --help refuses the launch, naming the tool, the
# missing flag and the CLI version that carries it; once the surface matches again, the doctor
# passes clean.

# U9 — check 5: every flag family, the gh --json field list, and forge isolation
# gh pr create loses --body-file.
printf -- '--repo\n--head\n--base\n--title\n' > "$TU/stub/gh-create-help.txt"
out=$(doctor "$TU/u3")
check "U9 gh pr create missing flag refuses" "$(echo "$out" | grep -c "gh pr create --help does not list '--body-file'")" "1"
rm -f "$TU/stub/gh-create-help.txt"

# glab mr list loses --sort — doctor run with KAIZERO_FORGE=glab against the same fixture
# (u3's origin has no host, so the override is the only way to select glab, same as U6).
printf -- '--repo\n--source-branch\n--all\n--output\n--per-page\n--order\n' > "$TU/stub/glab-list-help.txt"
out=$(KAIZERO_FORGE=glab doctor "$TU/u3")
check "U9 glab mr list missing flag refuses" "$(echo "$out" | grep -c "glab mr list --help does not list '--sort'")" "1"
check "U9 glab missing flag names the fix version" "$(echo "$out" | grep -c "present in glab >= 1.53.0")" "1"
rm -f "$TU/stub/glab-list-help.txt"

# glab mr create loses --yes.
printf -- '--repo\n--source-branch\n--target-branch\n--title\n--description\n' > "$TU/stub/glab-create-help.txt"
out=$(KAIZERO_FORGE=glab doctor "$TU/u3")
check "U9 glab mr create missing flag refuses" "$(echo "$out" | grep -c "glab mr create --help does not list '--yes'")" "1"
rm -f "$TU/stub/glab-create-help.txt"

# gh auth status loses --hostname — the one flag the live auth probe below also depends on.
printf -- '\n' > "$TU/stub/gh-auth-status-help.txt"
out=$(doctor "$TU/u3")
check "U9 gh auth status missing --hostname refuses" "$(echo "$out" | grep -c "gh auth status --help does not list '--hostname'")" "1"
rm -f "$TU/stub/gh-auth-status-help.txt"

# gh pr list --json's own field list drops headRefOid.
printf '%s\n' 'number baseRefName state url' > "$TU/stub/gh-list-json.txt"
out=$(doctor "$TU/u3")
check "U9 gh --json field list missing field refuses" "$(echo "$out" | grep -c "Gh pr list --json does not offer the 'headRefOid' field")" "1"
rm -f "$TU/stub/gh-list-json.txt"

# glab auth status loses --hostname too — same probe-ordering hazard as gh's, on the other CLI.
printf -- '\n' > "$TU/stub/glab-auth-status-help.txt"
out=$(KAIZERO_FORGE=glab doctor "$TU/u3")
check "U9 glab auth status missing --hostname refuses" "$(echo "$out" | grep -c "glab auth status --help does not list '--hostname'")" "1"
rm -f "$TU/stub/glab-auth-status-help.txt"

out=$(doctor "$TU/u3")
check "U9 clean flag surface still passes (both forges checked above)" "$(echo "$out" | grep -c 'RC=0')" "1"

# forge isolation: a glab-selected run never shells out to gh --help (or the --json probe), and
# a gh-selected run never shells out to glab --help — proven from stub call counts.
rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"
out=$(KAIZERO_FORGE=glab doctor "$TU/u3")
check "U9 glab run never calls gh --help" "$(grep -c -- '--help' "$TU/stub/gh.argv" 2>/dev/null || echo 0)" "0"
rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"
out=$(doctor "$TU/u3")
check "U9 gh run never calls glab --help" "$(grep -c -- '--help' "$TU/stub/glab.argv" 2>/dev/null || echo 0)" "0"
# each of the five flag families (gh pr list, gh pr create, glab mr list, glab mr create, gh
# --json field list) refuses on its own when the CLI's surface loses one flag or field, naming
# the CLI version that restores it; the check only ever shells out to the resolved $FORGE's own
# subcommands.

# U10 — check 5's refusal is exit-coded and leaks no later check; an unrecognized
# KAIZERO_FORGE is refused the same way
printf -- '--repo\n--head\n--state\n--limit\n' > "$TU/stub/gh-list-help.txt"
out=$(doctor "$TU/u3")
check "U10 missing flag: RC pinned nonzero" "$(echo "$out" | grep RC=)" "RC=1"
check "U10 missing flag: no 'all prerequisites OK.'" "$(echo "$out" | grep -c 'All prerequisites OK')" "0"
check "U10 missing flag: no later check's own output" "$(echo "$out" | grep -c 'auth status failed\|is behind origin\|commit(s) origin does not')" "0"
rm -f "$TU/stub/gh-list-help.txt"

# an unrecognized KAIZERO_FORGE is refused where the forge is resolved (check 3), before check
# 4 (CLI presence) even runs — never "all prerequisites OK.", whatever happens to be on PATH.
out=$(KAIZERO_FORGE=/some/path/gh doctor "$TU/u3")
check "U10 unrecognized KAIZERO_FORGE refuses" "$(echo "$out" | grep -c "KAIZERO_FORGE='/some/path/gh'")" "1"
check "U10 unrecognized KAIZERO_FORGE: no OK line" "$(echo "$out" | grep -c 'All prerequisites OK')" "0"
# a missing flag refuses with a pinned nonzero exit and prints nothing from any check after it;
# an unrecognized KAIZERO_FORGE override is refused at resolution time, not silently
# defaulted through to "all prerequisites OK."

# U11 — check 5 runs before every live probe, in both directions
# both broken: the flag message wins, the auth message never appears.
printf -- '--repo\n--head\n--state\n--limit\n' > "$TU/stub/gh-list-help.txt"
echo "dead token" > "$TU/stub/gh-auth-status-github.example.com"   # u4b's origin host is github.example.com
out=$(doctor "$TU/u4b")
check "U11 both broken: refuses with the flag message" "$(echo "$out" | grep -c "gh pr list --help does not list '--json'")" "1"
check "U11 both broken: never reaches the auth message" "$(echo "$out" | grep -c 'auth status failed')" "0"
rm -f "$TU/stub/gh-list-help.txt"

# flags clean, only the token dead: the refusal moves to the auth message, proving check 5
# completed cleanly (no flag message, no hang) before check 6 is what actually failed — and,
# since check 5 shells out only to --help/--json on the stub, this is also the proof that the
# check itself needs no network or live auth of its own to complete.
out=$(doctor "$TU/u4b")
check "U11 clean flags, dead token: auth message only" "$(echo "$out" | grep -c 'auth status failed')" "1"
check "U11 clean flags, dead token: no flag message" "$(echo "$out" | grep -c 'does not list')" "0"
rm -f "$TU/stub/gh-auth-status-github.example.com"
# a fixture with both the token and a flag broken refuses on the flag, never the auth message;
# the same fixture with only the token broken refuses on auth — check 5 always completes first,
# and needs neither network nor a live auth call to do it.

# U12 — a clean flag surface still ends "all prerequisites OK.", gh-selected and glab-selected
# alike
out=$(doctor "$TU/u3")
check "U12 clean flag surface (gh selected): RC pinned" "$(echo "$out" | grep RC=)" "RC=0"
check "U12 clean flag surface (gh selected): still OK" "$(echo "$out" | grep -c 'All prerequisites OK')" "1"

out=$(KAIZERO_FORGE=glab doctor "$TU/u3")
check "U12 clean flag surface (glab selected): RC pinned" "$(echo "$out" | grep RC=)" "RC=0"
check "U12 clean flag surface (glab selected): still OK" "$(echo "$out" | grep -c 'All prerequisites OK')" "1"
# RC=0, "all prerequisites OK." either way, pinned rather than merely "not refused."

# U13 — the doctor's flag literals are drift-checked against mr_list/mr_create's own real calls,
# read straight out of kaizero.sh
# Not a hand-copied string in this test file: both sides come from grepping the live script, so a
# flag added to mr_list/mr_create without a matching update to assert_forge_flags (or vice versa)
# turns this red.
extract(){ grep -oE -- '--[a-z-]+' <<<"$1" | sort -u; }
doc_gh_list=$(extract "$(grep 'assert_forge_flag "\$gh_list_help" "gh pr list"' "$REAL_SCRIPT")")
real_gh_list=$(extract "$(grep -A2 'gh pr list --repo' "$REAL_SCRIPT" | grep -v assert_forge_flag)")
check "U13 gh pr list: doctor's flags match mr_list's real call" "$([ "$doc_gh_list" = "$real_gh_list" ] && echo same || echo DIFFER)" "same"

doc_gh_create=$(extract "$(grep 'assert_forge_flag "\$gh_create_help" "gh pr create"' "$REAL_SCRIPT")")
real_gh_create=$(extract "$(grep -A1 'gh pr create --repo' "$REAL_SCRIPT" | grep -v assert_forge_flag)")
check "U13 gh pr create: doctor's flags match mr_create's real call" "$([ "$doc_gh_create" = "$real_gh_create" ] && echo same || echo DIFFER)" "same"

doc_glab_list=$(extract "$(grep 'assert_forge_flag "\$glab_list_help" "glab mr list"' "$REAL_SCRIPT")")
real_glab_list=$(extract "$(grep -A1 'glab mr list --repo' "$REAL_SCRIPT" | grep -v assert_forge_flag)")
check "U13 glab mr list: doctor's flags match mr_list's real call" "$([ "$doc_glab_list" = "$real_glab_list" ] && echo same || echo DIFFER)" "same"

doc_glab_create=$(extract "$(grep 'assert_forge_flag "\$glab_create_help" "glab mr create"' "$REAL_SCRIPT")")
real_glab_create=$(extract "$(grep -A2 'glab mr create --repo' "$REAL_SCRIPT" | grep -v assert_forge_flag)")
check "U13 glab mr create: doctor's flags match mr_create's real call" "$([ "$doc_glab_create" = "$real_glab_create" ] && echo same || echo DIFFER)" "same"

doc_auth=$(extract "$(grep 'assert_forge_flag "\$gh_auth_help" "gh auth status"' "$REAL_SCRIPT")")
real_auth=$(extract "$(grep '"\$FORGE" auth status --hostname "\$ORIGIN_HOST" >/dev/null 2>&1 \\$' "$REAL_SCRIPT")")
check "U13 auth probe: doctor's flag matches the live auth probe's own flag" "$([ "$doc_auth" = "$real_auth" ] && echo same || echo DIFFER)" "same"
# every flag family the doctor asserts is read straight out of the same script's real call
# sites, not re-typed by hand in this file; the two sides can only stay "same" by actually being
# kept in sync.

# U14 — each subcommand's --help is spawned at most once per doctor run
rm -f "$TU/stub/gh.argv"
out=$(doctor "$TU/u3")
check "U14 'pr list --help' spawned exactly once" "$(grep -cx 'pr list --help' "$TU/stub/gh.argv")" "1"
check "U14 'pr create --help' spawned exactly once" "$(grep -cx 'pr create --help' "$TU/stub/gh.argv")" "1"
check "U14 'auth status --help' spawned exactly once" "$(grep -cx 'auth status --help' "$TU/stub/gh.argv")" "1"
check "U14 'pr list --json' spawned exactly once" "$(grep -cx 'pr list --json' "$TU/stub/gh.argv")" "1"
# one --help per subcommand, one --json probe, no re-spawn per flag.

# U15 — a flag named only in a description or EXAMPLES line, never on its own definition line,
# does not satisfy the check
cat > "$TU/stub/gh-create-help.txt" <<'HELP'
Usage: gh pr create [flags]

Create a pull request

Flags:
  -R, --repo string     Select another repository
  -H, --head branch     Head branch
  -B, --base branch     Target branch
  -t, --title string    Title

EXAMPLES
  # create a pull request with a body from a file
  $ gh pr create --body-file changes.md
HELP
out=$(doctor "$TU/u3")
check "U15 flag mentioned only in EXAMPLES does not satisfy the check" "$(echo "$out" | grep -c "gh pr create --help does not list '--body-file'")" "1"
rm -f "$TU/stub/gh-create-help.txt"
# a substring match would have let this pass; the definition-line match refuses it.

# U16 — a help transcript over 64 KiB that does list the flag still passes: no SIGPIPE/pipefail
# false refusal
{ printf '%s\n\n' 'Usage: gh pr list [flags]'
  head -c 80000 /dev/zero | tr '\0' 'x'; printf '\n'
  printf '  %s\n' --repo --head --state --limit --json
} > "$TU/stub/gh-list-help.txt"
check "U16 fixture actually exceeds 64KiB" "$([ "$(wc -c < "$TU/stub/gh-list-help.txt")" -gt 65536 ] && echo yes || echo no)" "yes"
out=$(doctor "$TU/u3")
check "U16 large help transcript that lists every flag still passes" "$(echo "$out" | grep -c 'RC=0')" "1"
rm -f "$TU/stub/gh-list-help.txt"
# the herestring match survives a help text past the SIGPIPE-under-pipefail threshold a piped
# grep -q would false-refuse on.

# U17 — forge isolation, by total argv-log line count, not only a --help count
linecount(){ [ -f "$1" ] && wc -l < "$1" || echo 0; }
rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"
out=$(KAIZERO_FORGE=glab doctor "$TU/u3")
check "U17 glab-selected run: gh stub argv total lines" "$(linecount "$TU/stub/gh.argv")" "0"
rm -f "$TU/stub/gh.argv" "$TU/stub/glab.argv"
out=$(doctor "$TU/u3")
check "U17 gh-selected run: glab stub argv total lines" "$(linecount "$TU/stub/glab.argv")" "0"
# the unselected forge's stub sees zero lines at all, not merely zero --help lines — a leaked
# pr list --json-shaped probe would show up here even if it dodged a --help-only count.

# U18 — a missing-flag message names the live MIN_GH_VERSION constant, not a hardcoded literal
minver=$(grep -oE 'MIN_GH_VERSION="[^"]+"' "$REAL_SCRIPT" | grep -oE '[0-9.]+')
printf -- '--repo\n--head\n--state\n--limit\n' > "$TU/stub/gh-list-help.txt"
out=$(doctor "$TU/u3")
check "U18 refusal names the live MIN_GH_VERSION constant" "$(echo "$out" | grep -c "present in gh >= $minver")" "1"
rm -f "$TU/stub/gh-list-help.txt"
# the message is built from $MIN_GH_VERSION itself; raising the constant would raise this
# assertion's own expectation too, with no test edit.

# U19 — the same refusal fires on a real MR-mode launch, not only under --doctor
mkorigin "$TU/u19real"; mkrepo "$TU/u19plan"
printf -- '--repo\n--head\n--state\n--limit\n' > "$TU/stub/gh-list-help.txt"
( cd "$TU/u19real" || exit 1; timeout 20 bash "$SCRIPT" "$TU/u19plan/todo.md" > "$TU/u19.log" 2>&1 ); rc=$?
check "U19 real launch (not --doctor) refuses on missing flag" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "U19 real launch: names the flag" "$(grep -c "gh pr list --help does not list '--json'" "$TU/u19.log")" "1"
check "U19 real launch: starts no agent" "$(grep -c 'ARGV:' "$TU/u19.log")" "0"
rm -f "$TU/stub/gh-list-help.txt"
# a real launch runs run_doctor mr too, and refuses before claude is ever spawned — the check is
# not --doctor-only.
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
