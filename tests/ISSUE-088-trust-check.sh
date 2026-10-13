#!/usr/bin/env bash
# KAIZERO_TEST_ISOLATED=1
# KAIZERO_WALLCLOCK_BUDGET=300s
# shellcheck disable=SC1091,SC2164
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# ISSUE-088-trust-check — a launch whose target repository Claude Code does not trust is refused
# before anything is written, with the steps to trust it; a trusted target starts claude.
# Needs real claude: no — a stub `claude` on a scenario-scoped PATH stands in for it
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/ISSUE-088-trust-check
# Wall-clock budget: a dozen launches of a few seconds each — well under 300s
# The operator's live ~/.claude.json is rewritten by every running claude, so it is not checksummed here:
# no launch reads or writes it except E3, which points HOME at a fixture directory.
# Race note: none — every launch has its own repository and its own CLAUDE_CONFIG_DIR.

TR="$TESTROOT/ISSUE-088-trust-check"; mkdir -p "$TR/bin"
export TEST_CLAUDE_CONFIG_DIR_KEEP=1   # this scenario supplies each launch's CLAUDE_CONFIG_DIR itself

# stub claude: records that it ran; $STUB_FLIP (a config path) is rewritten to untrusted on the first run
cat > "$TR/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-v" ] && { echo "9.9.9 (stub)"; exit 0; }
echo run >> "$STUB_MARKER"
if [ -n "${STUB_FLIP:-}" ] && [ ! -e "$STUB_MARKER.flipped" ]; then
  : > "$STUB_MARKER.flipped"; sed -i.bak 's/true/false/' "$STUB_FLIP"; rm -f "$STUB_FLIP.bak"
fi
exit 0
EOF
chmod +x "$TR/bin/claude"

# mk_repo DIR: a committed repo holding todo.md and one Task file
mk_repo() {
  mkdir -p "$1/tasks"; ( cd "$1" && git init -q -b main && git config user.email t@t.t && git config user.name test \
    && printf -- '- [ ] TASK-1 x tasks/TASK-1.md\n' > todo.md && printf -- '### Acceptance criteria\n- [ ] a\n' > tasks/TASK-1.md \
    && git add -A && git commit -qm init ); }
# cfg DIR CONTENT: a fresh CLAUDE_CONFIG_DIR whose .claude.json holds CONTENT
cfg() { mkdir -p "$1"; printf '%s\n' "$2" > "$1/.claude.json"; }
# launch REPO CFGDIR OUTFILE [args...]: runs kaizero from REPO with the stub claude; the stub's marker is OUTFILE.marker
launch() {
  local repo="$1" cd_="$2" out="$3"; shift 3
  rm -f "$out.marker" "$out.marker.flipped"
  ( cd "$repo" && PATH="$TR/bin:$PATH" STUB_MARKER="$out.marker" CLAUDE_CONFIG_DIR="$cd_" \
      timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" "$@" > "$out" 2>&1 ); echo $?; }
ran() { [ -e "$1.marker" ] && echo yes || echo no; }
has() { grep -qF -- "$2" "$1" && echo yes || echo no; }
tj() { printf '{"projects":{"%s":{"hasTrustDialogAccepted":%s}}}' "$1" "$2"; }

R="$TR/r1"; mk_repo "$R"; P="$(cd "$R" && pwd -P)"
common="$R/.git"

# A — refusals
cfg "$TR/c-noentry" "$(tj /elsewhere true)"
sum0=$(cksum < "$TR/c-noentry/.claude.json"); ls0=$(ls -a "$common" | tr '\n' ' ')
rc=$(launch "$R" "$TR/c-noentry" "$TR/a1.out" --local-merge todo.md -t x)
check "A1 no projects entry: nonzero" "$([ "$rc" != 0 ] && echo yes)" "yes"
check "A1 program-name prefix and the key path" "$(has "$TR/a1.out" "kaizero.sh: '$P' is not trusted")" "yes"
check "A3 steps: run claude, accept, exit, relaunch" "$(grep -c 'run `claude` in that directory, accept the trust dialog, exit it, then launch' "$TR/a1.out")" "1"
check "A1 stub claude never ran" "$(ran "$TR/a1.out")" "no"
check "A1 config checksum unchanged" "$(cksum < "$TR/c-noentry/.claude.json")" "$sum0"
check "A1 git common dir listing unchanged" "$(ls -a "$common" | tr '\n' ' ')" "$ls0"
check "A1 no instance registered" "$(ls "$common/instance" 2>/dev/null | wc -l | tr -d ' ')" "0"
check "A1 no run summary" "$(has "$TR/a1.out" "Fork")" "no"

rc=$(launch "$R" "$TR/no-such-cfg" "$TR/a2.out" --local-merge todo.md -t x)
check "A2 config file absent: refused" "$([ "$rc" != 0 ] && has "$TR/a2.out" "is not trusted")" "yes"
for v in false '"true"' null; do
  cfg "$TR/c-v" "$(tj "$P" "$v")"; rc=$(launch "$R" "$TR/c-v" "$TR/a2v.out" --local-merge todo.md -t x)
  check "A2 hasTrustDialogAccepted=$v refused" "$([ "$rc" != 0 ] && has "$TR/a2v.out" "is not trusted")" "yes"
done
cfg "$TR/c-nofield" "{\"projects\":{\"$P\":{\"allowedTools\":[]}}}"; rc=$(launch "$R" "$TR/c-nofield" "$TR/a2f.out" --local-merge todo.md -t x)
check "A2 field absent refused" "$([ "$rc" != 0 ] && has "$TR/a2f.out" "is not trusted")" "yes"
cfg "$TR/c-parent" "$(tj "$(dirname "$P")" true)"; rc=$(launch "$R" "$TR/c-parent" "$TR/a5.out" --local-merge todo.md -t x)
check "A5 parent trusted, own entry absent: refused" "$([ "$rc" != 0 ] && has "$TR/a5.out" "is not trusted")" "yes"

# B — passes
cfg "$TR/c-ok" "$(tj "$P" true)"; sum1=$(cksum < "$TR/c-ok/.claude.json")
rc=$(launch "$R" "$TR/c-ok" "$TR/b1.out" --local-merge todo.md -t x)
check "B1 trusted: exit 0, claude started" "$rc $(ran "$TR/b1.out")" "0 yes"
check "B1 no trust message" "$(has "$TR/b1.out" "not trusted")" "no"
check "B1 config checksum unchanged" "$(cksum < "$TR/c-ok/.claude.json")" "$sum1"

LNK="$TR/link"; ln -s "$R" "$LNK"
rc=$(launch "$LNK" "$TR/c-ok" "$TR/b6.out" --local-merge todo.md -t x)
check "B6 symlink spelling checked under physical path: trusted" "$rc $(ran "$TR/b6.out")" "0 yes"
cfg "$TR/c-lnk" "$(tj "$TR/link" true)"; rc=$(launch "$LNK" "$TR/c-lnk" "$TR/b6b.out" --local-merge todo.md -t x)
check "B6 only the symlink spelling trusted: refused" "$([ "$rc" != 0 ] && has "$TR/b6b.out" "is not trusted")" "yes"

SP="$TR/sp ace"; mk_repo "$SP"; PS="$(cd "$SP" && pwd -P)"
cfg "$TR/c-sp" "$(tj "$PS" true)"; rc=$(launch "$SP" "$TR/c-sp" "$TR/b7.out" --local-merge todo.md -t x)
check "B7 path with a space passes" "$rc $(ran "$TR/b7.out")" "0 yes"

# C — unreadable / unparseable
cfg "$TR/c-nop" '{"numStartups":3}'; rc=$(launch "$R" "$TR/c-nop" "$TR/c8.out" --local-merge todo.md -t x)
check "C8 no projects key: nonzero, names the file" "$([ "$rc" != 0 ] && has "$TR/c8.out" "$TR/c-nop/.claude.json")" "yes"
check "C8 says content could not be read" "$(has "$TR/c8.out" "could not be read")" "yes"
check "C8 does not tell the operator to trust" "$(has "$TR/c8.out" "accept the trust dialog")" "no"
cfg "$TR/c-unr" "$(tj "$P" true)"; chmod 000 "$TR/c-unr/.claude.json"
rc=$(launch "$R" "$TR/c-unr" "$TR/c8u.out" --local-merge todo.md -t x); chmod 644 "$TR/c-unr/.claude.json"
check "C8 unreadable file: nonzero, could not be read" "$([ "$rc" != 0 ] && has "$TR/c8u.out" "could not be read")" "yes"

# D — formats
mkdir -p "$TR/c-f2" "$TR/c-f4" "$TR/c-f0" "$TR/c-u2"
for kind in 2 4 0; do
  python3 -c 'import json,sys; ind=int(sys.argv[3]) or None; json.dump({"numStartups":1,"projects":{"/other":{"mcp":{"a":{}},"hasTrustDialogAccepted":False},sys.argv[1]:{"allowedTools":[],"history":{"x":1},"hasTrustDialogAccepted":True}}},open(sys.argv[2],"w"),indent=ind,separators=(", ",": ") if ind else (",",":"))' "$P" "$TR/c-f$kind/.claude.json" "$kind"
  rc=$(launch "$R" "$TR/c-f$kind" "$TR/d$kind.out" --local-merge todo.md -t x)
  check "D indent $kind: trusted passes" "$rc $(ran "$TR/d$kind.out")" "0 yes"
  python3 -c 'import json,sys; ind=int(sys.argv[3]) or None; json.dump({"projects":{sys.argv[1]:{"mcp":{"a":{}},"hasTrustDialogAccepted":False}}},open(sys.argv[2],"w"),indent=ind)' "$P" "$TR/c-u2/.claude.json" "$kind"
  rc=$(launch "$R" "$TR/c-u2" "$TR/du$kind.out" --local-merge todo.md -t x)
  check "D indent $kind: untrusted refused" "$([ "$rc" != 0 ] && has "$TR/du$kind.out" "is not trusted")" "yes"
done

# E — CLAUDE_CONFIG_DIR wins over ~/.claude.json
FH="$TR/fakehome"; mkdir -p "$FH"; tj "$P" true > "$FH/.claude.json"
rc=$( cd "$R" && HOME="$FH" PATH="$TR/bin:$PATH" STUB_MARKER="$TR/e1.marker" CLAUDE_CONFIG_DIR="$TR/c-noentry" timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TR/e1.out" 2>&1; echo $? )
check "E1 trust only in ~/.claude.json: refused" "$([ "$rc" != 0 ] && has "$TR/e1.out" "is not trusted")" "yes"
rm -f "$FH/.claude.json"; ( cd "$R" && HOME="$FH" PATH="$TR/bin:$PATH" STUB_MARKER="$TR/e2.marker" CLAUDE_CONFIG_DIR="$TR/c-ok" timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TR/e2.out" 2>&1 )
check "E2 trust only in CLAUDE_CONFIG_DIR: passes" "$(ran "$TR/e2")" "yes"
tj "$P" true > "$FH/.claude.json"; env_unset=$( cd "$R" && env -u CLAUDE_CONFIG_DIR HOME="$FH" PATH="$TR/bin:$PATH" STUB_MARKER="$TR/e3.marker" timeout 60 env KAIZERO_MAX_LOOPS=1 bash "$SCRIPT" --local-merge todo.md -t x > "$TR/e3.out" 2>&1; echo $? )
check "E3 variable unset: reads ~/.claude.json" "$env_unset $(ran "$TR/e3")" "0 yes"

# F — two repositories: only the target counts
T2="$TR/target2"; C2="$TR/coord2"; mk_repo "$T2"; mk_repo "$C2"
PT="$(cd "$T2" && pwd -P)"; PC="$(cd "$C2" && pwd -P)"
cfg "$TR/c-tonly" "$(tj "$PT" true)"; rc=$(launch "$T2" "$TR/c-tonly" "$TR/f1.out" --local-merge "$C2/todo.md" -t x)
check "F1 target trusted, coordination untrusted: passes" "$rc $(ran "$TR/f1.out")" "0 yes"
cfg "$TR/c-conly" "$(tj "$PC" true)"; rc=$(launch "$T2" "$TR/c-conly" "$TR/f2.out" --local-merge "$C2/todo.md" -t x)
check "F2 coordination trusted alone: refused" "$([ "$rc" != 0 ] && has "$TR/f2.out" "is not trusted")" "yes"
check "F2 refusal names the target, not the coordination repository" "$(has "$TR/f2.out" "'$PT'")" "yes"

# G — order: a dirty tree is refused first
D="$TR/dirty"; mk_repo "$D"; echo x > "$D/untracked"
rc=$(launch "$D" "$TR/c-noentry" "$TR/g1.out" --local-merge todo.md -t x)
check "G1 dirty untrusted target: clean-tree refusal wins" "$([ "$rc" != 0 ] && echo "$(has "$TR/g1.out" "is dirty") $(has "$TR/g1.out" "not trusted")")" "yes no"

# H — once per run: a restart after the entry flips to false is not refused
cfg "$TR/c-flip" "$(tj "$P" true)"
rm -f "$TR/h1.marker" "$TR/h1.marker.flipped"
( cd "$R" && PATH="$TR/bin:$PATH" STUB_MARKER="$TR/h1.marker" STUB_FLIP="$TR/c-flip/.claude.json" CLAUDE_CONFIG_DIR="$TR/c-flip" \
    timeout 90 env KAIZERO_MAX_LOOPS=2 bash "$SCRIPT" --local-merge todo.md -t x > "$TR/h1.out" 2>&1 )
check "H1 claude started twice, no trust refusal" "$(wc -l < "$TR/h1.marker" | tr -d ' ') $(has "$TR/h1.out" "not trusted")" "2 no"

# I — doctor and emit skip the check
rc=$( cd "$R" && PATH="$TR/bin:$PATH" CLAUDE_CONFIG_DIR="$TR/c-noentry" timeout 60 bash "$SCRIPT" --doctor --local-merge > "$TR/i1.out" 2>&1; echo $? )
check "I1 --doctor: no trust message" "$(has "$TR/i1.out" "not trusted")" "no"
( cd "$R" && PATH="$TR/bin:$PATH" CLAUDE_CONFIG_DIR="$TR/c-noentry" KAIZERO_TEST_EMIT=1 timeout 60 bash "$SCRIPT" --local-merge todo.md -t x > "$TR/i2.out" 2>&1 )
check "I2 KAIZERO_TEST_EMIT: no trust message" "$(has "$TR/i2.out" "not trusted")" "no"

# J — absence checks on the code and on the operator's real config
check "J1 no new flag or environment variable of its own" "$(sed -n '/^# --- the target must be trusted by claude/,/^fi$/p' "$REAL_SCRIPT" | grep -c 'KAIZERO_[A-Z_]*TRUST\|--trust')" "0"
check "J2 the check calls no jq or python" "$(sed -n '/^# --- the target must be trusted by claude/,/^fi$/p' "$REAL_SCRIPT" | grep -v '^#' | grep -c 'jq\|python')" "0"
check "J3 README Prerequisites mentions trust" "$(sed -n '/^### Prerequisites/,/^### /p' "$REPO/README.md" | grep -c 'trust')" "1"

cd "$TESTROOT"
. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
