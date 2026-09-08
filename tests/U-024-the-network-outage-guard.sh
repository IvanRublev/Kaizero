#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=15m
# KAIZERO_TEST_ISOLATED=1 — flaky under concurrency (internal producer/consumer timing race, not a shared-file collision): see TEST.md Dispatch instruction
# cd is safe throughout: test-setup.sh's own cd() override hard-exits on failure. The sourced
# test-setup.sh/test-teardown-*.sh are resolved at runtime, nothing to follow statically.
# shellcheck disable=SC2164,SC1091,SC2103
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-024-the-network-outage-guard — origin unreachable at a mid-run forge re-check parks instead
# of blaming the token, and resumes on its own once origin answers again (BUG-047).
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-024-the-network-outage-guard
# Wall-clock budget: its longest Run command is `timeout 80`; allow at least 15 minutes for the
# whole scenario (14 cases, several with short deliberate parks)
#
# Every case reaches the real run_loop — origin intact through the launch doctor (a real,
# fetchable, no-host bare origin from mkorigin), the outage arriving only after the run is up, so
# a case tests the mid-run guard, never the doctor. mktodo/mkrepo build the coordination side; a
# controllable stub claude and stub gh on a scenario-scoped PATH (mkpath) stand in for the rest,
# the same shape U-021 uses.
#
# Two distinct "unreachable" shapes are used on purpose, matched to what each case actually needs
# to prove:
# - Git-transport-down: `git remote set-url origin` (or --push) to https://outage.invalid/... —
#   .invalid never resolves (RFC 2606), so `git ls-remote` fails fast and offline with "Could not
#   resolve host", a message looks_like_network_error recognizes. Restoring the real local
#   bare-repo URL "answers again".
# - Forge-API-down: git transport stays on the real, reachable local bare origin; only the stub
#   gh's `auth status` is made to fail, with a message the case controls via
#   $TU/stub/gh-auth-fail (present = fail with that file's content as stderr; absent = pass). A
#   network-shaped message (dial tcp: i/o timeout) drives wait_for_network forge; a
#   credentials-shaped one (Bad credentials) drives the permanent token stop instead — same
#   distinction BUG-047 exists to draw.
#
# A third fixture, a local path that does not exist, produces git's generic "does not appear to
# be a git repository" — a message looks_like_network_error does NOT match, so
# network_reachable reads it as rc 3 (credentials-shaped, not network). That is deliberate: it is
# the fixture for the "private origin" token case (the reachability probe itself fails, but not
# on the network), never for a case that expects a park.

### Setup
TU="$TESTROOT/U-024-the-network-outage-guard"; mkdir -p "$TU/bin" "$TU/stub"
mkrepo(){ mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init ); }
mktodo(){ ( cd "$1"; echo "- [ ] $2 fix thing" > todo.md; git add todo.md; git commit -qm todo ); }

# target repo cloned from a local bare origin — real, fetchable, no host. $1 = target dir.
mkorigin(){
  mkdir -p "$1-seed"; ( cd "$1-seed"; git init -q -b main; git config user.email t@t.t; git config user.name test
    echo x > f; git add f; git commit -qm init )
  git clone -q --bare "$1-seed" "$1-origin.git"
  git clone -q "$1-origin.git" "$1"
  ( cd "$1"; git config user.email t@t.t; git config user.name test )
}

# stub claude: records that it ran, never actually claims/implements — every case here is about
# the guard around a launch, never a landing. $1 = a tag so each case gets its own launch counter.
mkclaude(){
  # run_doctor's own preflight (`command -v claude` / `claude -v`, kaizero.sh check 2) must not
  # count as a session launch — it runs once before the loop below ever starts, and every case
  # here times its origin-corruption/signal off the FIRST REAL launch.
  printf '#!/usr/bin/env bash\n[ "${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }\necho launched >> "%s/%slaunched"\nexit 0\n' "$TU" "$1" > "$TU/bin/claude-$1"
  chmod +x "$TU/bin/claude-$1"; : > "$TU/${1}launched"
}

# stub gh: `auth status` fails, with $TU/stub/gh-auth-fail's content on stderr, iff that file
# exists; absent = pass. One switch, flipped by a case to simulate a token/API problem without
# touching the real (reachable) git transport at all. `pr list --json` and other verbs default to
# a harmless success so a case that never touches them needs no further stubbing. `pr list --help`/
# `pr create --help` answer with the exact flags run_doctor's check 8 (kaizero.sh's
# assert_forge_flag) greps for, and a bare `pr list --json` (no field list) fails with the field
# names check 8 also greps for on stderr — both real gh's own documented behaviour, needed so a
# real launch's doctor pass here, not the fixture, is what every case below actually tests.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "$1 $2 $3" = "auth status --help" ]; then printf "%s\n" --hostname; exit 0; fi' \
  'if [ "$1 $2" = "auth status" ]; then' \
  '  if [ -f "'"$TU"'/stub/gh-auth-fail" ]; then cat "'"$TU"'/stub/gh-auth-fail" >&2; exit 1; fi' \
  '  exit 0' \
  'fi' \
  'if [ "$1 $2 $3" = "pr list --help" ]; then printf "%s\n" --repo --head --state --limit --json; exit 0; fi' \
  'if [ "$1 $2 $3" = "pr create --help" ]; then printf "%s\n" --repo --head --base --title --body-file; exit 0; fi' \
  'if [ "$1 $2 $3" = "pr list --json" ] && [ -z "${4:-}" ]; then' \
  '  echo "Unknown JSON field: \"\"" >&2' \
  '  echo "Available fields:" >&2' \
  '  echo "  number headRefOid baseRefName state url" >&2' \
  '  exit 1' \
  'fi' \
  'if [ "$1 $2" = "pr list" ]; then cat "'"$TU"'/stub/gh-list.out" 2>/dev/null || echo "[]"; exit 0; fi' \
  'exit 0' \
  > "$TU/bin/gh"
chmod +x "$TU/bin/gh"

mkpath(){
  local d="$TU/path-$1" tag="$2"; shift 2; mkdir -p "$d"
  for t in "$@"; do
    case "$t" in
      claude) cp "$TU/bin/claude-$tag" "$d/claude" ;;
      gh)     cp "$TU/bin/gh" "$d/gh" ;;
      *)      p=$(command -v "$t") || { echo "REFUSING: '$t' not found — cannot build $d" >&2; exit 1; }
              ln -sf "$p" "$d/$t" ;;
    esac
  done
  printf '%s:/usr/bin:/bin' "$d"
}

# stop a background kaizero.sh run cleanly: TERM, wait briefly, KILL if it ignored that.
stopwait(){ local pid=$1; kill -TERM "$pid" 2>/dev/null
  local i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null; true; }

export KAIZERO_FORGE=gh

### U60 — origin unreachable at a mid-run guard parks with the network wait line, the probe's own cause, and a heartbeat — launches nothing while parked, then resumes and launches on its own, no relaunch by hand
mkorigin "$TU/u60code"; mkrepo "$TU/u60plan"; mktodo "$TU/u60plan" u60a
REALORIGIN="$(git -C "$TU/u60code" remote get-url origin)"
mkclaude u60
P60=$(mkpath u60 u60 claude flock git timeout gh jq)
cd "$TU/u60code"
PATH="$P60" KAIZERO_WAIT_TICK=1 KAIZERO_LOG_TICK=2 KAIZERO_REVIEW_POLL=2s bash "$SCRIPT" "$TU/u60plan/todo.md" > "$TU/u60.log" 2>&1 &
WPID=$!
# let the FIRST pass launch on the real (reachable) origin — proves the doctor passed and the
# guard itself, not the doctor, is what this case is about.
i=0; while [ "$(wc -l < "$TU/u60launched" | tr -d ' ')" -lt 1 ] && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
check "U60 first session launched before any outage" "$([ "$(wc -l < "$TU/u60launched" | tr -d ' ')" -ge 1 ] && echo yes || echo no)" "yes"
# now cut the network — a real DNS failure, offline-safe, matches looks_like_network_error.
git -C "$TU/u60code" remote set-url origin "https://outage.invalid/u60code.git"
i=0; while ! grep -q 'unreachable — waiting' "$TU/u60.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
check "U60 wait line printed" "$([ "$(grep -c 'unreachable — waiting' "$TU/u60.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U60 no auth status blamed" "$(grep -c 'auth status failed' "$TU/u60.log")" "0"
LAUNCHED_AT_PARK=$(wc -l < "$TU/u60launched" | tr -d ' ')
check "U60 probe's own cause printed" "$([ "$(grep -c 'Could not resolve host' "$TU/u60.log")" -ge 1 ] && echo yes || echo no)" "yes"
# hold the outage open past one KAIZERO_LOG_TICK (2s here) to prove the piped log heartbeats on
# that cadence, with no immediate duplicate right behind the opening announcement.
sleep 3
check "U60 no immediate 0s duplicate" "$(grep -c 'unreachable . 0s' "$TU/u60.log")" "0"
check "U60 heartbeat after one LOG_TICK" "$([ "$(grep -c 'unreachable .' "$TU/u60.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U60 no launch while parked" "$(wc -l < "$TU/u60launched" | tr -d ' ')" "$LAUNCHED_AT_PARK"
git -C "$TU/u60code" remote set-url origin "$REALORIGIN"
i=0; while ! grep -q 'reachable again' "$TU/u60.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
i=0; while [ "$(wc -l < "$TU/u60launched" | tr -d ' ')" -le "$LAUNCHED_AT_PARK" ] && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
check "U60 resume line printed" "$([ "$(grep -c 'reachable again' "$TU/u60.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U60 claude launched after" "$([ "$(wc -l < "$TU/u60launched" | tr -d ' ')" -gt "$LAUNCHED_AT_PARK" ] && echo yes || echo no)" "yes"
stopwait "$WPID"
# U60 PASS — the mid-run guard reads a DNS-shaped outage as transient and parks in
# wait_for_network instead of blaming the token: the wait line names origin and the poll cadence,
# the probe's own stderr ("Could not resolve host …") prints with it, no auth status failed line,
# no session launched while it is down, and — because the log is piped to a file — the
# announcement is not immediately followed by a `· 0s` duplicate and a heartbeat lands once ~20s
# (LOG_TICK) have passed. Once origin answers again the guard prints the resume line and the very
# next pass launches a session on its own — the outage never needed a human to relaunch anything.

### U61 — an outage that clears in well under one poll interval resumes promptly, not a full `KAIZERO_REVIEW_POLL` later
mkorigin "$TU/u61code"; mkrepo "$TU/u61plan"; mktodo "$TU/u61plan" u61a
REALORIGIN="$(git -C "$TU/u61code" remote get-url origin)"
mkclaude u61
P61=$(mkpath u61 u61 claude flock git timeout gh jq)
cd "$TU/u61code"
PATH="$P61" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=20s bash "$SCRIPT" "$TU/u61plan/todo.md" > "$TU/u61.log" 2>&1 &
WPID=$!
i=0; while [ "$(wc -l < "$TU/u61launched" | tr -d ' ')" -lt 1 ] && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
git -C "$TU/u61code" remote set-url origin "https://outage.invalid/u61code.git"
i=0; while ! grep -q 'unreachable — waiting' "$TU/u61.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
CUT_AT=$(date +%s)
sleep 3
git -C "$TU/u61code" remote set-url origin "$REALORIGIN"      # blip clears well inside the 20s poll window
i=0; while ! grep -q 'reachable again' "$TU/u61.log" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i+1)); done
RESUMED_AT=$(date +%s)
ELAPSED=$((RESUMED_AT - CUT_AT))
check "U61 resumed within ~10s of clearing, not a 20s poll later" "$([ "$ELAPSED" -lt 15 ] && echo yes || echo no)" "yes"
stopwait "$WPID"
# U61 PASS — wait_for_network's first re-probe fires right when the park opens (poll_last starts
# unset/elapsed), so an outage that clears in a few seconds resumes in a few seconds — never
# idling out a full KAIZERO_REVIEW_POLL.

### U62 — a revoked token still stops the run at the existing `auth status failed` line and exit 2, on a reachable origin and on one the reachability probe itself cannot read either — never read as "unreachable"
mkorigin "$TU/u62code"; mkrepo "$TU/u62plan"; mktodo "$TU/u62plan" u62a
mkclaude u62a; mkclaude u62b
REALGIT="$(type -P git)"

# public origin: git transport fine, only the token is bad — but the token is only revoked AFTER
# a first pass launches on a good token, so this exercises the MID-RUN guard, not the launch
# doctor's own (unchanged) check 5. forge_auth_ok() only runs when ORIGIN_HOST is non-empty, so
# this origin is a fake HTTPS URL from the start (never mkorigin's hostless local-path clone): a
# git wrapper placed ahead of the real git on this case's own PATH answers `ls-remote` against
# that URL with a canned success, redirects `fetch` back to the real local bare origin (the
# launch doctor's own one-time `git fetch` still needs to work), and passes every other git
# invocation straight through to the real git.
REALORIGIN_A="$(git -C "$TU/u62code" remote get-url origin)"
FAKEURL_A="https://fake-forge-a.test/org/u62a.git"
git -C "$TU/u62code" remote set-url origin "$FAKEURL_A"
P62a=$(mkpath u62a u62a claude flock git timeout gh jq)
rm -f "$TU/path-u62a/git"
cat > "$TU/path-u62a/git" <<EOF
#!/usr/bin/env bash
REALGIT="$REALGIT"
FAKEURL="$FAKEURL_A"
REALORIGIN="$REALORIGIN_A"
args=("\$@")
sub=""; i=0
while [ "\$i" -lt "\${#args[@]}" ]; do
  a="\${args[\$i]}"
  case "\$a" in
    -C|-c) i=\$((i+2)); continue ;;
    -*) i=\$((i+1)); continue ;;
    *) sub="\$a"; break ;;
  esac
done
if [ "\$sub" = ls-remote ]; then
  for a in "\${args[@]}"; do
    if [ "\$a" = "\$FAKEURL" ]; then
      ref="\${args[\$((\${#args[@]}-1))]}"
      printf '%040d\t%s\n' 1 "\$ref"
      exit 0
    fi
  done
fi
if [ "\$sub" = fetch ]; then
  newargs=()
  for a in "\${args[@]}"; do
    [ "\$a" = origin ] && a="\$REALORIGIN"
    newargs+=("\$a")
  done
  exec "\$REALGIT" "\${newargs[@]}"
fi
exec "\$REALGIT" "\$@"
EOF
chmod +x "$TU/path-u62a/git"
( cd "$TU/u62code"
  PATH="$P62a" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 40 bash "$SCRIPT" "$TU/u62plan/todo.md" > "$TU/u62a.log" 2>&1 ) &
WPID62A=$!
i=0; while [ "$(wc -l < "$TU/u62alaunched" | tr -d ' ')" -lt 1 ] && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
check "U62a first session launched before revoke" "$([ "$(wc -l < "$TU/u62alaunched" | tr -d ' ')" -ge 1 ] && echo yes || echo no)" "yes"
echo "revoked token: Bad credentials" > "$TU/stub/gh-auth-fail"
wait "$WPID62A"
check "U62a exit status" "$?" "2"
check "U62a auth status failed line" "$([ "$(grep -c 'auth status failed' "$TU/u62a.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U62a never labeled unreachable" "$(grep -c 'unreachable' "$TU/u62a.log")" "0"
check "U62a no second session launched" "$(wc -l < "$TU/u62alaunched" | tr -d ' ')" "1"
rm -f "$TU/stub/gh-auth-fail"

# private origin: the reachability probe ITSELF fails, but on credentials (rc 3), not the network
# — the wrapper's ls-remote handler for the retargeted URL answers with a credentials-shaped
# refusal (never one of looks_like_network_error's patterns), which network_reachable reads as
# rc 3, same as the doctor's own reading of a private origin. The origin only turns bad AFTER a
# first pass launches, for the same reason as (a) above.
mkrepo "$TU/u62plan-b"; mktodo "$TU/u62plan-b" u62b
mkorigin "$TU/u62code-b"
REALORIGIN_B="$(git -C "$TU/u62code-b" remote get-url origin)"
FAKEURL_B="https://fake-forge-b.test/org/u62b.git"
BADURL_B="https://fake-forge-b-bad.test/org/u62b.git"
git -C "$TU/u62code-b" remote set-url origin "$FAKEURL_B"
P62b=$(mkpath u62b u62b claude flock git timeout gh jq)
rm -f "$TU/path-u62b/git"
cat > "$TU/path-u62b/git" <<EOF
#!/usr/bin/env bash
REALGIT="$REALGIT"
FAKEURL="$FAKEURL_B"
BADURL="$BADURL_B"
REALORIGIN="$REALORIGIN_B"
args=("\$@")
sub=""; i=0
while [ "\$i" -lt "\${#args[@]}" ]; do
  a="\${args[\$i]}"
  case "\$a" in
    -C|-c) i=\$((i+2)); continue ;;
    -*) i=\$((i+1)); continue ;;
    *) sub="\$a"; break ;;
  esac
done
if [ "\$sub" = ls-remote ]; then
  for a in "\${args[@]}"; do
    if [ "\$a" = "\$FAKEURL" ]; then
      ref="\${args[\$((\${#args[@]}-1))]}"
      printf '%040d\t%s\n' 1 "\$ref"
      exit 0
    fi
    if [ "\$a" = "\$BADURL" ]; then
      echo "fatal: Authentication failed for '\$BADURL'" >&2
      exit 1
    fi
  done
fi
if [ "\$sub" = fetch ]; then
  newargs=()
  for a in "\${args[@]}"; do
    [ "\$a" = origin ] && a="\$REALORIGIN"
    newargs+=("\$a")
  done
  exec "\$REALGIT" "\${newargs[@]}"
fi
exec "\$REALGIT" "\$@"
EOF
chmod +x "$TU/path-u62b/git"
( cd "$TU/u62code-b"
  PATH="$P62b" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 40 bash "$SCRIPT" "$TU/u62plan-b/todo.md" > "$TU/u62b.log" 2>&1 ) &
WPID62B=$!
i=0; while [ "$(wc -l < "$TU/u62blaunched" | tr -d ' ')" -lt 1 ] && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
check "U62b first session launched before revoke" "$([ "$(wc -l < "$TU/u62blaunched" | tr -d ' ')" -ge 1 ] && echo yes || echo no)" "yes"
git -C "$TU/u62code-b" remote set-url origin "$BADURL_B"
echo "revoked token: Bad credentials" > "$TU/stub/gh-auth-fail"
wait "$WPID62B"
check "U62b exit status (private origin, bad token)" "$?" "2"
check "U62b auth status failed line" "$([ "$(grep -c 'auth status failed' "$TU/u62b.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U62b never parks as unreachable" "$(grep -c 'unreachable — waiting' "$TU/u62b.log")" "0"
check "U62b no second session launched" "$(wc -l < "$TU/u62blaunched" | tr -d ' ')" "1"
rm -f "$TU/stub/gh-auth-fail"
# U62 PASS — a real credential refusal reaches the SAME permanent stop BUG-047 leaves untouched,
# whether the git transport is fine (a) or the reachability probe fails too on credentials rather
# than the network (b, network_reachable rc 3, `case 3) break` in mr_network_and_auth_ok): both
# exit 2 on the existing auth status failed line, neither ever prints "unreachable", neither
# launches a second session. Both sub-cases plant the failure only after a first pass has already
# launched on a good token/origin, so this exercises the mid-run guard (mr_network_and_auth_ok),
# never the launch doctor's own unchanged check 5.

### U63 — the forge API host down while git's own transport stays up parks via the forge probe, its wait/heartbeat line naming the origin's own host
mkorigin "$TU/u63code"; mkrepo "$TU/u63plan"; mktodo "$TU/u63plan" u63a
mkclaude u63
# forge_auth_ok() only runs when ORIGIN_HOST is non-empty, so this origin is a fake HTTPS URL
# from the start (never mkorigin's hostless local-path clone): a git wrapper placed ahead of the
# real git on this case's own PATH answers `ls-remote` against that URL with a canned success,
# redirects `fetch` back to the real local bare origin (the launch doctor's own one-time
# `git fetch` still needs to work), and passes every other git invocation straight through to
# the real git.
REALGIT="$(type -P git)"
REALORIGIN_63="$(git -C "$TU/u63code" remote get-url origin)"
FAKEURL_63="https://fake-forge-c.test/org/u63.git"
ORIGIN_HOST_63="fake-forge-c.test"
git -C "$TU/u63code" remote set-url origin "$FAKEURL_63"
P63=$(mkpath u63 u63 claude flock git timeout gh jq)
rm -f "$TU/path-u63/git"
cat > "$TU/path-u63/git" <<EOF
#!/usr/bin/env bash
REALGIT="$REALGIT"
FAKEURL="$FAKEURL_63"
REALORIGIN="$REALORIGIN_63"
args=("\$@")
sub=""; i=0
while [ "\$i" -lt "\${#args[@]}" ]; do
  a="\${args[\$i]}"
  case "\$a" in
    -C|-c) i=\$((i+2)); continue ;;
    -*) i=\$((i+1)); continue ;;
    *) sub="\$a"; break ;;
  esac
done
if [ "\$sub" = ls-remote ]; then
  for a in "\${args[@]}"; do
    if [ "\$a" = "\$FAKEURL" ]; then
      ref="\${args[\$((\${#args[@]}-1))]}"
      printf '%040d\t%s\n' 1 "\$ref"
      exit 0
    fi
  done
fi
if [ "\$sub" = fetch ]; then
  newargs=()
  for a in "\${args[@]}"; do
    [ "\$a" = origin ] && a="\$REALORIGIN"
    newargs+=("\$a")
  done
  exec "\$REALGIT" "\${newargs[@]}"
fi
exec "\$REALGIT" "\$@"
EOF
chmod +x "$TU/path-u63/git"
cd "$TU/u63code"
PATH="$P63" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s bash "$SCRIPT" "$TU/u63plan/todo.md" > "$TU/u63.log" 2>&1 &
WPID=$!
# let the FIRST pass launch on a working token — proves the mid-run guard, not the launch
# doctor, is what parks next.
i=0; while [ "$(wc -l < "$TU/u63launched" | tr -d ' ')" -lt 1 ] && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
LAUNCHED_AT_PARK=$(wc -l < "$TU/u63launched" | tr -d ' ')
check "U63 first session launched before outage" "$([ "$LAUNCHED_AT_PARK" -ge 1 ] && echo yes || echo no)" "yes"
printf 'dial tcp 140.82.112.6:443: i/o timeout\n' > "$TU/stub/gh-auth-fail"
i=0; while ! grep -q 'unreachable — waiting' "$TU/u63.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
check "U63 forge-outage wait line printed" "$([ "$(grep -c 'unreachable — waiting' "$TU/u63.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U63 no auth status failed line" "$(grep -c 'auth status failed' "$TU/u63.log")" "0"
check "U63 no empty slot in the label" "$(grep -cE 'origin  unreachable|origin unreachable . $' "$TU/u63.log")" "0"
check "U63 labeled by the origin's own host" "$([ "$(grep -F -c "$ORIGIN_HOST_63" "$TU/u63.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U63 no launch while parked" "$(wc -l < "$TU/u63launched" | tr -d ' ')" "$LAUNCHED_AT_PARK"
rm -f "$TU/stub/gh-auth-fail"
i=0; while ! grep -q 'reachable again' "$TU/u63.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
check "U63 resume line printed" "$([ "$(grep -c 'reachable again' "$TU/u63.log")" -ge 1 ] && echo yes || echo no)" "yes"
stopwait "$WPID"
# U63 PASS — an outage limited to the forge's own API host (git's transport unaffected), arriving
# only after a first pass has already launched, parks through wait_for_network forge exactly as a
# git-transport outage parks through wait_for_network net — no auth status failed line while it
# lasts. This fixture's origin carries a real host (a fake HTTPS URL, its ls-remote/fetch calls
# answered by a git wrapper ahead of the real git on this case's own PATH), so the
# wait/heartbeat line's label is ORIGIN_HOST itself — never a line with an empty slot between
# "origin" and "unreachable".

### U64 — `remote.origin.pushurl` pointed at an unreachable address while the fetch URL stays fine still parks and launches no session — the guard probes the URL a Hand off would actually push to
mkorigin "$TU/u64code"; mkrepo "$TU/u64plan"; mktodo "$TU/u64plan" u64a
mkclaude u64
git -C "$TU/u64code" config remote.origin.pushurl "https://outage.invalid/u64code.git"
P64=$(mkpath u64 u64 claude flock git timeout gh jq)
cd "$TU/u64code"
PATH="$P64" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 30 bash "$SCRIPT" "$TU/u64plan/todo.md" > "$TU/u64.log" 2>&1
check "U64 wait line printed (pushurl alone is bad)" "$([ "$(grep -c 'unreachable — waiting' "$TU/u64.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U64 no session launched" "$(wc -l < "$TU/u64launched" | tr -d ' ')" "0"
# U64 PASS — network_reachable reads `git remote get-url --push origin`, so a pushurl override
# that redirects only the push side is caught even though a plain fetch would have succeeded —
# the endpoint judged is the one a Hand off actually uses.

### U65 — the target base branch missing from an otherwise-reachable origin, and the same base present only under a sibling path (`refs/heads/feature/main`, not `refs/heads/main`), both stop the run with the doctor's own reading — never a park
mkorigin "$TU/u65code-a"; mkrepo "$TU/u65plan-a"; mktodo "$TU/u65plan-a" u65a
git --git-dir="$TU/u65code-a-origin.git" branch -m main gone-main
mkclaude u65a
P65a=$(mkpath u65a u65a claude flock git timeout gh jq)
( cd "$TU/u65code-a"
  PATH="$P65a" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 30 bash "$SCRIPT" "$TU/u65plan-a/todo.md" > "$TU/u65a.log" 2>&1 )
check "U65a exit status (base gone, the launch doctor's own refusal)" "$?" "1"
check "U65a names the base to push" "$([ "$(grep -c 'not on origin' "$TU/u65a.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U65a never parks as unreachable" "$(grep -c 'unreachable — waiting' "$TU/u65a.log")" "0"
check "U65a no session launched" "$(wc -l < "$TU/u65alaunched" | tr -d ' ')" "0"

mkorigin "$TU/u65code-b"; mkrepo "$TU/u65plan-b"; mktodo "$TU/u65plan-b" u65b
git --git-dir="$TU/u65code-b-origin.git" branch -m main feature/main
mkclaude u65b
P65b=$(mkpath u65b u65b claude flock git timeout gh jq)
( cd "$TU/u65code-b"
  PATH="$P65b" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s timeout 30 bash "$SCRIPT" "$TU/u65plan-b/todo.md" > "$TU/u65b.log" 2>&1 )
check "U65b exit status (sibling only)" "$?" "1"
check "U65b exact ref decides, not a tail" "$([ "$(grep -c 'not on origin' "$TU/u65b.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U65b never parks as unreachable" "$(grep -c 'unreachable — waiting' "$TU/u65b.log")" "0"
# U65 PASS — both cases fail before run_loop even starts: the launch doctor's own check 6 (a
# plain `git fetch origin +refs/heads/<base>:...`) refuses first, naming the base to push, at
# status 1 — a missing base is permanent, never network-shaped, so nothing here ever reaches
# wait_for_network. refs/heads/feature/main alone does not satisfy refs/heads/main: git's own ref
# matching treats the full spelled-out ref as an exact path, not a tail pattern.

### U66 — Ctrl+C during the network wait ends the run through the usual closer at status 0; `SIGHUP` during the same wait ends it through the same closer at the `SIGHUP` status
mkorigin "$TU/u66code-a"; mkrepo "$TU/u66plan-a"; mktodo "$TU/u66plan-a" u66a
mkclaude u66a
P66a=$(mkpath u66a u66a claude flock git timeout gh jq)
cd "$TU/u66code-a"
PATH="$P66a" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s
export PATH KAIZERO_WAIT_TICK KAIZERO_REVIEW_POLL
WPID=$(bg_setsid "$TU/u66a.log" bash "$SCRIPT" "$TU/u66plan-a/todo.md")
i=0; while [ "$(wc -l < "$TU/u66alaunched" | tr -d ' ')" -lt 1 ] && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
git -C "$TU/u66code-a" remote set-url origin "https://outage.invalid/u66a.git"
i=0; while ! grep -q 'unreachable — waiting' "$TU/u66a.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
T0=$(date +%s); kill -INT -"$WPID"; RC=$(wait_setsid "$TU/u66a.log"); T1=$(date +%s)
check "U66a Ctrl+C exit status" "$RC" "0"
check "U66a interrupt landed within ~5s" "$([ "$((T1-T0))" -lt 8 ] && echo yes || echo no)" "yes"
check "U66a usual closing report printed" "$([ "$(grep -c 'Run loop stopped' "$TU/u66a.log")" -ge 1 ] && echo yes || echo no)" "yes"
cd - >/dev/null

mkorigin "$TU/u66code-b"; mkrepo "$TU/u66plan-b"; mktodo "$TU/u66plan-b" u66b
mkclaude u66b
P66b=$(mkpath u66b u66b claude flock git timeout gh jq)
cd "$TU/u66code-b"
PATH="$P66b" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s
export PATH KAIZERO_WAIT_TICK KAIZERO_REVIEW_POLL
WPID=$(bg_setsid "$TU/u66b.log" bash "$SCRIPT" "$TU/u66plan-b/todo.md")
i=0; while [ "$(wc -l < "$TU/u66blaunched" | tr -d ' ')" -lt 1 ] && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
git -C "$TU/u66code-b" remote set-url origin "https://outage.invalid/u66b.git"
i=0; while ! grep -q 'unreachable — waiting' "$TU/u66b.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
kill -HUP -"$WPID"; RC=$(wait_setsid "$TU/u66b.log")
check "U66b SIGHUP exit status" "$RC" "129"
check "U66b same closing report as SIGTERM" "$([ "$(grep -c 'Run loop stopped\|TOTAL' "$TU/u66b.log")" -ge 1 ] && echo yes || echo no)" "yes"
cd - >/dev/null
# U66 PASS — the network wait is an ordinary blocking wait like every other park in the file:
# Ctrl+C/SIGTERM sets STOP, the loop's sleep/poll calls return promptly (bounded by WAIT_TICK),
# and the single closer runs — status 0 for a plain Ctrl+C. SIGHUP (added by BUG-047 because this
# wait can now run unbounded) forwards to the same STOP/closer path but is remembered separately
# (HUPPED), so the run ends on status 129 instead of 0, on the same closing report.

### U67 — `KAIZERO_REVIEW_WAIT=0` never parks on an unreachable origin: it names the cause and exits 2 within seconds, exactly as it already promises for reviews
mkorigin "$TU/u67code"; mkrepo "$TU/u67plan"; mktodo "$TU/u67plan" u67a
mkclaude u67
P67=$(mkpath u67 u67 claude flock git timeout gh jq)
# one continuous run, KAIZERO_REVIEW_WAIT=0 set from the start: it does not affect the first
# pass (the network is fine, so nothing parks), and the origin only turns bad AFTER that first
# pass has already launched — so this exercises the mid-run guard's =0 gate, never the launch
# doctor's own unchanged check 6, which would otherwise refuse at launch on a pre-cut origin.
( cd "$TU/u67code"
  PATH="$P67" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s KAIZERO_REVIEW_WAIT=0 timeout 30 bash "$SCRIPT" "$TU/u67plan/todo.md" > "$TU/u67.log" 2>&1 &
  WPID=$!
  i=0; while [ "$(wc -l < "$TU/u67launched" | tr -d ' ')" -lt 1 ] && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
  git -C "$TU/u67code" remote set-url origin "https://outage.invalid/u67code.git"
  T0=$(date +%s)
  wait "$WPID"; RC=$?; T1=$(date +%s)
  check "U67 exit status" "$RC" "2"
  check "U67 elapsed" "$([ "$((T1-T0))" -lt 10 ] && echo yes || echo no)" "yes"
  check "U67 names unreachable, not waits" "$([ "$(grep -c 'unreachable — not waiting' "$TU/u67.log")" -ge 1 ] && echo yes || echo no)" "yes"
  check "U67 never prints the wait line" "$(grep -c 'unreachable — waiting' "$TU/u67.log")" "0" )
# U67 PASS — wait_for_network honours KAIZERO_REVIEW_WAIT=0 exactly as
# wait_for_reviews/wait_for_dependency_clear already do: it never prints the "waiting" line or
# parks, it names the cause once and stops, IDFAIL=1, exit 2, within seconds.

### U68 — `KAIZERO_REVIEW_POLL` renders in house duration form in the wait line — `30s` stays `30s`, `900` (seconds) renders as `15m`
mkorigin "$TU/u68code-a"; mkrepo "$TU/u68plan-a"; mktodo "$TU/u68plan-a" u68a
mkclaude u68a
P68a=$(mkpath u68a u68a claude flock git timeout gh jq)
# origin turns bad only AFTER the first pass has launched, so the doctor's launch-time check 6
# passes and this exercises the mid-run guard's cadence rendering, never the doctor.
( cd "$TU/u68code-a"
  PATH="$P68a" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=30s timeout 30 bash "$SCRIPT" "$TU/u68plan-a/todo.md" > "$TU/u68a.log" 2>&1 & WPID=$!
  i=0; while [ "$(wc -l < "$TU/u68alaunched" | tr -d ' ')" -lt 1 ] && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
  git -C "$TU/u68code-a" remote set-url origin "https://outage.invalid/u68a.git"
  i=0; while ! grep -q 'unreachable — waiting' "$TU/u68a.log" 2>/dev/null && [ "$i" -lt 80 ]; do sleep 0.2; i=$((i+1)); done
  check "U68a renders 30s as 30s" "$([ "$(grep -c 're-probing every 30s' "$TU/u68a.log")" -ge 1 ] && echo yes || echo no)" "yes"
  stopwait "$WPID" )

mkorigin "$TU/u68code-b"; mkrepo "$TU/u68plan-b"; mktodo "$TU/u68plan-b" u68b
mkclaude u68b
P68b=$(mkpath u68b u68b claude flock git timeout gh jq)
( cd "$TU/u68code-b"
  PATH="$P68b" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=900 timeout 30 bash "$SCRIPT" "$TU/u68plan-b/todo.md" > "$TU/u68b.log" 2>&1 & WPID=$!
  i=0; while [ "$(wc -l < "$TU/u68blaunched" | tr -d ' ')" -lt 1 ] && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
  git -C "$TU/u68code-b" remote set-url origin "https://outage.invalid/u68b.git"
  i=0; while ! grep -q 'unreachable — waiting' "$TU/u68b.log" 2>/dev/null && [ "$i" -lt 80 ]; do sleep 0.2; i=$((i+1)); done
  check "U68b renders 900 as 15m" "$([ "$(grep -c 're-probing every 15m' "$TU/u68b.log")" -ge 1 ] && echo yes || echo no)" "yes"
  stopwait "$WPID" )
# U68 PASS — the wait line's cadence goes through fmt_dur, the house convention every other
# duration in the script uses (the watchdog line, the restart line), never the raw knob value.

### U69 — a `SIGTERM` arriving during the between-runs sleep, before the network guard's next pass ever runs, yields only the closing report — never a wait line claiming the run parked
mkorigin "$TU/u69code"; mkrepo "$TU/u69plan"; mktodo "$TU/u69plan" u69a
mkclaude u69
P69=$(mkpath u69 u69 claude flock git timeout gh jq)
cd "$TU/u69code"
PATH="$P69" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s bash "$SCRIPT" "$TU/u69plan/todo.md" > "$TU/u69.log" 2>&1 &
WPID=$!
# first session launches and exits (the stub claude exits immediately) — catch it right in the
# between-runs RESTART_WAIT sleep that follows, before the loop's next top (and thus the next
# mr_network_and_auth_ok call) ever runs.
i=0; while [ "$(wc -l < "$TU/u69launched" | tr -d ' ')" -lt 1 ] && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
i=0; while ! grep -q 'restarting in' "$TU/u69.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
git -C "$TU/u69code" remote set-url origin "https://outage.invalid/u69code.git"
kill -TERM "$WPID"
wait "$WPID"; RC=$?
check "U69 exit status" "$RC" "143"
check "U69 no wait line ever printed" "$(grep -c 'unreachable — waiting' "$TU/u69.log")" "0"
check "U69 exactly one Code 95 line" "$(grep -c 'Code 95' "$TU/u69.log")" "1"
# U69 PASS — STOP/TERMED are set and the loop's own `if [ "$STOP" = 1 ]; then … break; fi` right
# after the between-runs sleep fires before the next iteration ever reaches
# mr_network_and_auth_ok — so a SIGTERM landing in that gap, even with the network already cut,
# never gets far enough to open a park. The closer's Code 95 line is the only line this stop
# produces.

### U70 — `wait_for_reviews`'s own poll, parked on an open `[↑]` request, also parks on a network outage instead of blaming the token — same behaviour as the pre-launch guard
mkorigin "$TU/u70code"; mkrepo "$TU/u70plan"
( cd "$TU/u70code"; git checkout -qb u70a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
REALORIGIN70="$(git -C "$TU/u70code" remote get-url origin)"
( cd "$TU/u70plan"; printf -- '- [\xe2\x86\x91] u70a fix thing\n' > todo.md; git add todo.md; git commit -qm todo )
cat > "$TU/stub/gh-list.out" <<'JSON'
[{"number":70,"headRefOid":"zzz","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/70"}]
JSON
mkclaude u70
P70=$(mkpath u70 u70 claude flock git timeout gh jq)
cd "$TU/u70code"
PATH="$P70" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s bash "$SCRIPT" "$TU/u70plan/todo.md" > "$TU/u70.log" 2>&1 &
WPID=$!
i=0; while ! grep -q 'Waiting for reviews' "$TU/u70.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
check "U70 parked on the open review first" "$([ "$(grep -c 'Waiting for reviews' "$TU/u70.log")" -ge 1 ] && echo yes || echo no)" "yes"
git -C "$TU/u70code" remote set-url origin "https://outage.invalid/u70code.git"
i=0; while ! grep -q 'unreachable — waiting' "$TU/u70.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
check "U70 review park's poll parks on network too" "$([ "$(grep -c 'unreachable — waiting' "$TU/u70.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U70 no auth status failed" "$(grep -c 'auth status failed' "$TU/u70.log")" "0"
check "U70 no exit 2 while parked" "$(kill -0 "$WPID" 2>/dev/null && echo alive || echo dead)" "alive"
git -C "$TU/u70code" remote set-url origin "$REALORIGIN70"
i=0; while ! grep -q 'reachable again' "$TU/u70.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
check "U70 resumes when origin answers" "$([ "$(grep -c 'reachable again' "$TU/u70.log")" -ge 1 ] && echo yes || echo no)" "yes"
stopwait "$WPID"
rm -f "$TU/stub/gh-list.out"
# wait_for_reviews's poll routes through the same mr_network_and_auth_ok as the pre-launch guard,
# so a park already open for a review reacts to a network outage the identical way: it parks on
# wait_for_network instead of ever reaching the token check, no auth status failed, no exit, and
# resumes once origin answers again.

# U71 — wait_for_dependency_clear's own poll (a task blocked on an unchecked prerequisite, MR
# mode) parks on a network outage exactly as wait_for_reviews' poll does — the two parks
# differing only in what they wait on
mkorigin "$TU/u71code"; mkrepo "$TU/u71plan"
( cd "$TU/u71code"; git checkout -qb u71a-fix-thing; echo y > g; git add g; git commit -qm work; git checkout -q main )
( cd "$TU/u71plan"; printf -- '- [\xe2\x86\x91] u71a fix thing\n- [ ] u71b needs u71a\n' > todo.md; git add todo.md; git commit -qm todo )
u71sha=$(git -C "$TU/u71code" rev-parse u71a-fix-thing)
cat > "$TU/stub/gh-list.out" <<JSON
[{"number":71,"headRefOid":"$u71sha","baseRefName":"main","state":"OPEN","url":"https://example.invalid/pr/71"}]
JSON
cat > "$TU/bin/claude-u71" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = -v ] && { echo "1.0.0 (test stub)"; exit 0; }
echo launched >> "$TU/u71launched"
n=\$(wc -l < "$TU/u71launched" | tr -d ' ')
[ "\$n" -eq 1 ] && "$TU/u71plan/.git/zero.sh" no-claim-mark
exit 0
EOF
chmod +x "$TU/bin/claude-u71"; : > "$TU/u71launched"
P71=$(mkpath u71 u71 claude flock git timeout gh jq)
cd "$TU/u71code"
PATH="$P71" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=2s bash "$SCRIPT" "$TU/u71plan/todo.md" > "$TU/u71.log" 2>&1 &
WPID=$!
i=0; while ! grep -q 'Waiting for reviews' "$TU/u71.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
check "U71 parked blocked on u71a first" "$([ "$(grep -c 'Waiting for reviews' "$TU/u71.log")" -ge 1 ] && echo yes || echo no)" "yes"
git -C "$TU/u71code" remote set-url origin "https://outage.invalid/u71code.git"
i=0; while ! grep -q 'unreachable — waiting' "$TU/u71.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
check "U71 dependency park's poll parks on network too" "$([ "$(grep -c 'unreachable — waiting' "$TU/u71.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U71 no auth status failed" "$(grep -c 'auth status failed' "$TU/u71.log")" "0"
git -C "$TU/u71code" remote set-url origin "$TU/u71code-origin.git"
i=0; while ! grep -q 'reachable again' "$TU/u71.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
check "U71 resumes when origin answers" "$([ "$(grep -c 'reachable again' "$TU/u71.log")" -ge 1 ] && echo yes || echo no)" "yes"
stopwait "$WPID"
rm -f "$TU/stub/gh-list.out"
# wait_for_dependency_clear's own re-check (MR_REVIEW_ACTIVE=1, BUG-039l's site) shares
# mr_network_and_auth_ok with wait_for_reviews' poll and the pre-launch guard, so a network
# outage met while blocked on a sibling task's still-open request parks and resumes exactly the
# same way — no auth status failed, no exit 2.

# U72 — an origin that flaps (reachable/unreachable across successive pre-launch probes)
# launches a bounded, growing-gap number of sessions rather than one per flat RESTART_WAIT, and
# every pass that met the outage leaves a log line
mkorigin "$TU/u72code"; mkrepo "$TU/u72plan"; mktodo "$TU/u72plan" u72a
REALORIGIN="$(git -C "$TU/u72code" remote get-url origin)"
BADORIGIN="https://outage.invalid/u72code.git"
mkclaude u72
P72=$(mkpath u72 u72 claude flock git timeout gh jq)
cd "$TU/u72code"
PATH="$P72" KAIZERO_WAIT_TICK=1 KAIZERO_REVIEW_POLL=1s KAIZERO_RESTART_WAIT=1 timeout 80 bash "$SCRIPT" "$TU/u72plan/todo.md" > "$TU/u72.log" 2>&1 &
WPID=$!
# let the launch doctor's own one-time origin fetch pass on the real origin before the flipper
# ever touches it — this case tests the mid-run guard's flap handling, never the doctor.
i=0; while [ "$(wc -l < "$TU/u72launched" | tr -d ' ')" -lt 1 ] && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done
# an independent flipper, on its own clock — not one triggered by a session launch, which would
# deadlock: once the guard parks in wait_for_network, no session runs to flip origin back, and a
# launch-triggered flip can never recover on its own. Toggling faster than
# KAIZERO_REVIEW_POLL=1s guarantees some passes meet the outage (park, then recover on the
# flipper's own next tick) while others land on the reachable half and proceed straight through.
( i=0; while [ "$i" -lt 200 ]; do
    if [ $((i % 2)) -eq 0 ]; then git -C "$TU/u72code" remote set-url origin "$BADORIGIN" 2>/dev/null
    else git -C "$TU/u72code" remote set-url origin "$REALORIGIN" 2>/dev/null; fi
    i=$((i+1)); sleep 1
  done ) & FLIPPID=$!
wait "$WPID" 2>/dev/null
kill "$FLIPPID" 2>/dev/null; wait "$FLIPPID" 2>/dev/null
check "U72 flap lines logged (streak widened)" "$([ "$(grep -c 'Origin flapped before this launch' "$TU/u72.log")" -ge 1 ] && echo yes || echo no)" "yes"
check "U72 restart gap grows past RESTART_WAIT=1s" "$([ "$(grep -oE 'restarting in [0-9]+s' "$TU/u72.log" | grep -vc 'restarting in 1s')" -ge 1 ] && echo yes || echo no)" "yes"
# want a small number, not dozens, over 40s
check "U72 launches bounded, not one per 1s forever" "$([ "$(wc -l < "$TU/u72launched" | tr -d ' ')" -lt 30 ] && echo yes || echo no)" "yes"
# NET_FLAP_STREAK increments every pass whose guard met an outage before proceeding, and
# RESTART_GAP = RESTART_WAIT * 2^streak (capped at 64x) widens the sleep between sessions on
# every such pass — a flapping origin that occasionally passes the probe by chance still thins
# its own relaunch cadence instead of spinning at a flat RESTART_WAIT.

# U73 — a second, independent witness for the auth-status literal-call-site count and its two
# mid-run callers
check "U73 literal 'auth status --hostname' call sites" "$(grep -n 'auth status' "$REPO/kaizero.sh" | grep -c 'auth status --hostname')" "2"
check "U73 pre-launch guard routes through the helper" "$([ "$(grep -c 'if ! mr_network_and_auth_ok; then break; fi' "$REPO/kaizero.sh")" -ge 1 ] && echo yes || echo no)" "yes"
check "U73 wait_for_reviews routes through the helper" "$([ "$(sed -n '/^wait_for_reviews()/,/^wait_for_dependency_clear()/p' "$REPO/kaizero.sh" | grep -c 'mr_network_and_auth_ok')" -ge 1 ] && echo yes || echo no)" "yes"
check "U73 wait_for_dependency_clear routes through it" "$([ "$(sed -n '/^wait_for_dependency_clear()/,/^tasks_verb()/p' "$REPO/kaizero.sh" | grep -c 'mr_network_and_auth_ok')" -ge 1 ] && echo yes || echo no)" "yes"
# informational cross-check, read alongside the two counts above rather than alone — want 0
# additional sites beyond the two named above. Scoped by function body (run_doctor's own check 4,
# forge_auth_ok's own call), not by a substring match against neighboring text, since neither call
# site's own line literally contains the function's name next to it.
U73_TOTAL=$(grep -c 'auth status --hostname' "$REPO/kaizero.sh")
U73_IN_DOCTOR=$(awk '/^run_doctor\(\)/,/^}/' "$REPO/kaizero.sh" | grep -c 'auth status --hostname')
U73_IN_FORGE_AUTH_OK=$(awk '/^forge_auth_ok\(\)/,/^}/' "$REPO/kaizero.sh" | grep -c 'auth status --hostname')
check "U73 no bare literal auth-status call left mid-run" "$((U73_TOTAL - U73_IN_DOCTOR - U73_IN_FORGE_AUTH_OK))" "0"
# kaizero.sh reads "$FORGE" auth status --hostname exactly twice in the whole file: the
# launch doctor's own check 5, and inside the shared forge_auth_ok helper. Every mid-run site —
# the pre-launch guard, wait_for_reviews's poll, wait_for_dependency_clear's poll — calls
# mr_network_and_auth_ok (which calls forge_auth_ok), never the CLI directly.

# U74 — static properties this suite cannot reproduce live: no case here stands up a real HTTPS
# credential prompt or a black-holed route, and no case waits out an hours-long unbounded park,
# so these pin the guarantee at the source instead
# scoped to both network_reachable bodies (the main script's own, and BUG-048's baked-in zero.sh
# heredoc copy) — a whole-file grep also catches this guard's own doc comment (line ~502, real
# text, not a call site) and the unrelated pre-existing push guard (mr_land's step 4), neither of
# which this fix touches.
check "U74 GIT_TERMINAL_PROMPT=0 guards a git transport call" "$(awk '/^network_reachable\(\)/,/^}/' "$REPO/kaizero.sh" | grep -c 'GIT_TERMINAL_PROMPT=0')" "2"
check "U74 network_reachable's ls-remote is wrapped in the bounded timeout" "$(awk '/^network_reachable\(\)/,/^}/' "$REPO/kaizero.sh" | grep -c 'timeout \"\${NETWORK_PROBE_TIMEOUT:-10}\"')" "2"
check "U74 forge_auth_ok's own retry is a fixed, bounded 3 tries" "$(awk '/^forge_auth_ok\(\)/,/^}/' "$REPO/kaizero.sh" | grep -c 'while \[ \"\$i\" -le 3 \]')" "1"
stop_line=$(awk '/^wait_for_network\(\)/{f=NR} f && /\[ \"\$STOP\" = 1 \]/{print NR; exit}' "$REPO/kaizero.sh")
wait_line=$(awk '/^wait_for_network\(\)/{f=NR} f && /unreachable — waiting, re-probing/{print NR; exit}' "$REPO/kaizero.sh")
# wait_for_network tests STOP before printing the wait line, not after
check "U74 STOP check precedes the wait-line printf" "$([ "$stop_line" -lt "$wait_line" ] && echo yes || echo no)" "yes"
check "U74 wait_for_network names REVIEW_WAIT_SECS exactly once" "$(awk '/^wait_for_network\(\)/,/^}/' "$REPO/kaizero.sh" | grep -c 'REVIEW_WAIT_SECS')" "1"
check "U74 the launch doctor's check 6 is untouched by this fix" "$(git -C "$REPO" diff HEAD~2 -- kaizero.sh | grep -c '^[+-].*fetch of origin')" "0"
# every bound this fix relies on but cannot exercise live in this suite (no fixture here can
# stand up a real HTTPS Username for '...': prompt or a route that black-holes instead of
# refusing, and no case can afford to wait out an unbounded park to prove it never ends on its
# own) is instead pinned at its source: GIT_TERMINAL_PROMPT=0 guards both git transport calls
# this fix touches, network_reachable's probe is timeout-wrapped, forge_auth_ok's retry is a
# fixed 3 tries, wait_for_network tests STOP strictly before it prints the wait line, its body
# names REVIEW_WAIT_SECS exactly once (the KAIZERO_REVIEW_WAIT=0 gate U67 exercises live — no
# second, unbounded-by-default ceiling check sits beside it), and the launch doctor's own check 6
# (fetch of origin/$TARGET_BASE failed), which already refuses an unreachable origin at launch
# with status 1, shows zero lines changed across this fix's whole diff — the launch-time refusal
# this criterion asks for is provably the same code that shipped before BUG-047 touched this
# file, not new behavior this suite would need to re-prove.
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
