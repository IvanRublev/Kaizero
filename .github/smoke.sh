#!/usr/bin/env bash
# smoke.sh — CI dependency smoke test. Runs the OS tools kaizero.sh relies on,
# in the exact argument forms it uses, to catch BSD-vs-GNU divergence (macOS) early.
# ponytail: curated to the real platform-divergent calls, not every command — keep
# in sync when kaizero.sh grows a new tool dependency.
set -euo pipefail

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
ok()   { echo "ok — $*"; }

src="$(cd "$(dirname "$0")/.." && pwd)/kaizero.sh"   # captured before any cd below

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "== env =="
echo "uname:    $(uname -a)"
echo "bash:     $BASH_VERSION"
echo "git:      $(git --version)"
echo "tmp:      $tmp"
echo "== checks =="

# 1. flock — runnable (kaizero.sh:61) + lockfile-command form (:498,509)
flock -n "$(mktemp)" true 2>/dev/null || fail "flock not runnable (-n fd true)"
lock="$tmp/lock"
flock "$lock" true                 || fail "flock <lockfile> <command> form failed"
# mutual exclusion: hold lock in background, non-blocking grab must fail
( flock 9; sleep 2 ) 9>"$lock" &
sleep 0.3
if flock -n 9 9>"$lock"; then fail "flock did not serialize (got a held lock)"; fi
wait
ok "flock"

# 2. instance id — uuidgen | tr -d - | head -c8 (kaizero.sh:120)
id="$(uuidgen 2>/dev/null | tr -d - | head -c8)"
[ "${#id}" -eq 8 ] || fail "uuidgen|tr|head produced '$id' (want 8 chars)"
ok "uuidgen/tr/head -> $id"

# 3. session_id extraction — sed + tr -cd (kaizero.sh:198)
sid="$(printf '%s' '{"session_id": "ab-CD_12"}' \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | tr -cd 'A-Za-z0-9_-')"
[ "$sid" = "ab-CD_12" ] || fail "session_id parse got '$sid' (want ab-CD_12)"
ok "sed/tr session_id"

# 4. process introspection — ps forms (kaizero.sh:206,208,304)
[ -n "$(ps -o comm= -p $$ 2>/dev/null)" ]                        || fail "ps -o comm= empty"
[ -n "$(ps -o ppid= -p $$ 2>/dev/null | tr -d '[:space:]')" ]    || fail "ps -o ppid= empty"
st1="$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')"
[ -n "$st1" ]                                                    || fail "ps -o lstart= empty"
st2="$(ps -o lstart= -p $$ 2>/dev/null | awk '{$1=$1;print}')"
[ "$st1" = "$st2" ]                                              || fail "ps -o lstart= not stable ('$st1' vs '$st2')"
ok "ps comm/ppid/lstart"

# 5. epoch seconds — date +%s (kaizero.sh:304 area / timing)
now="$(date +%s)"; case "$now" in ''|*[!0-9]*) fail "date +%s -> '$now'";; esac
ok "date +%s"

# 6. git worktree lifecycle — add <path> -b <branch> <start> / add -b <branch> <path> <start>
#    (make_target_wt's `track` mode, BUG 048 — the ref it checks out is one this claim's own
#    fetch resolved, `refs/remotes/origin/<branch>`, never `--track`/upstream resolution) /
#    repair / remove --force / prune
repo="$tmp/repo"; mkdir "$repo"; cd "$repo"
git init -q; git config user.email ci@ci; git config user.name ci
git commit -q --allow-empty -m init
base="$(git rev-parse --abbrev-ref HEAD)"
wt="$tmp/repo-task-1"
flock "$repo/.wtlock" git worktree add "$wt" -b "$base-task-1" "$base" >/dev/null 2>&1 \
  || fail "git worktree add <path> -b <branch> failed"
[ -d "$wt" ] || fail "worktree dir missing after add"
flock "$repo/.wtlock" git worktree repair "$wt" >/dev/null 2>&1 || fail "git worktree repair failed"
flock "$repo/.wtlock" git worktree remove --force "$wt"        || fail "git worktree remove --force failed"
wtt="$tmp/repo-task-track"
flock "$repo/.wtlock" git worktree add -b "$base-task-track" "$wtt" "refs/heads/$base" >/dev/null 2>&1 \
  || fail "git worktree add -b <branch> <path> <ref> failed"
[ -d "$wtt" ] || fail "worktree dir missing after add -b <branch> <path> <ref>"
flock "$repo/.wtlock" git worktree remove --force "$wtt"       || fail "git worktree remove --force (2) failed"
# make_target_wt's `track` mode (BUG 048): checks out an EXISTING branch this claim's own fetch
# just resolved — no `-b`, never `--track`/upstream resolution, so an existing branch name alone
# must resolve as a worktree start point.
git branch "$base-task-existing" "$base"
wte="$tmp/repo-task-existing"
flock "$repo/.wtlock" git worktree add "$wte" "$base-task-existing" >/dev/null 2>&1 \
  || fail "git worktree add <path> <existing-branch> (no -b) failed"
[ -d "$wte" ] || fail "worktree dir missing after add <path> <existing-branch>"
flock "$repo/.wtlock" git worktree remove --force "$wte"       || fail "git worktree remove --force (3) failed"
git worktree prune                                             || fail "git worktree prune failed"
ok "git worktree add/repair/remove/prune"

# 7. main-worktree root — git worktree list --porcelain | sed -n '1s/^worktree //p' (kaizero.sh:191)
#    First porcelain entry must be the MAIN worktree even when read from inside a linked one,
#    which is what makes the root guard refuse a launch in a leftover ../ts-* worktree (BUG-014).
main_root="$(cd "$repo" && pwd -P)"
[ "$(git -C "$repo" worktree list --porcelain | sed -n '1s/^worktree //p')" = "$main_root" ] \
  || fail "porcelain/sed main-root form failed from the main worktree"
wt2="$tmp/repo-task-2"
git -C "$repo" worktree add "$wt2" -b "$base-task-2" "$base" >/dev/null 2>&1 || fail "worktree add for root check failed"
[ "$(cd "$wt2" && git worktree list --porcelain | sed -n '1s/^worktree //p')" = "$main_root" ] \
  || fail "porcelain/sed answered the linked worktree instead of the main one"
git -C "$repo" worktree remove --force "$wt2" >/dev/null 2>&1
ok "git worktree list --porcelain | sed main-root"

# 8. token accounting — transcript_path sed (kaizero.sh:243) + the usage awk (kaizero.sh:304).
# The awk must dedupe by requestId and take the PARENT field on each line, never the
# usage.iterations[] copy or the cache_creation ephemeral leaves.
tp="$(printf '%s' '{"transcript_path": "/a b/c.jsonl"}' \
  | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[ "$tp" = "/a b/c.jsonl" ] || fail "transcript_path parse got '$tp'"
u='"input_tokens":10,"cache_creation_input_tokens":248,"cache_read_input_tokens":1000,"output_tokens":20,"cache_creation":{"ephemeral_5m_input_tokens":148,"ephemeral_1h_input_tokens":100},"iterations":[{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":1000,"cache_creation_input_tokens":248}]'
for _ in 1 2; do printf '{"requestId":"req_A","message":{"usage":{%s}}}\n' "$u"; done > "$tmp/t.jsonl"
sums="$(awk '
  function num(key,   s) {
    if (!match($0, "\"" key "\":[0-9]+")) return 0
    s = substr($0, RSTART, RLENGTH); sub(/.*:/, "", s); return s + 0
  }
  /"output_tokens":/ {
    k = match($0, /"requestId":"[^"]+"/) ? substr($0, RSTART + 13, RLENGTH - 14) : "line" NR
    if (k in seen) next
    seen[k] = 1; n++
    i  += num("input_tokens");                o  += num("output_tokens")
    cc += num("cache_creation_input_tokens"); cr += num("cache_read_input_tokens")
  }
  END { if (n) printf "%d %d %d %d %d\n", i, o, cc, cr, i + o + cc + cr }' "$tmp/t.jsonl")"
[ "$sums" = "10 20 248 1000 1278" ] || fail "usage awk got '$sums' (want '10 20 248 1000 1278')"
ok "sed transcript_path / awk usage dedupe"

# 9. KAIZERO_LINK symlink — plain POSIX `ln -s target link` (kaizero.sh link_ignored).
#    BSD and GNU ln agree on the two-argument form and diverge on -r/-f/-n, which is why none are
#    used. The guard is `[ ! -e ] && [ ! -L ]`: -e FOLLOWS the link, so a dangling link reads as
#    absent and an unguarded ln would die "File exists".
ldir="$tmp/linksrc"; mkdir -p "$ldir"; echo "criterion" > "$ldir/spec.md"
ln -s "$ldir" "$tmp/link"                       || fail "ln -s <dir> <name> failed"
[ -L "$tmp/link" ]                              || fail "-L did not see the symlink"
[ "$(cat "$tmp/link/spec.md")" = criterion ]    || fail "read through symlink failed"
ln -s "$tmp/nowhere" "$tmp/dangling"            || fail "ln -s to a missing target failed"
[ -L "$tmp/dangling" ]                          || fail "-L did not see the dangling link"
if [ -e "$tmp/dangling" ]; then fail "-e followed a dangling link (guard would misfire)"; fi
ok "ln -s / -L / -e guard"

# 10. context-rot guard's field extraction / threshold resolution (kaizero.sh's Stop hook).
# `grep -noE` feeds short per-field `LINE:"key":value` lines into the table-matcher awk — never
# the raw record — so this exercises: ENVIRON[] escapes surviving intact (a `-v` hand-off would
# expand `\[1m\]` into the character class `[1m]`, matching bare "1"/"m"); dynamic regex matching
# a version-suffixed family id while a word-suffix tier ("-mini") falls through to the default
# (split(s,a," ") whitespace-run parsing, blank table lines dropped, exercised via CZ_TABLE's own
# leading/trailing blank lines below); and match-based field extraction surviving a `tail -c` cut
# that lands mid-JSON, dropping `model` while the `usage` object (which trails it) survives.
CZT='
  \[1m\]                                                200000
  claude-fable-5(-[0-9]|[^A-Za-z0-9-])                  200000
'
guard_verdict() {   # $1 = raw bytes: a JSONL record, or a `tail -c`-cropped fragment of one
  printf '%s' "$1" \
    | grep -noE '"model":"[^"]*"|"input_tokens":[0-9]+|"cache_read_input_tokens":[0-9]+|"cache_creation_input_tokens":[0-9]+|"output_tokens":[0-9]+' \
    | CZ_TABLE="$CZT" CZ_DEFAULT=160000 awk '
      BEGIN {
        def = ENVIRON["CZ_DEFAULT"] + 0
        n = split(ENVIRON["CZ_TABLE"], tln, "\n")
        for (i = 1; i <= n; i++) {
          if (split(tln[i], f, " ") < 2) continue
          tn++; pat[tn] = f[1]; thr[tn] = f[2] + 0
        }
      }
      {
        if (!match($0, /^[0-9]+:/)) next
        L = substr($0, 1, RLENGTH - 1); rest = substr($0, RLENGTH + 1)
        if (!match(rest, /^"[a-zA-Z_]+":/)) next
        key = substr(rest, 2, RLENGTH - 3); val = substr(rest, RLENGTH + 1)
        if ((L, key) in seen) next
        seen[L, key] = 1
        if (key == "model") { sub(/^"/, "", val); sub(/"$/, "", val); mdl[L] = val; next }
        if (key == "output_tokens") { saw_out[L] = 1; next }
        tot[L] += val + 0
      }
      END {
        best = ""
        for (L in saw_out) { if ((tot[L]+0) > 0 && (best == "" || (L+0) > (best+0))) best = L }
        if (best == "") { print 0; exit }
        id = mdl[best] " "
        th = def
        for (i = 1; i <= tn; i++) { if (id ~ pat[i]) { th = thr[i]; break } }
        print (((tot[best]+0) >= th) ? 1 : 0)
      }'
}

REC_MINI='{"model":"claude-fable-5-mini","input_tokens":9000,"cache_read_input_tokens":170000,"cache_creation_input_tokens":1000,"output_tokens":500}'
[ "$(guard_verdict "$REC_MINI")" = 1 ] || fail "claude-fable-5-mini at 180000: default (160000) should fire; a -v hand-off would corrupt \\[1m\\] into a class matching mini's 'm' and wrongly give 0"

REC_VER='{"model":"claude-fable-5-20260115-v1:0","input_tokens":9000,"cache_read_input_tokens":170000,"cache_creation_input_tokens":1000,"output_tokens":500}'
[ "$(guard_verdict "$REC_VER")" = 0 ] || fail "claude-fable-5-20260115-v1:0 at 180000 should keep the family row (200000), not the default"

REC_FULL='{"model":"claude-fable-5","content":"PADDING","input_tokens":9000,"cache_read_input_tokens":170000,"cache_creation_input_tokens":1000,"output_tokens":500}'
[ "$(guard_verdict "$REC_FULL")" = 0 ] || fail "uncropped record should resolve its family row"
cropped="$(printf '%s' "$REC_FULL" | tail -c 110)"
[ "$(guard_verdict "$cropped")" = 1 ] || fail "a tail -c cut mid-JSON that drops 'model' should degrade to the default, not stay unmatched"

ok "context-rot guard: grep -n -o extraction, ENVIRON[] escapes, dynamic regex, tail -c mid-JSON cut"

# 11. one-glyph symbol guard — merge_task's shape (ISSUE-039b's glyph_count/symbol_ok): exactly
# one glyph, which may be several bytes (od byte-value counting, never bash's own `${#}` — that
# counts bytes under LC_ALL=C and characters under a UTF-8 locale, so it gives a different verdict
# on a multi-byte symbol depending on which locale launched the shell).
glyph_count() { printf '%s' "$1" | od -An -v -tu1 | tr -s ' \n' '\n' | awk 'NF && ($1<128 || $1>191){c++} END{print c+0}'; }
sym_ok() { [ "$(glyph_count "$1")" -eq 1 ] && [ "$1" != ' ' ] && [ "$1" != ']' ]; }
for loc in C en_US.UTF-8; do
  LC_ALL="$loc" sym_ok x   || fail "[$loc] sym_ok rejected a valid 1-char symbol 'x'"
  LC_ALL="$loc" sym_ok '?' || fail "[$loc] sym_ok rejected a valid 1-char symbol '?'"
  LC_ALL="$loc" sym_ok '✓' || fail "[$loc] sym_ok rejected the multi-byte glyph ✓"
  if LC_ALL="$loc" sym_ok ' ';  then fail "[$loc] sym_ok accepted a space"; fi
  if LC_ALL="$loc" sym_ok ']';  then fail "[$loc] sym_ok accepted ']'"; fi
  if LC_ALL="$loc" sym_ok 'xx'; then fail "[$loc] sym_ok accepted a 2-char symbol"; fi
done
ok "one-glyph symbol guard, byte-counted: same verdict under LC_ALL=C and en_US.UTF-8, including a multi-byte glyph"

# 12. todo dirty guard — git diff --quiet HEAD -- <path> (kaizero.sh merge_task).
printf '# todo\n\n- [ ] task one\n' > "$repo/todo.md"
git -C "$repo" add todo.md && git -C "$repo" commit -q -m 'add todo'
git -C "$repo" diff --quiet HEAD -- todo.md || fail "git diff --quiet on a clean tracked file reported dirty"
printf -- '- [ ] task two\n' >> "$repo/todo.md"
if git -C "$repo" diff --quiet HEAD -- todo.md; then fail "git diff --quiet did not see the uncommitted edit"; fi
git -C "$repo" checkout -- todo.md
ok "git diff --quiet HEAD -- <path> dirty/clean"

# 13. tick rewrite — merge_task's box-flip: fence-aware id match, symbol via ENVIRON (never -v,
# never in a regex — a `-v` hand-off decodes backslash escapes, eating a `\` symbol), substr
# replacement, everything else byte-exact, temp file + mv, trailing-newline-or-not preserved.
tick() {   # $1 = input file, $2 = id, $3 = symbol -> result on stdout
  local f="$1" id="$2" sym="$3" out="$tmp/tick.out.$$"
  SYM="$sym" awk -v id="$id" '
    BEGIN { sym = ENVIRON["SYM"] }
    /^[ \t]*```/ { fence = !fence; print; next }
    fence        { print; next }
    !done && /^[ \t]*- \[ \]/ {
      line = $0
      sub(/^[ \t]*- \[/, "", line)
      rest = line; sub(/^ \][ \t]*/, "", rest)
      split(rest, a, /[ \t]/)
      if (a[1] == id) {
        p = index($0, "[")
        print substr($0, 1, p) sym substr($0, p + 2)
        done = 1
        next
      }
    }
    { print }
  ' "$f" > "$out"
  if [ -z "$(tail -c1 "$f")" ]; then : ; else printf '%s' "$(cat "$out")" > "$out.2" && mv "$out.2" "$out"; fi
  cat "$out"; rm -f "$out"
}

fixture="$tmp/fixture.md"
# shellcheck disable=SC2016 # literal printf format string, nothing here is meant to expand
printf -- '- [ ] A first task\n\n```\n- [ ] A example inside a fence\n```\n\n- [ ] B second task\n' > "$fixture"
# shellcheck disable=SC1003 # a single-quoted literal backslash, not an escape attempt
for sym in x '?' '*' '.' '\'; do
  out="$(tick "$fixture" B "$sym")"
  printf '%s\n' "$out" | grep -qF -- "- [$sym] B second task" || fail "tick with symbol '$sym' did not produce the expected box"
  printf '%s\n' "$out" | grep -qF -- '- [ ] A example inside a fence' || fail "tick with symbol '$sym' touched the fenced example box"
done
ok "tick rewrite: symbols x ? * . \\, fence untouched"

# fence-aware id match on an id COLLISION: the fenced decoy shares the real task's own id ("A"),
# so removing either fence rule from the tick rewrite ticks the decoy too and this fails.
out="$(tick "$fixture" A x)"
printf '%s\n' "$out" | grep -qF -- '- [x] A first task' || fail "tick of id A did not flip the real A line"
printf '%s\n' "$out" | grep -qF -- '- [ ] A example inside a fence' || fail "tick of id A flipped the fenced decoy sharing its id"
ok "tick rewrite: id collision with a fenced decoy ticks only the real line"

nlfile="$tmp/nl.md"; printf -- '- [ ] C third task\n' > "$nlfile"
[ -n "$(tail -c1 "$nlfile")" ] && fail "fixture setup: nl.md should end with a trailing newline"
tick "$nlfile" C x > "$tmp/nl.out"
[ -n "$(tail -c1 "$tmp/nl.out")" ] && fail "tick added a trailing newline to a file that had one"
ok "tick rewrite preserves an existing trailing newline"

# 13b. retick rewrite — ISSUE-039b's tick_box `retick` path, extracted straight from kaizero.sh
# (never a hand-copied replica — a copy guards nothing when the source drifts): the box's byte
# length comes from match/RLENGTH (never assumed 1), so a multi-byte `[↑]` rewrites correctly; the
# arithmetic must reduce to 13's fixed-offset expression for a one-byte box, which 13 above already
# proves. A multi-line fixture, so the untouched lines and the rewritten line's own remainder (the
# text after the box) are asserted byte-exact too, not just the id's own box.
eval "$(sed -n '/^tick_box() {/,/^}/p' "$src")"

tickrepo="$tmp/tickrepo"; mkdir "$tickrepo"
git -C "$tickrepo" init -q; git -C "$tickrepo" config user.email ci@ci; git -C "$tickrepo" config user.name ci
printf -- '- [ ] A untouched before\n- [\xe2\x86\x91] D fourth task, remainder text\n- [x] Z untouched after\n' > "$tickrepo/todo.md"
git -C "$tickrepo" add todo.md; git -C "$tickrepo" commit -q -m todo

# shellcheck disable=SC2034 # read by tick_box, eval'd above from kaizero.sh, invisible to static analysis
COORD_ROOT="$tickrepo" TODO_PATH=todo.md TODO_ABS="$tickrepo/todo.md"
before="$(git -C "$tickrepo" rev-parse HEAD)"
before_content="$(cat "$tickrepo/todo.md")"
tick_box D y >/dev/null   # merge-retry shape: no retick, box already landed
[ "$(cat "$tickrepo/todo.md")" = "$before_content" ] || fail "retick: a no-retick call over a landed box touched the file"
[ "$(git -C "$tickrepo" rev-parse HEAD)" = "$before" ] || fail "retick: a no-retick call over a landed box committed"

tick_box D x retick >/dev/null
want="$(printf -- '- [ ] A untouched before\n- [x] D fourth task, remainder text\n- [x] Z untouched after\n')"
[ "$(cat "$tickrepo/todo.md")" = "$want" ] || fail "retick over a multi-byte [↑] box did not rewrite only that line's box, byte-exact elsewhere"
[ "$(git -C "$tickrepo" log -1 --format=%s)" = "zero sync D" ] || fail "retick did not commit 'zero sync D'"
ok "retick rewrite: multi-byte box -> one-byte symbol"

nonlfile="$tmp/nonl.md"; printf -- '- [ ] D fourth task' > "$nonlfile"
[ -n "$(tail -c1 "$nonlfile")" ] || fail "fixture setup: nonl.md should have no trailing newline"
tick "$nonlfile" D x > "$tmp/nonl.out"
[ -n "$(tail -c1 "$tmp/nonl.out")" ] || fail "tick did not preserve the missing trailing newline"
[ "$(cat "$tmp/nonl.out")" = "- [x] D fourth task" ] || fail "tick on the no-trailing-newline fixture produced unexpected content"
ok "tick rewrite preserves a missing trailing newline"

# 14. coordination/target role detection (ISSUE-038a): the nesting check's git calls, and
# physical-path resolution under a symlinked tmpdir.
nestrepo="$tmp/nest-outer"; mkdir -p "$nestrepo/inner"
git -C "$nestrepo" init -q; git -C "$nestrepo" config user.email ci@ci; git -C "$nestrepo" config user.name ci
git -C "$nestrepo/inner" init -q; git -C "$nestrepo/inner" config user.email ci@ci; git -C "$nestrepo/inner" config user.name ci
git -C "$nestrepo/inner" commit -q --allow-empty -m init
# 14a. check-ignore -q — the allowed-when-ignored path of the nesting check.
if git -C "$nestrepo" check-ignore -q inner; then fail "check-ignore -q answered yes before inner/ was ignored"; fi
echo 'inner/' > "$nestrepo/.gitignore"
git -C "$nestrepo" check-ignore -q inner || fail "check-ignore -q did not see inner/ after it was ignored"
ok "git check-ignore -q"
# 14b. ls-files --stage mode 160000 — the allowed-when-submodule path of the nesting check.
git -C "$nestrepo" rm -q --cached inner >/dev/null 2>&1 || true   # never staged; drop any accidental add
git -C "$nestrepo" -c protocol.file.allow=always submodule add -q "$nestrepo/inner" sub >/dev/null 2>&1 \
  || fail "git submodule add failed"
mode="$(git -C "$nestrepo" ls-files --stage -- sub | awk '{print $1}')"
[ "$mode" = 160000 ] || fail "ls-files --stage on a submodule gave mode '$mode' (want 160000)"
ok "git ls-files --stage mode 160000"
# 14c. pwd -P — physical resolution the root-guard and coordination/target comparisons rely on
# (a logical mktemp path under a symlinked /tmp never prefix-matches git's physical worktree roots).
physical="$(cd "$tmp" && pwd -P)"
case "$physical" in /*) : ;; *) fail "pwd -P did not return an absolute path: '$physical'" ;; esac
[ -d "$physical" ] || fail "pwd -P path '$physical' does not exist"
ok "pwd -P physical path resolution"
# 14d. the main-worktree discriminator (kaizero.sh's wt_root: `git rev-parse --show-cdup`,
# resolved physically with pwd -P — never `git worktree list --porcelain`'s "main" entry, which
# answers the git directory instead of the working tree whenever core.worktree is unset, on a
# `git init --separate-git-dir=…` repository: the working-tree root, never the git directory.
sgdroot="$tmp/sgd-root"; sgddir="$tmp/sgd-gitdir"; mkdir -p "$sgdroot"
git init -q --separate-git-dir="$sgddir" "$sgdroot" >/dev/null
git -C "$sgdroot" config user.email ci@ci; git -C "$sgdroot" config user.name ci
git -C "$sgdroot" commit -q --allow-empty -m init
sgdphys="$(cd "$sgdroot" && pwd -P)"
[ "$(git -C "$sgdroot" worktree list --porcelain | sed -n '1s/^worktree //p')" != "$sgdphys" ] \
  || fail "fixture invalid: worktree list --porcelain already answered the working tree root — this case no longer exercises the fallback wt_root exists for"
sgdcdup="$(git -C "$sgdroot" rev-parse --show-cdup)"
[ "$(cd "$sgdroot/$sgdcdup" && pwd -P)" = "$sgdphys" ] \
  || fail "show-cdup did not resolve a --separate-git-dir repository's working tree root"
ok "main-worktree discriminator (show-cdup) on a --separate-git-dir repository"
# 14e. same discriminator on the git-submodule-add submodule from 14b: its own worktree root,
# not the superproject's .git/modules/<name> gitdir the submodule's .git file points at.
subphys="$(cd "$nestrepo/sub" && pwd -P)"
subcdup="$(git -C "$nestrepo/sub" rev-parse --show-cdup)"
[ "$(cd "$nestrepo/sub/$subcdup" && pwd -P)" = "$subphys" ] \
  || fail "show-cdup did not resolve a git submodule add submodule's working tree root"
ok "main-worktree discriminator (show-cdup) on a git submodule add submodule"

# 15. target branch naming/matching (ISSUE-038b): cut -c1-40 slug truncation, and the bash `case`
# id-prefix primitive target_branches_for_id is built on — never git for-each-ref's own refname
# globbing, whose bare '*' stops at '/' and would silently drop a slash-bearing branch.
long="$(printf 'x%.0s' $(seq 1 60))"
cut40="$(printf '%s' "$long" | cut -c1-40)"
[ "${#cut40}" -eq 40 ] || fail "cut -c1-40 on a 60-char string gave ${#cut40} chars (want 40)"
[ "$cut40" = "$(printf 'x%.0s' $(seq 1 40))" ] || fail "cut -c1-40 did not take the first 40 chars"
ok "cut -c1-40 slug truncation"

n=SMTH-8; cand=SMTH-85-other
case "$cand" in "$n"|"$n"-*)
  fail "bash case id-prefix match included SMTH-85-other under id SMTH-8 (trailing '-' must exclude it)" ;;
esac
ok "bash case id-prefix match excludes SMTH-85-other under id SMTH-8 (trailing dash)"

n=SMTH-855; cand=SMTH-855-foo/bar
case "$cand" in
  "$n"|"$n"-*) : ;;
  *) fail "bash case id-prefix match excluded SMTH-855-foo/bar under id SMTH-855 (a '/' after '<id>-' must not exclude it)" ;;
esac
ok "bash case id-prefix match includes SMTH-855-foo/bar under id SMTH-855 (slash does not stop it)"

# 16. git worktree prune (ISSUE-038c): claim's recovery when a tt-… or ts-… directory is deleted
# by hand while its registry entry survives — prune must clear the stale entry so a fresh
# `worktree add` on the same branch does not fail "already checked out".
pr="$tmp/prune"; mkdir "$pr"
git -C "$pr" init -q -b main; git -C "$pr" config user.email ci@ci; git -C "$pr" config user.name ci
git -C "$pr" commit -q --allow-empty -m init
git -C "$pr" worktree add -q "$pr/wt" -b prune-branch >/dev/null
rm -rf "$pr/wt"
before=$(git -C "$pr" worktree list --porcelain | grep -c '^worktree ')
[ "$before" -eq 2 ] || fail "worktree list --porcelain lost the deleted worktree's registry entry before prune ran (count $before, want 2)"
git -C "$pr" worktree list --porcelain | grep -qxF 'prunable gitdir file points to non-existent location' \
  || fail "worktree list --porcelain did not flag the hand-deleted worktree as prunable"
git -C "$pr" worktree prune
after=$(git -C "$pr" worktree list --porcelain | grep -c '^worktree ')
[ "$after" -eq 1 ] || fail "git worktree prune left a stale registry entry for a directory deleted by hand (count $after, want 1)"
git -C "$pr" worktree add -q "$pr/wt2" prune-branch \
  || fail "worktree add on the same branch failed after prune cleared the stale entry"
ok "git worktree prune clears a hand-deleted worktree's registry entry"

# 17. land gate (ISSUE-038d): merge-base --is-ancestor (test 2, "already on base") and diff
# --quiet A...B (test 3, "carries no change") — the two git primitives the gate is built from.
lgr="$tmp/landgate"; mkdir "$lgr"
git -C "$lgr" init -q -b main; git -C "$lgr" config user.email ci@ci; git -C "$lgr" config user.name ci
git -C "$lgr" commit -q --allow-empty -m base
git -C "$lgr" branch merged-in            # tip left right here: an ancestor of main once main advances
git -C "$lgr" commit -q --allow-empty -m 'main moves on'
git -C "$lgr" merge-base --is-ancestor merged-in main \
  || fail "merge-base --is-ancestor said an ancestor branch was NOT an ancestor of main"
git -C "$lgr" checkout -q -b empty-branch main
git -C "$lgr" merge -q --no-ff -m 'fold main back in' main   # only merges base back in — no new content
git -C "$lgr" diff --quiet main...HEAD \
  || fail "diff --quiet main...HEAD was non-empty for a branch that only merged main back in"
git -C "$lgr" checkout -q -b real-branch main
echo change > "$lgr/f"; git -C "$lgr" add f; git -C "$lgr" commit -q -m change
git -C "$lgr" diff --quiet main...HEAD \
  && fail "diff --quiet main...HEAD was empty for a branch carrying real content"
ok "git merge-base --is-ancestor / git diff --quiet A...B (land gate tests 2 and 3)"

# 18. forge argument surface (ISSUE-039d): every flag mr_list/mr_create pass, asserted present in
# the real CLI's own --help — a rename would otherwise surface as a task failing to land
# mid-fleet. The list here is read off mr_list/mr_create in kaizero.sh, kept in sync by hand
# like every other curated check in this file. SMOKE_SKIP_FORGE=1 skips this one check for an
# offline laptop; CI never sets it.
if [ -n "${SMOKE_SKIP_FORGE:-}" ]; then
  echo "skip — forge argument surface (SMOKE_SKIP_FORGE=1)"
else
  command -v gh   >/dev/null 2>&1 || fail "gh not found on PATH (required unless SMOKE_SKIP_FORGE=1)"
  command -v glab >/dev/null 2>&1 || fail "glab not found on PATH (required unless SMOKE_SKIP_FORGE=1)"

  assert_flag() {   # $1 = "tool subcommand" (its own --help), $2 = flag to find
    local help; help="$($1 --help 2>&1)" || true
    printf '%s' "$help" | grep -qF -- "$2" || fail "$1 --help does not list '$2'"
  }

  # mr_list's flags.
  for f in --repo --head --state --limit --json; do assert_flag "gh pr list" "$f"; done
  for f in --repo --source-branch --all --output --per-page --order --sort; do assert_flag "glab mr list" "$f"; done

  # mr_create's flags — the non-interactive ones included, since a create that can prompt hangs
  # a session to the watchdog.
  for f in --repo --head --base --title --body-file; do assert_flag "gh pr create" "$f"; done
  for f in --repo --source-branch --target-branch --title --description --yes; do assert_flag "glab mr create" "$f"; done

  # gh pr list --json's own field list — the same rename hazard one level down. Given no value,
  # gh exits 1 and prints the field list on STDERR with stdout empty: read stderr, ignore the
  # (expected non-zero) status — a check that greps stdout finds nothing and passes vacuously.
  ghfields="$(gh pr list --json 2>&1 >/dev/null || true)"
  for f in number headRefOid baseRefName state url; do
    printf '%s' "$ghfields" | grep -qF -- "$f" || fail "gh pr list --json field list missing '$f'"
  done

  # 039c's own probe.
  assert_flag "gh auth status" --hostname
  assert_flag "glab auth status" --hostname

  ok "forge argument surface: gh/glab pr|mr list|create flags, gh --json field list, auth status --hostname"
fi

# 19. `ps -Ao pid=,ppid=` combined-column form (BUG 058k: terminator.sh's descendant walk — the
# only place kaizero.sh now uses `ps -A`, every other ps check above is single-pid `-p $$`).
# Resolves a known parent/child pair the way the downstream `awk '$2==p{print $1}'` filtering does.
sleep 60 & child=$!
disown "$child" 2>/dev/null || true
found="$(ps -Ao pid=,ppid= 2>/dev/null | awk -v p=$$ '$2==p{print $1}' | tr '\n' ' ')"
kill "$child" 2>/dev/null || true
case " $found " in *" $child "*) : ;; *) fail "ps -Ao pid=,ppid= | awk '\$2==p{print \$1}' did not resolve child $child of parent $$ (got '$found')" ;; esac
ok "ps -Ao pid=,ppid= combined-column output resolves a known parent/child pair"

# 20. `stat` BSD vs GNU forms (BUG 058k: transcript_mtime/newest_mtime's STAT_MTIME fallback uses
# -f %m / -c %Y; the todo-box tick-rewrite path's permission-bit read uses -f %Lp / -c %a).
# kaizero.sh already falls back between the two at each call site; this just proves whichever
# form the current host actually has produces a usable value.
sf="$tmp/stat-test"; : > "$sf"; chmod 644 "$sf"
mt="$(stat -c %Y "$sf" 2>/dev/null || stat -f %m "$sf" 2>/dev/null || true)"
case "$mt" in ''|*[!0-9]*) fail "neither 'stat -c %Y' nor 'stat -f %m' produced a usable mtime (got '$mt')" ;; esac
perm="$(stat -c %a "$sf" 2>/dev/null || stat -f %Lp "$sf" 2>/dev/null || true)"
case "$perm" in ''|*[!0-9]*) fail "neither 'stat -c %a' nor 'stat -f %Lp' produced a usable permission mode (got '$perm')" ;; esac
ok "stat -c %Y/-f %m mtime and -c %a/-f %Lp permission mode both resolve to a usable value"

# 21. `timeout` present and runnable (BUG 058k: network_reachable uses it unguarded, with no
# presence check anywhere the way flock/git/the forge CLI already get one — stock macOS ships no
# `timeout` binary, and a missing one fails "command not found" in a way network_reachable's
# catch-all currently misreads as a transient network outage rather than a missing prerequisite).
command -v timeout >/dev/null 2>&1 || fail "timeout not found on PATH — network_reachable would silently misread this as a transient outage"
timeout 2 true || fail "timeout 2 true did not succeed (want exit 0 well inside the 2s budget)"
ok "timeout present and runnable"

echo "SMOKE PASS ($(uname -s), bash $BASH_VERSION)"
