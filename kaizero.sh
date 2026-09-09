#!/usr/bin/env bash
# kaizero.sh — run claude with a predefined first prompt in an endless loop.
#
# prerequisite: flock (brew install flock), runnable not just present. Serializes cross-instance
# merges and worktree rescues; without it parallel zeroing races and corrupts the base.

# Run -h for usage.
set -euo pipefail

VERSION="0.1.2"
PROG="$(basename "$0")"   # name shown in usage/errors, from how the script was invoked

# lowest released version of each forge CLI known to carry every flag/field assert_forge_flags
# and mr_list/mr_create depend on — named as the fix in that check's failure messages. gh:
# `headRefOid` in `pr list --json`'s field list is the binding constraint
# (earliest tag carrying it is v2.18.0; --body-file/--json/--head are all older still). glab:
# --order/--sort on `mr list`, absent in v1.52.0, present in v1.53.0 (2025-02-14) — every other
# glab flag here predates that. Kept in sync by hand alongside assert_forge_flags's own flag list
# and .github/smoke.sh check 18, same convention.
MIN_GH_VERSION="2.18.0"
MIN_GLAB_VERSION="1.53.0"

# Which `script` invocation shape allocates claude a pty. macOS/BSD's `script -q FILE
# cmd args...` takes the command as a normal argv; util-linux's `-c` mode takes ONE shell command
# string instead, so building it needs its own quoting step (see build_claude_cmd_string below).
# Resolved once here, not per launch — the host doesn't change mid-run.
case "$(uname)" in
    Darwin) PTY_STYLE=bsd ;;
    *)      PTY_STYLE=util-linux ;;
esac

RESTART_WAIT="${KAIZERO_RESTART_WAIT:-5}" # seconds between claude restarts — the window to press Ctrl+C
WAIT_TICK="${KAIZERO_WAIT_TICK:-5}" # seconds between claimable-Task probes while every unchecked Task is peer-held
WAIT_FRAME=1         # seconds per spinner frame on a terminal — one |/-\ revolution every 4
WAIT_STEP=5          # seconds the terminal's elapsed clock advances in — at 1Hz a live clock is noise
LOG_TICK="${KAIZERO_LOG_TICK:-20}" # seconds between waiting lines when stdout is a log or a pipe, not a terminal
WATCHDOG_DEFAULT=15m # KAIZERO_WATCHDOG default: how long claude may burn no CPU before it is killed
WATCHDOG_GRACE="${KAIZERO_WATCHDOG_GRACE:-10}" # seconds the watchdog waits after its SIGTERM before escalating to SIGKILL
DEPENDENCY_WAIT_DEFAULT=10m # KAIZERO_DEPENDENCY_WAIT default: ceiling on the no-claim wait below
REVIEW_POLL_DEFAULT=5m      # KAIZERO_REVIEW_POLL default: how often a park syncs the forge
FORGE_AUTH_RETRY_WAIT="${KAIZERO_FORGE_AUTH_RETRY_WAIT:-2}" # seconds forge_auth_ok waits between its own retries
NETWORK_PROBE_TIMEOUT=10    # seconds a reachability probe (BUG-047) may block — bounds a
                            # black-holed route or a stuck credential prompt well under a bare
                            # TCP connect timeout (75s+ on macOS)

# The braces around the pipe reader in the logging example are load-bearing — do NOT tidy them
# into a bare pipe. Ctrl+C signals the whole foreground group; the reader's default SIGINT action
# is terminate, and once it dies the log has no writer left, losing exactly the closing report the
# operator ran the pipe for. `trap '' INT` sets *ignore*, which survives `exec`, so the reader
# inherits it and drains the pipe until Kaizero exits.
usage() {
  # single-quoted heredoc keeps backticks literal; sed injects the RESTART_WAIT constant.
  sed -e "s/@@RESTART_WAIT@@/$RESTART_WAIT/g" -e "s/@@PROG@@/$PROG/g" -e "s/@@VERSION@@/$VERSION/g" \
      -e "s/@@WATCHDOG_DEFAULT@@/$WATCHDOG_DEFAULT/g" \
      -e "s/@@DEPENDENCY_WAIT_DEFAULT@@/$DEPENDENCY_WAIT_DEFAULT/g" <<'USAGE'
usage: @@PROG@@ [todo-file-path] [--local-merge] [--always-on] [--no-co-authorship] [-t|--taskprompt TEXT]
version @@VERSION@@

  Loops claude to zero a Markdown Release Todo List — fork a worktree per Task, implement,
  commit, and hand it to review as a pull/merge request or merge it locally; the Task's
  box is ticked once it lands on the base branch — restart on fresh context, until every
  box is checked. Run several in parallel; they claim Tasks via git worktrees. Ctrl+C in
  the @@RESTART_WAIT@@s gap stops.

  todo-file-path              The Release Todo List to zero. Omitted → prompted for it.
  -t, --taskprompt TEXT       Alterations appended after step c's fixed per-Task instruction
                              (follow setup, tick and commit, both gates). Empty by default.
      --local-merge           Land each Task as a local merge instead of a pull/merge
                              request, skipping the origin read entirely. It merges
                              straight to the base branch with no review step — review
                              the commits it produces afterward.
      --always-on             Park instead of exiting once every Task has Landed;
                              resumes the moment a new commit — not just a saved
                              file — adds an unchecked Task to the Release Todo
                              List. KAIZERO_MAX_LOOPS still applies.
      --no-co-authorship      Skip the Kaizero co-author trailer this run would
                              otherwise add to every commit made in a Task worktree.
      --doctor
      --doctor --local-merge  Check prerequisites, then exit. On its own it also
                              makes the same origin/forge decision a launch does and
                              runs the forge checks (run from the target root);
                              --local-merge stops at the generic checks and reads no
                              origin.
  -h, --help                  Show this help.

  Layout: stand in the code repository and pass the Release Todo List's path. The todo inside
  that same repository is the one-repository fork-merge layout, and runs under --local-merge
  only — a merge request has nowhere to go from a repository that also holds the Release Todo
  List. The todo in a different repository makes that one the coordination repository and the
  code repository the target; code stays on a branch in the target until it lands.

  Branches: a branch named exactly <id>, or starting <id>-, is that Task's and is adopted —
  unless a longer id on the Release Todo List claims it by the same test. Delete or rename a
  removed Task's branch, or it lingers as an orphan the next id can't match. ids are tracker
  keys, unique per target over time — never add an id that prefix-extends an adopted branch;
  rename the branch instead. Reopen a Landed Task by unchecking its box — the next claim
  reattaches to the branch that already carries its work; delete the branch too for a clean
  slate.

  Default mode: MR mode. Every launch reads the target's origin first — on a github
  or gitlab host each Task is handed off as a pull/merge request. No origin at all, or
  one on neither forge, refuses at launch: pass --local-merge or add a recognized origin.
  MR mode needs the Release Todo List to be in a separate — coordination — repository,
  and `gh` or `glab` plus `jq` on PATH.

  MR mode hands off a pull/merge request for review: [↑] pushed, request open ·
  [x] Landed · [⛔] declined · [?] needs a human look — a reviewer's verdict turns into
  the box on every loop pass.

  Branches in MR mode: a Task forks from origin/<base>, never the local one;
  a branch is deleted only once its work is proven landed in origin/<base>, so
  a declined or unresolved Task's branch is kept on purpose; no force push, no
  amend after a push, no rebase, ever.

  Environment (all variables are in README.md):

    KAIZERO_WATCHDOG=duration   How long claude may make no progress before the watchdog
                                   kills it, in seconds or with an s/m/h suffix (900, 90s,
                                   15m, 1h). Default @@WATCHDOG_DEFAULT@@; 0 disables the watchdog.
                                   Progress is claude's own CPU time, so a long honest run
                                   is never killed — only one that has stopped working.

    KAIZERO_DEPENDENCY_WAIT=duration
                                   Ceiling on the wait after a session walks the whole
                                   Release Todo List and claims nothing because every
                                   unchecked Task is dependency-blocked (step 2.a). Same
                                   grammar as KAIZERO_WATCHDOG (900, 90s, 15m, 1h).
                                   Default @@DEPENDENCY_WAIT_DEFAULT@@; 0 relaunches
                                   claude immediately every cycle. The wait ends the
                                   instant the block clears (a peer merges or its holder
                                   dies) or this ceiling elapses, whichever comes first;
                                   the relaunched session claims the next free Task.

    KAIZERO_LINK=name[,name…]   Top-level directories symlinked from the repo root
                                   into every Task worktree. Unset by default. A worktree
                                   checks out tracked files only, so gitignored Task
                                   directories a Task line points at are absent there;
                                   listing them here lets a session read the Acceptance
                                   Criteria and tick them in the real file.

    KAIZERO_TASK_ID_PATTERN=ere Extended regex a Task's first token must match to count
                                   as an id, checked on the current Release Todo List only.
                                   Default matches SMTH-855, 7, 7.a, TASK-030 (requires a
                                   digit). `.` disables the shape check, leaving only the
                                   no-token case. A first token shaped `[ID](path)`: its
                                   bracketed text is unwrapped before the pattern check runs,
                                   against the unwrapped text.

  Log a run (Kaizero's own output only; claude's TUI stays on the terminal):

    @@PROG@@ ~/repos/acme-planning/todo.md 2>&1 | { trap '' INT; tee ../run.log; }

  The `trap` keeps tee alive through Ctrl+C so the final report lands in the file.
USAGE
}

# CONTEXT_THRESHOLDS: model-id pattern → restart-at token count, one pair per line, matched in
# order against the newest transcript usage record's model id — first match wins, so a row below
# one that already matched is dead and nothing reports it. Unmatched → CONTEXT_THRESHOLD_DEFAULT.
# A word-suffix tier (e.g. claude-fable-5-mini) is NOT its family's row and falls to the default;
# giving it its own number means adding a `-mini` row of its own — where that row SITS in the
# table is then a no-op, since first-match-wins already sorts it out on its own text alone.
# 200000 comes from Opus 4.8's measured degradation curve (see README's "Context rot"); 160000 is
# 80% of an assumed 200k window. Neither is inherited from the third-party hook this table replaces.
# This table is the ONLY place these numbers live, and they are meant to be retuned from real
# runs, not treated as settled. Sort a model with:
#   grep -rhoE '"model":"[^"]*"' ~/.claude/projects/ | sort | uniq -c
# — appearing ONLY bare on sessions known to run a 1M window → safe to add a row; appearing both
# bare AND with `[1m]` → do NOT add a row, since a 200000 row would then sit at that session's
# hard wall instead of before it, where the 160000 default already puts it.
# This table goes stale by default and fails LOW when it does: sessions on a new model restarting
# far sooner than expected is the symptom that means it needs a row here.
#                model-id pattern                       restart at
CONTEXT_THRESHOLDS='
  \[1m\]                                                200000
  claude-fable-5(-[0-9]|[^A-Za-z0-9-])                  200000
  claude-mythos-5(-[0-9]|[^A-Za-z0-9-])                 200000
  claude-opus-5(-[0-9]|[^A-Za-z0-9-])                   200000
  claude-sonnet-5(-[0-9]|[^A-Za-z0-9-])                 200000
'
CONTEXT_THRESHOLD_DEFAULT=160000    # anything unlisted: assume a 200k window, restart at 80% of it

# origin_parts <url>: sets ORIGIN_HOST (bare host, userinfo stripped, lowercased once — the form
# both the github/gitlab test and --hostname use; carries :port only for an https/http scheme,
# where the port is part of the CLI's own host key), ORIGIN_REDUCED (the URL with userinfo
# stripped, case and port otherwise as it arrived — never a credential, everywhere the origin is
# displayed), and ORIGIN_REPO_ARG (the value to pass as a forge CLI's --repo: same as
# ORIGIN_REDUCED for a scheme URL, but for scp-syntax reduced to OWNER/REPO on github.com or
# HOST/OWNER/REPO elsewhere, trailing .git stripped — gh/glab reject the bare host:path shape
# ORIGIN_REDUCED carries there). Two forms: a URL with a scheme (https://, ssh://, …), and git's
# scp-like syntax ([user@]host:path, no scheme, no port — a leading digit in path is not one).
# Anything else (a local path) has no host and passes through unchanged.
origin_parts() {
  local u="$1"
  if [[ "$u" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/]*)(/.*)?$ ]]; then
    local scheme="${BASH_REMATCH[1]}" authority="${BASH_REMATCH[2]}" path="${BASH_REMATCH[3]}"
    authority="${authority##*@}"     # strip userinfo
    local host port="" hostlc
    if [[ "$authority" == \[*\]* ]]; then
      host="${authority%%]*}]"                    # bracketed IPv6 literal, kept whole
      local after="${authority#*]}"
      [[ "$after" == :* ]] && port="${after#:}"
    else
      host="${authority%%:*}"
      [[ "$authority" == *:* ]] && port="${authority#*:}"
    fi
    hostlc="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
    case "$scheme" in
      http|https) ORIGIN_HOST="$hostlc${port:+:$port}" ;;
      *)          ORIGIN_HOST="$hostlc" ;;
    esac
    if [ -n "$port" ]; then ORIGIN_REDUCED="$scheme://$host:$port$path"
    else ORIGIN_REDUCED="$scheme://$host$path"; fi
    ORIGIN_REPO_ARG="$ORIGIN_REDUCED"
  elif [[ "$u" =~ ^([^@/[:space:]]+@)?([^:/[:space:]]+):(.*)$ ]]; then
    local host="${BASH_REMATCH[2]}" path="${BASH_REMATCH[3]}"
    ORIGIN_HOST="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
    ORIGIN_REDUCED="$host:$path"
    path="${path%.git}"
    if [ "$ORIGIN_HOST" = "github.com" ]; then ORIGIN_REPO_ARG="$path"
    else ORIGIN_REPO_ARG="$host/$path"; fi
  else
    ORIGIN_HOST=""
    ORIGIN_REDUCED="$u"
    ORIGIN_REPO_ARG="$u"
  fi
}

# rewrite_note <root> <expanded-reduced-url>: "" when the configured remote.origin.url and the
# expanded one (git remote get-url's, after an insteadOf rewrite) reduce to the same value;
# otherwise " — configured as <raw-reduced>", so a host-naming refusal shows the URL the operator
# actually set beside the one the rewrite produced. Saves/restores ORIGIN_HOST/ORIGIN_REDUCED —
# it must not disturb the caller's own reading of the expanded URL.
rewrite_note() {
  local root="$1" expanded="$2" raw save_host="$ORIGIN_HOST" save_reduced="$ORIGIN_REDUCED"
  raw="$(git -C "${root:-.}" config --get remote.origin.url 2>/dev/null)" || raw=""
  if [ -n "$raw" ]; then
    origin_parts "$raw"
    [ "$ORIGIN_REDUCED" = "$expanded" ] || printf ' — configured as %s' "$ORIGIN_REDUCED"
  fi
  ORIGIN_HOST="$save_host"; ORIGIN_REDUCED="$save_reduced"
}

# resolve_forge <host>: sets FORGE from KAIZERO_FORGE if set, else from the host (github → gh,
# gitlab → glab). Returns nonzero, FORGE unset, when neither applies and there is no override, or
# when KAIZERO_FORGE is set to anything but gh or glab — an override names one of the two
# forges this mode implements, never a third forge or a command path, checked here so every path
# that resolves a forge rejects it the same way, once, before it can reach a `case "$FORGE"`.
resolve_forge() {
  if [ -n "${KAIZERO_FORGE:-}" ]; then
    case "$KAIZERO_FORGE" in
      gh|glab) FORGE="$KAIZERO_FORGE"; return 0 ;;
      *) FORGE=""; return 2 ;;
    esac
  fi
  case "$1" in
    *github*) FORGE=gh ;;
    *gitlab*) FORGE=glab ;;
    *) return 1 ;;
  esac
}

# decide_origin <repo>: read origin and resolve its forge, or refuse once with the shared
# launch/doctor wording. --local-merge callers skip this entirely.
decide_origin() {
  local root="$1" origin rc=0
  origin="$(git -C "$root" remote get-url origin 2>/dev/null)" || origin=""
  [ -n "$origin" ] || { echo "$PROG: No 'origin' remote — landing as a merge/pull request is the default and needs one to hand a Task off to; run with --local-merge to merge locally instead — it merges directly to the current branch with no review step, review the commits it produces afterward"; return 1; }
  origin_parts "$origin"
  resolve_forge "$ORIGIN_HOST" || rc=$?
  if [ "$rc" = 2 ]; then
    echo "$PROG: KAIZERO_FORGE='$KAIZERO_FORGE' is not gh or glab — those are the only two forges this mode implements"
    return 1
  fi
  [ "$rc" = 0 ] || { echo "$PROG: Unsupported forge '${ORIGIN_HOST:-$ORIGIN_REDUCED}' (origin: $ORIGIN_REDUCED$(rewrite_note "$root" "$ORIGIN_REDUCED")) — MR mode only knows github and gitlab; set KAIZERO_FORGE=gh|glab for a self-hosted instance of one, or run with --local-merge to merge locally instead"; return 1; }
  ORIGIN_URL="$ORIGIN_REPO_ARG"
}

# capture_help <tool> <subcommand...> -> stdout: that subcommand's own --help text (stdout+stderr
# merged, since CLIs vary on which stream they print help to). A failing --help still returns text
# here (redirected to `true`, never propagated) — a missing flag surfaces downstream, from an empty
# or unexpected capture, the same way a renamed one does. Spawned once per subcommand; callers
# must not invoke --help a second time for the same subcommand.
capture_help() {
  "$@" --help 2>&1 || true
}

# flag_defined <help-text> <flag>: true when <flag> is the first token on one of <help-text>'s own
# lines — either "-X, --flag ..." (gh) or "-X --flag ..." / "--flag ..." (glab, no comma, and no
# short form at all for some flags) — never merely mentioned inside a description or an EXAMPLES
# transcript, where the flag never starts the line (`gh pr create --help` mentions --title on 5
# lines, only 1 a definition; a substring match would let a dropped flag hide behind a stale
# example). Reads via a here-string, never a pipe: piping a large capture into `grep -q` risks the
# writer taking SIGPIPE on an early match under this script's `set -o pipefail`, which would
# report a PRESENT flag as missing (measured latent on bash 5.2/macOS once the help text crosses
# 64 KiB; herestrings write through a temp file, not a live pipe, so this never fires here).
flag_defined() {
  local help="$1" flag="$2"
  grep -qE -- "^[[:space:]]*(-[A-Za-z],?[[:space:]]+)?${flag}([[:space:]]|\$)" <<<"$help"
}

# assert_forge_flag <help-text> "<tool subcommand>" <flag> <min-version>: exits nonzero, naming
# the subcommand, the flag and <min-version> (MIN_GH_VERSION/MIN_GLAB_VERSION), when <flag> is not
# on a definition line of the already-captured <help-text>. Never re-spawns --help itself — the
# caller captures it once per subcommand via capture_help and passes the text in.
assert_forge_flag() {
  local help="$1" cmd="$2" flag="$3" minver="$4"
  flag_defined "$help" "$flag" \
    || { echo "$PROG: $cmd --help does not list '$flag' — $FORGE's flag surface changed; that flag is present in $FORGE >= $minver, so upgrade if your $FORGE is older, or it was renamed in a newer $FORGE and kaizero needs updating"; exit 1; }
}

# check 5: forge flag/field surface — every flag mr_list/mr_create pass to $FORGE, the live auth
# probe's own `--hostname` flag, and (gh only) the JSON field list mr_list reads out of `pr list
# --json`, are still where this script expects them. A rename here would otherwise surface as a
# task failing to land mid-fleet, or, for `--hostname`, as the live auth probe below failing with a
# login instruction that also fails while the real cause — a renamed flag — never gets named.
# Static: no network, no auth (`sed -n '/^# check .*flag/,/^}/p' kaizero.sh` shows only --help
# calls and one `gh pr list --json` given no value, whose exit status is ignored below), so it runs
# before every live probe further down — an operator with both a dead token and a renamed flag
# learns about the flag in the same round trip. Only the resolved $FORGE's own subcommands are
# checked — unlike .github/smoke.sh check 18, which checks both CLIs unconditionally because CI
# installs both; --doctor only ever has one forge selected for the run. Mirrors smoke check 18's
# flag list, kept in sync by hand the same way. Defined here, not inside the "# --- forge" fence
# further down: that fence is baked into the emitted `.git/zero.sh` (the `cat <<'ZERO_EOF'`
# heredoc run_doctor's own caller sits well outside), so a function placed there is never in scope
# for kaizero.sh's own `run_doctor` call below — this check runs in THIS process, at `--doctor`/
# launch time, never inside the emitted zero.sh (which has no doctor of its own to run it from).
assert_forge_flags() {
  case "$FORGE" in
    gh)
      local gh_list_help gh_create_help gh_auth_help ghfields f
      gh_list_help="$(capture_help gh pr list)"
      gh_create_help="$(capture_help gh pr create)"
      gh_auth_help="$(capture_help gh auth status)"
      for f in --repo --head --state --limit --json; do assert_forge_flag "$gh_list_help" "gh pr list" "$f" "$MIN_GH_VERSION"; done
      for f in --repo --head --base --title --body-file; do assert_forge_flag "$gh_create_help" "gh pr create" "$f" "$MIN_GH_VERSION"; done
      assert_forge_flag "$gh_auth_help" "gh auth status" --hostname "$MIN_GH_VERSION"
      # gh pr list --json's own field list — the same rename hazard one level down. Given no
      # value, gh exits 1 and prints the field list on stderr with stdout empty: read stderr,
      # ignore the (expected non-zero) status.
      ghfields="$(gh pr list --json 2>&1 >/dev/null)" || true
      for f in number headRefOid baseRefName state url; do
        grep -qF -- "$f" <<<"$ghfields" \
          || { echo "$PROG: Gh pr list --json does not offer the '$f' field — gh's JSON field surface changed; that field is present in gh >= $MIN_GH_VERSION, so upgrade if your gh is older, or it was renamed in a newer gh and kaizero needs updating"; exit 1; }
      done
      ;;
    glab)
      local glab_list_help glab_create_help glab_auth_help f
      glab_list_help="$(capture_help glab mr list)"
      glab_create_help="$(capture_help glab mr create)"
      glab_auth_help="$(capture_help glab auth status)"
      for f in --repo --source-branch --all --output --per-page --order --sort; do assert_forge_flag "$glab_list_help" "glab mr list" "$f" "$MIN_GLAB_VERSION"; done
      for f in --repo --source-branch --target-branch --title --description --yes; do assert_forge_flag "$glab_create_help" "glab mr create" "$f" "$MIN_GLAB_VERSION"; done
      assert_forge_flag "$glab_auth_help" "glab auth status" --hostname "$MIN_GLAB_VERSION"
      ;;
  esac
}

# --- the main-worktree discriminator ---------------------------------------------------
# physical root of the working tree containing $1 — via --show-cdup, never the other rev-parse
# flag that answers this: that one can answer with a logical, symlink-preserving path, and a
# physical path never prefix-matches git's physical worktree roots under a symlinked /tmp).
# Works for every layout git supports —
# a standard `.git` dir, `.git` a file (`--separate-git-dir`, and a submodule's absorbed gitdir),
# `.git` a symlink, and a worktree attached to a bare repository — because it walks up from $1
# inside its OWN worktree, never through `git worktree list`'s "main" entry (broken for all four:
# it reports the git directory, not the working tree, whenever core.worktree is unset or ignored).
wt_root() {
  local d="$1" cdup
  cdup="$(git -C "$d" rev-parse --show-cdup)" || return 1
  (cd "$d/$cdup" && pwd -P)
}

# true when $1's own worktree is its repository's main one, or — a bare origin has no main
# worktree of its own — the only kind of worktree that repository can ever have.
is_main_or_bare() {
  local d="$1" gd cd_
  gd="$(git -C "$d" rev-parse --path-format=absolute --git-dir)" || return 1
  cd_="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir)" || return 1
  [ "$gd" = "$cd_" ] && return 0
  git -c safe.bareRepository=all -C "$cd_" rev-parse --is-bare-repository 2>/dev/null | grep -qx true
}

# path of the MAIN worktree for common (git) dir $1 — named in a linked-worktree refusal only.
# core.worktree resolves it exactly for a submodule's absorbed gitdir. A relocated
# `--separate-git-dir=`/symlinked main never sets it (a known git limitation with no outside
# workaround); `worktree list`'s first entry is trustworthy there too UNLESS it echoes $1 itself
# back — the tell that git could not resolve the working tree either and is naming the git
# directory, not a working tree. Empty output (and failure) means genuinely undeterminable —
# callers must not print it as a path.
main_root_of() {
  local cd_="$1" cw guess
  cw="$(git -C "$cd_" config --get core.worktree 2>/dev/null)" || cw=""
  if [ -n "$cw" ]; then (cd "$cd_/$cw" 2>/dev/null && pwd -P) && return 0; fi
  guess="$(git -C "$cd_" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
  [ -n "$guess" ] && [ "$guess" != "$cd_" ] || return 1
  printf '%s' "$guess"
}

# run_doctor [mr]: verify prerequisites. The single source of truth for prerequisite checks — run
# on normal startup AND via `--doctor` (which the brew formula calls as a post-install step).
# Exits nonzero with an actionable message on failure. No argument: claude CLI + flock, as always.
# `mr`: MR mode's own checks 1-6 against $TARGET_ROOT/$TARGET_BASE, consuming ORIGIN_HOST/
# ORIGIN_URL/FORGE the origin/forge decision already established before calling here — it neither
# resolves them nor carries refusals of its own for a missing or unsupported origin; the claude/
# flock probes above have already run on whichever path got here too, so this does not repeat
# those either. Check 3 (the flag/field surface) is static and runs before checks 4-5's live
# probes, on purpose — see assert_forge_flags's own comment inside the "# --- forge" fence further
# down the file.
run_doctor() {
  if [ "${1:-}" != mr ]; then
    # guard: claude CLI present AND runnable — `command -v` only proves a name resolves on PATH,
    # which a version-manager shim (asdf, etc.) always does regardless of which version it
    # resolves to for this cwd; only invoking it proves the real launch (below) will work here.
    command -v claude >/dev/null 2>&1 || { echo "$PROG: Claude CLI not found on PATH — install Claude Code: https://claude.com/product/claude-code"; exit 1; }
    local claude_v_out
    claude_v_out=$(claude -v 2>&1) || { echo "$PROG: Claude CLI found on PATH but failed to run — $claude_v_out"; exit 1; }

    # guard: flock prerequisite (see top) — present AND runnable.
    command -v flock >/dev/null 2>&1 || { echo "$PROG: Flock not found on PATH (Linux: util-linux; macOS: brew install flock)"; exit 1; }
    flock -n "$(mktemp)" true 2>/dev/null || { echo "$PROG: Flock present but not runnable"; exit 1; }
    return 0
  fi

  # check 1: git on PATH.
  command -v git >/dev/null 2>&1 || { echo "$PROG: Git not found on PATH"; exit 1; }

  # check 2: the forge CLI and jq, separately, so the operator learns which one to install.
  command -v "$FORGE" >/dev/null 2>&1 \
    || { echo "$PROG: $FORGE CLI not found on PATH — install it: https://cli.github.com/ (gh) or https://gitlab.com/gitlab-org/cli (glab)"; exit 1; }
  command -v jq >/dev/null 2>&1 \
    || { echo "$PROG: Jq not found on PATH — install it: https://jqlang.org/download/"; exit 1; }

  # check 3: forge flag/field surface — see assert_forge_flags above. Static, so it runs before
  # every live probe below: a fixture with both a dead token and a renamed flag reports the flag
  # problem, not the auth one. assert_forge_flags is defined above, not inside the "# --- forge"
  # fence further down the file — see its own comment for why.
  assert_forge_flags

  # check 4: the forge CLI is authenticated for the origin's host — scoped with --hostname so a
  # stale entry for an unrelated host, or a login for some OTHER host, cannot mislead this check.
  # An origin with no host at all — a local path, a file:// URL — has nothing to scope the probe
  # to; an empty --hostname is not a scoped probe, so this is skipped rather than called unscoped.
  if [ -n "$ORIGIN_HOST" ]; then
    echo "$PROG: Testing $FORGE authentication for $ORIGIN_HOST..."
    "$FORGE" auth status --hostname "$ORIGIN_HOST" >/dev/null 2>&1 \
      || { echo "$PROG: $FORGE authentication for $ORIGIN_HOST: failed"; echo "$PROG: $FORGE auth status failed for $ORIGIN_HOST — run $FORGE auth login --hostname $ORIGIN_HOST (landing a Task as a merge/pull request needs access to that host)$(rewrite_note "$TARGET_ROOT" "$ORIGIN_URL")"; exit 1; }
    echo "$PROG: $FORGE authentication for $ORIGIN_HOST: ok"
  else
    echo "$PROG: Origin '$ORIGIN_URL' has no host to scope an auth check to — skipping check 3"
  fi

  # check 5: proving network + git auth + that the base a request would target exists on the
  # remote — network_reachable's own exit code (2 = base absent, never a network cause) tells the
  # two outcomes apart without reading git's prose, same rule acquire_task's own base refresh
  # applies. Refspec spelled out so refs/remotes/origin/<base> is always updated (forks from it)
  # rather than opportunistically, depending on the clone's own fetch config.
  echo "$PROG: Testing '$TARGET_BASE' presence on origin..."
  rc=0; network_reachable || rc=$?
  case "$rc" in
    2) echo "$PROG: '$TARGET_BASE' presence on origin: failed"; echo "$PROG: '$TARGET_BASE' is not on origin in $TARGET_ROOT — push the base branch first: git push -u origin $TARGET_BASE (a merge request needs a base branch that exists on the forge)"; exit 1 ;;
  esac
  local fetch_out
  if ! fetch_out=$(git -C "$TARGET_ROOT" fetch origin "+refs/heads/$TARGET_BASE:refs/remotes/origin/$TARGET_BASE" 2>&1); then
    echo "$PROG: '$TARGET_BASE' presence on origin: failed"; echo "$PROG: Fetch of origin/$TARGET_BASE failed in $TARGET_ROOT — $fetch_out"; exit 1
  fi
  echo "$PROG: '$TARGET_BASE' presence on origin: ok"

  # check 6: warning only. Tasks fork from origin/<base> regardless, so this never gates —
  # it only tells the operator when their own checkout disagrees with what a request will build on.
  local local_tip remote_tip mb
  local_tip="$(git -C "$TARGET_ROOT" rev-parse "$TARGET_BASE")"
  remote_tip="$(git -C "$TARGET_ROOT" rev-parse FETCH_HEAD)"
  if [ "$local_tip" != "$remote_tip" ]; then
    mb="$(git -C "$TARGET_ROOT" merge-base "$local_tip" "$remote_tip" 2>/dev/null)" || mb=""
    if [ "$mb" = "$local_tip" ]; then
      echo "$PROG: $TARGET_BASE in $TARGET_ROOT is behind origin/$TARGET_BASE — Tasks fork from origin/$TARGET_BASE, so requests build on the current base even though this checkout does not; git pull when convenient"
    else
      echo "$PROG: Warning: $TARGET_BASE in $TARGET_ROOT has $(git -C "$TARGET_ROOT" rev-list --count "$remote_tip..$local_tip") commit(s) origin does not — Tasks fork from origin/$TARGET_BASE, so that work is in no session and no merge request; push it first if it belongs there"
    fi
  fi
}

# a mid-run auth-status re-check (run_loop's pre-launch guard, wait_for_reviews's poll) fails
# identically on a dead token or on a network blip — both go through the same host round-trip —
# but only the blip clears on its own. A few tries a couple seconds apart absorb that without
# stopping a whole fleet run, and the work it was about to hand off, over an outage a plain retry
# would have outlived. Sets FORGE_AUTH_ERR to the CLI's own stderr on the final failed attempt, so
# a caller can tell a network-shaped failure (the API host down) from a real credential refusal
# (BUG-047) without re-running the command.
forge_auth_ok() {
  [ -n "$ORIGIN_HOST" ] || return 0   # no host to scope the probe to — same rule as check 5
  local i=1
  while [ "$i" -le 3 ]; do
    if FORGE_AUTH_ERR=$("$FORGE" auth status --hostname "$ORIGIN_HOST" 2>&1 1>/dev/null); then return 0; fi
    [ "$i" -lt 3 ] && sleep "$FORGE_AUTH_RETRY_WAIT"
    i=$((i+1))
  done
  return 1
}

# looks_like_network_error TEXT: true when TEXT (git's or a forge CLI's own stderr) names a
# transport-level failure — DNS, connect, TLS or deadline problems common to git's HTTP client and
# both forge CLIs' Go HTTP clients — rather than a credential refusal (BUG-047). Read once, shared
# by every probe below, so "unreachable" is judged the same way whichever round-trip failed.
looks_like_network_error() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *"could not resolve host"*|*"no such host"*|*"dial tcp"*|*"i/o timeout"*|*"timeout"*| \
    *"connection refused"*|*"network is unreachable"*|*"tls handshake"*|*"deadline exceeded"*| \
    *"connection reset"*|*"no route to host"*|*"could not connect"*|*"couldn't connect"*| \
    *"failed to connect"*)
      return 0 ;;
    *) return 1 ;;
  esac
}

# network_reachable: probes the effective PUSH url (git remote get-url --push honors
# remote.origin.pushurl / url.*.pushInsteadOf) — the endpoint a Hand off's push actually uses,
# which a redirected fetch URL can disagree with (BUG-047). The ref probed is fully spelled out as
# refs/heads/$TARGET_BASE — a bare branch name is a ls-remote PATTERN, matched against any ref
# whose path ends in it (refs/heads/feature/main answers for "main" too), which would read a base
# missing from origin as present; the exact ref decides, never a ref's last path segment.
# GIT_TERMINAL_PROMPT=0 keeps a bare HTTPS origin with no credential helper from blocking on a
# username prompt; the NETWORK_PROBE_TIMEOUT bound keeps a black-holed route from blocking past it.
# Sets NETWORK_ERR to the probe's own stderr on every nonzero return, for a caller to print. Returns
# 0 = reachable; 2 = base branch absent on origin — --exit-code turns that into git's own rc 2,
# matching the launch doctor's check 4 reading of the same condition, permanent, never a network
# cause; 3 = the probe itself was refused on credentials, not on the network — a private origin's
# ls-remote fails on a revoked token exactly as it fails on an outage, so the message decides,
# never the bare exit code; 1 = anything else, including the timeout's own 124, treated as a
# transient outage.
network_reachable() {
  local pushurl out rc=0
  pushurl="$(git -C "$TARGET_ROOT" remote get-url --push origin 2>/dev/null)" || pushurl=origin
  out="$(GIT_TERMINAL_PROMPT=0 timeout "${NETWORK_PROBE_TIMEOUT:-10}" \
    git -C "$TARGET_ROOT" ls-remote --exit-code --heads "$pushurl" "refs/heads/$TARGET_BASE" 2>&1 1>/dev/null)" || rc=$?
  NETWORK_ERR="$out"
  case "$rc" in
    0) return 0 ;;
    2) return 2 ;;
    124) return 1 ;;
    *) looks_like_network_error "$out" && return 1 || return 3 ;;
  esac
}

# wait_for_network PROBE: origin unreachable at a mid-run forge re-check — a network outage, unlike
# a dead token, clears on its own, so this parks instead of stopping the run (BUG-047). PROBE is
# "net" (default; re-polls network_reachable) or "forge" (re-polls forge_auth_ok, for an outage
# limited to the forge API host while git's own transport stays up — the two can fail independently).
# No ceiling: like an unset KAIZERO_REVIEW_WAIT, a person ends it, not a timer. The forge probe
# re-polls on REVIEW_POLL_SECS — the existing knob, no new one, respecting the API's own rate limit.
# The network probe (a free git ls-remote, no such limit) re-polls on the smaller of REVIEW_POLL_SECS
# and WAIT_TICK, with the first re-probe right after the park opens, so a blip much shorter than the
# poll interval resumes within a tick or two rather than idling a full interval. Returns 0 = the probe
# now succeeds; 2 = the probe still fails but no longer reads as a
# network problem (base now missing, or a credential refused for real) — the caller re-judges from
# scratch rather than being told "resumed"; 1 = STOP (Ctrl+C/SIGTERM/SIGHUP) — the loop's usual
# closer. Origin is named by its host, or by its reduced URL when it has none (a hostless/file://
# origin, the shape every MR fixture uses).
wait_for_network() {
  local probe="${1:-net}" start last poll_last i spin=0 frames="|/-\\" label="${ORIGIN_HOST:-$ORIGIN_REDUCED}" cause gate
  if [ "$probe" = forge ]; then cause="$FORGE_AUTH_ERR"; gate="$REVIEW_POLL_SECS"
  else cause="$NETWORK_ERR"; gate="$REVIEW_POLL_SECS"; [ "$WAIT_TICK" -lt "$gate" ] && gate="$WAIT_TICK"
  fi
  start=$(date +%s); last=$start; poll_last=0
  # a Ctrl+C/SIGTERM/SIGHUP landing here (or at either STOP check below) ends the run before any
  # claude session launches this pass, so the closer line every other STOP break already prints
  # (kaizero.sh:804/818) is never reached from there — print it at the one place all three
  # of this park's mid-run callers (the loop-top guard, wait_for_reviews's poll,
  # wait_for_dependency_clear's poll) share, so it fires once regardless of which one parked.
  if [ "$STOP" = 1 ]; then printf '\n%s%sRun loop stopped%s\n' "$(icon_plain)" "$C_DIM" "$C_RESET"; return 1; fi
  # KAIZERO_REVIEW_WAIT=0: README promises "0 never parks", and this park honours that gate
  # exactly as wait_for_reviews/wait_for_dependency_clear already do — name the cause and stop
  # instead of ever printing the "waiting" line below.
  if [ "$REVIEW_WAIT_SECS" = 0 ]; then
    printf '❄ Origin %s unreachable — not waiting (KAIZERO_REVIEW_WAIT=0)\n' "$label" >&2
    [ -n "$cause" ] && printf '%s\n' "$cause" >&2
    IDFAIL=1
    return 1
  fi
  printf '❄ Origin %s unreachable — waiting, re-probing every %s · press Ctrl+C to stop\n' \
    "$label" "$(fmt_dur "$REVIEW_POLL_SECS")"
  [ -n "$cause" ] && printf '%s\n' "$cause" >&2
  while true; do
    if [ "$STOP" = 1 ]; then printf '\n%s%sRun loop stopped%s\n' "$(icon_plain)" "$C_DIM" "$C_RESET"; return 1; fi
    if [ $(( $(date +%s) - poll_last )) -ge "$gate" ]; then
      poll_last=$(date +%s)
      if [ "$probe" = forge ]; then
        if forge_auth_ok; then
          if [ -t 1 ]; then printf '\r\033[K'; fi
          printf '❄ Origin reachable again · resuming\n'
          return 0
        fi
        if ! looks_like_network_error "$FORGE_AUTH_ERR"; then
          if [ -t 1 ]; then printf '\r\033[K'; fi
          return 2
        fi
        cause="$FORGE_AUTH_ERR"
      else
        network_reachable
        case "$?" in
          0)
            if [ -t 1 ]; then printf '\r\033[K'; fi
            printf '❄ Origin reachable again · resuming\n'
            return 0 ;;
          2|3)
            if [ -t 1 ]; then printf '\r\033[K'; fi
            return 2 ;;
        esac
        cause="$NETWORK_ERR"
      fi
      if [ -t 1 ]; then printf '\r\033[K'; fi
      [ -n "$cause" ] && printf '%s\n' "$cause" >&2
    fi
    if [ -t 1 ]; then
      i=0
      while [ "$i" -lt $((WAIT_TICK / WAIT_FRAME)) ]; do
        printf '\r❄ %s origin %s unreachable · %s · Ctrl+C to stop\033[K' \
          "${frames:$((spin%4)):1}" "$label" \
          "$(fmt_dur $(( ( ( $(date +%s) - start ) / WAIT_STEP ) * WAIT_STEP )))"
        spin=$((spin+1)); i=$((i+1))
        sleep "$WAIT_FRAME" || true
        if [ "$STOP" = 1 ]; then printf '\n%s%sRun loop stopped%s\n' "$(icon_plain)" "$C_DIM" "$C_RESET"; return 1; fi
      done
    else
      if [ $(( $(date +%s) - last )) -ge "$LOG_TICK" ]; then
        last=$(date +%s)
        printf '❄ Origin %s unreachable · %s\n' "$label" "$(fmt_dur $(( last - start )))"
      fi
      sleep "$WAIT_TICK" || true
    fi
  done
}

# mr_network_and_auth_ok: BUG-047's split, shared by every mid-run forge re-check (run_loop's
# pre-launch guard, wait_for_reviews's poll, wait_for_dependency_clear's poll) so the network
# judgment lives in exactly one place. Network first, credentials second: an outage — on git's
# transport or, once that is fine, on the forge API host alone — parks in wait_for_network (its own
# line and cadence) and this call re-judges from scratch once it stops parking; a base branch
# missing from origin, or a probe refused on credentials rather than on the network, is permanent —
# no park, the token check below reports it (or, for a missing base, this function does, with the
# doctor's own reading of that condition). Returns 0 = proceed; 1 = stop (STOP or IDFAIL is already
# set by the time this returns, for the caller's usual closer path to read). Also sets the global
# NET_MET_OUTAGE=1 whenever this call parked in wait_for_network at all, even if it goes on to
# return 0 — the loop-top guard reads that flag to widen its own restart gap (BUG-047 "a flapping
# origin must not spin"); the two mid-run polls ignore the flag, since only a session launch needs it.
mr_network_and_auth_ok() {
  local rc
  NET_MET_OUTAGE=0
  while true; do
    network_reachable; rc=$?
    case "$rc" in
      0) break ;;
      2)
        echo "$PROG: '$TARGET_BASE' is not on origin in $TARGET_ROOT — push the base branch first: git push -u origin $TARGET_BASE (a merge request needs a base branch that exists on the forge)" >&2
        IDFAIL=1
        return 1 ;;
      3) break ;;   # the probe itself was refused on credentials — let the token check report it
      *)
        NET_MET_OUTAGE=1
        wait_for_network net
        [ $? = 1 ] && return 1 ;;   # STOP; a 0 or 2 return re-judges from the top of this loop
    esac
  done
  while true; do
    if forge_auth_ok; then return 0; fi
    if looks_like_network_error "$FORGE_AUTH_ERR"; then
      NET_MET_OUTAGE=1
      wait_for_network forge
      [ $? = 1 ] && return 1
      continue   # re-judge network AND the token from scratch once the API host answers again
    fi
    printf '\n❄ %s auth status failed for %s — run %s auth login --hostname %s (MR mode needs access to that host)\n' \
      "$FORGE" "$ORIGIN_HOST" "$FORGE" "$ORIGIN_HOST" >&2
    IDFAIL=1
    return 1
  done
}

# --doctor: run the prerequisite checks only, then exit. Used by `brew install` as a post-install
# step and for manual troubleshooting; any other args fall through to a normal run. Bare, it mirrors
# a real launch: the generic checks, then the same origin/forge decision, then MR mode's own checks,
# deriving TARGET_ROOT/TARGET_BASE from cwd — it cannot borrow main's guards, which live past it.
# `decide_origin` owns the origin decision and its refusals for both paths. `--doctor --local-merge`
# stops at the generic checks and reads no origin, the diagnostic counterpart of a launch's own
# --local-merge.
if [ "${1:-}" = --doctor ]; then
  run_doctor
  if [ "${2:-}" != --local-merge ]; then
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "$PROG: Not a git repository — run from inside the repo you want zeroed."; exit 1; }
    DOCTOR_BASE="$(git symbolic-ref -q --short HEAD)" \
        || { echo "$PROG: Detached HEAD in the target repository '$(pwd -P)' — check out the base branch first."; exit 1; }
    DOCTOR_ROOT="$(wt_root "$(pwd -P)")" || { echo "$PROG: Could not resolve the doctor root"; exit 1; }
    if is_main_or_bare "$(pwd -P)"; then
      [ "$(pwd -P)" = "$DOCTOR_ROOT" ] || { echo "$PROG: Not at the main repo root — cd to '$DOCTOR_ROOT' first. (Kaizero's own \`ts-*\`/\`tt-*\` Task worktrees are never valid launch dirs.)"; exit 1; }
    else
      if DOCTOR_MAIN="$(main_root_of "$(git rev-parse --path-format=absolute --git-common-dir)")"; then
        echo "$PROG: Not at the main repo root — cd to '$DOCTOR_MAIN' first. (Kaizero's own \`ts-*\`/\`tt-*\` Task worktrees are never valid launch dirs.)"; exit 1
      else
        echo "$PROG: Not at the main repo root, and its path could not be determined here — cd to the repository's own working directory (not a linked worktree) first."; exit 1
      fi
    fi
    TARGET_ROOT="$DOCTOR_ROOT"; TARGET_BASE="$DOCTOR_BASE"
    decide_origin "$TARGET_ROOT" || exit 1
    run_doctor mr
  fi
  echo "$PROG: All prerequisites OK."
  exit 0
fi

# normal startup guard (fail-fast, before any side effects). Skipped under KAIZERO_TEST_EMIT:
# that path only writes the generated scripts for CI to shellcheck and exits before launching
# claude, so CI needn't have claude/the hooks installed. See .github/check-embedded.sh.
# claude restart loop: run claude, accumulate timing, repeat until all Tasks land / Ctrl+C /
# MAX_LOOPS. Reads main()'s globals (PROMPT, STOP_SETTINGS, INSTANCE_ID); own state stays global
# (no `local`) so the INT trap + print_report see it.
run_loop() {
# KAIZERO_MAX_LOOPS: exit after N iterations instead of looping until Ctrl+C. 0/unset =
# unlimited (normal). Set >0 for tests so the loop self-terminates without a SIGINT.
MAX_LOOPS="${KAIZERO_MAX_LOOPS:-0}"
# fd 4 = where claude's own chatter goes. Redirected stdout + stdin still on the terminal → claude
# keeps writing to the terminal, so piping kaizero.sh to a log file records the ❄ reports, not
# the TUI. No redirect, or stdin not a terminal (tests, CI, nohup) → fd 4 is plain stdout, as today.
# Dup stdin rather than open /dev/tty: on macOS a descriptor opened from the /dev/tty clone device
# is not kqueue-registrable, and claude dies at startup with `EINVAL … kqueue`. The tty stdin the
# shell was handed is a real terminal fd, opened read-write, so it takes writes and kqueue both.
if [ ! -t 1 ] && [ -t 0 ]; then exec 4>&0; else exec 4>&1; fi
# fd 3 = a dup of OUR stdin, handed back to claude on every launch. Bash redirects an async
# command's stdin from /dev/null unless the launch names one, so backgrounding claude, for
# the TERM trap) silently took the terminal away from it — `[ -t 0 ]` inside claude went false and
# nothing typed at the session reached it any more. `<&3` gives back exactly what a foreground
# launch inherited, pipe or terminal alike.
exec 3<&0
LOOP_COUNT=0
# claude's pid, set per launch below. Initialized here because Claude Code exports CLAUDE_PID (its
# own pid) into every Bash-tool env: without this, a TERM arriving BEFORE the first launch — the
# pre-launch wait, or a Ctrl+C at startup — makes on_term SIGTERM the session that ran us.
CLAUDE_WRAPPER_PID=""
# BUG 057: this launch's identity value, changes every restart (LOOP_COUNT+1) so an orphaned hook
# or a stale watchdog timer from an earlier launch can never be mistaken for the current one.
SESSION_EPOCH=""
STOP=0                    # set by the INT/TERM/HUP traps; the loop breaks to the closer below
TERMED=0                  # set by the TERM trap; makes the closer exit 143 instead of 0
HUPPED=0                  # set by the HUP trap; makes the closer exit 129 instead of 0 (BUG-047:
                           # the network wait can now run for hours, so a terminal hangup ending
                           # it must still reach the same closer, not bash's default HUP kill)
IDFAIL=0                  # set when `zero.sh validate-ids` refuses; makes the closer exit 2
NET_FLAP_STREAK=0         # BUG-047: consecutive passes whose pre-launch guard met an outage before
                           # proceeding — widens the between-session restart gap below every pass it
                           # stays nonzero, so a flapping origin that clears the guard by chance
                           # cannot relaunch a session at RESTART_WAIT's flat cadence forever
TODOS_BASE=$(read_counter "${TODOS_TIME_FILE:-}")   # snapshot: report only THIS run's slice of the shared aggregates
TODOS_DONE_BASE=$(read_counter "${TODOS_DONE_FILE:-}")
LOOP_START=$(date +%s)   # script loop (outer while loop) starts here

# Ctrl+C during the between-runs sleep (cooked mode) requests a clean stop; the loop breaks to the
# single closer below (during chat the tty is raw, so Ctrl+C goes to claude, not here). Set AFTER
# the timing vars so the report can read them.
trap 'STOP=1' INT

# SIGTERM (supervisor shutdown, `timeout`, `kill`) requests the same clean stop, and additionally
# forwards the signal to claude — a hung child must not outlive us — and records TERMED so the
# closer can exit 143. Bash keeps one handler per signal, so further TERM work chains into here.
# BUG 057: CLAUDE_WRAPPER_PID alone is not evidence — validate it against SESSION_RECORD_FILE
# (written right after launch) before signalling anything. A SIGTERM landing before the record
# exists (the window between CLAUDE_WRAPPER_PID=$! and the write) finds an empty file and stays
# silent: nothing to
# refuse, nothing to kill. A record that exists but fails validation (names a dead/superseded
# session) IS refused, and named on the console — this process, unlike the emitted hook, has a
# console to speak on.
on_term() {
    STOP=1
    TERMED=1
    # BUG 058k: no pre-invocation guard here — terminator.sh validates the record itself and is a
    # fast no-op when there is nothing to target (e.g. before the first launch); this call never
    # writes an exit-reason code (no 4th/5th arg), so kaizero.sh's own post-wait fallback
    # (TERM → 93) still decides this launch's reported reason, unchanged.
    [ -n "${TERMINATOR_SH:-}" ] && "$TERMINATOR_SH" "${SESSION_RECORD_FILE:-}" "${SESSION_EPOCH:-}" "${EXIT_REASON_FILE:-}"
    return 0
}
trap on_term TERM

# SIGHUP (terminal closed, controlling process exited) while parked in the network wait — the only
# wait with no ceiling of its own — requests the same clean stop as SIGTERM (BUG-047).
on_hup() {
    STOP=1
    HUPPED=1
    [ -n "${TERMINATOR_SH:-}" ] && "$TERMINATOR_SH" "${SESSION_RECORD_FILE:-}" "${SESSION_EPOCH:-}" "${EXIT_REASON_FILE:-}"
    return 0
}
trap on_hup HUP

WATCHDOG_SECS="$(parse_dur "${KAIZERO_WATCHDOG:-$WATCHDOG_DEFAULT}" || true)"
WATCHDOG_RAW="${KAIZERO_WATCHDOG:-$WATCHDOG_DEFAULT}"
if [ -z "$WATCHDOG_SECS" ]; then
    echo "$PROG: Ignoring KAIZERO_WATCHDOG=$WATCHDOG_RAW (want 900, 90s, 15m, 1h, or 0 to disable) — using $WATCHDOG_DEFAULT" >&2
    WATCHDOG_RAW="$WATCHDOG_DEFAULT"; WATCHDOG_SECS="$(parse_dur "$WATCHDOG_DEFAULT")"
fi
WATCHDOG_PID=""      # set per launch by arm_watchdog, cleared by disarm_watchdog

DEPENDENCY_WAIT_SECS="$(parse_dur "${KAIZERO_DEPENDENCY_WAIT:-$DEPENDENCY_WAIT_DEFAULT}" || true)"
DEPENDENCY_WAIT_RAW="${KAIZERO_DEPENDENCY_WAIT:-$DEPENDENCY_WAIT_DEFAULT}"
if [ -z "$DEPENDENCY_WAIT_SECS" ]; then
    echo "$PROG: Ignoring KAIZERO_DEPENDENCY_WAIT=$DEPENDENCY_WAIT_RAW (want 900, 90s, 15m, 1h, or 0 to disable) — using $DEPENDENCY_WAIT_DEFAULT" >&2
    DEPENDENCY_WAIT_RAW="$DEPENDENCY_WAIT_DEFAULT"; DEPENDENCY_WAIT_SECS="$(parse_dur "$DEPENDENCY_WAIT_DEFAULT")"
fi

# KAIZERO_REVIEW_WAIT: unset is a sentinel for "unbounded", never fed to parse_dur — an
# empty REVIEW_WAIT_SECS is what lets both wait_for_reviews and wait_for_dependency_clear skip
# their ceiling test entirely rather than reaching `[ … -gt … ]` on an empty string. `0` is a
# real, distinct value ("never park"), so it is checked before parse_dur ever runs.
REVIEW_WAIT_RAW="${KAIZERO_REVIEW_WAIT:-}"
REVIEW_WAIT_SECS=""
if [ -n "$REVIEW_WAIT_RAW" ] && [ "$REVIEW_WAIT_RAW" != 0 ]; then
    REVIEW_WAIT_SECS="$(parse_dur "$REVIEW_WAIT_RAW" || true)"
    if [ -z "$REVIEW_WAIT_SECS" ]; then
        echo "$PROG: Ignoring KAIZERO_REVIEW_WAIT=$REVIEW_WAIT_RAW (want 900, 90s, 15m, 1h, or 0 to never park) — waiting with no ceiling" >&2
    fi
elif [ "$REVIEW_WAIT_RAW" = 0 ]; then
    REVIEW_WAIT_SECS=0
fi

REVIEW_POLL_SECS="$(parse_dur "${KAIZERO_REVIEW_POLL:-$REVIEW_POLL_DEFAULT}" || true)"
REVIEW_POLL_RAW="${KAIZERO_REVIEW_POLL:-$REVIEW_POLL_DEFAULT}"
if [ -z "$REVIEW_POLL_SECS" ]; then
    echo "$PROG: Ignoring KAIZERO_REVIEW_POLL=$REVIEW_POLL_RAW (want 900, 90s, 15m, 1h) — using $REVIEW_POLL_DEFAULT" >&2
    REVIEW_POLL_RAW="$REVIEW_POLL_DEFAULT"; REVIEW_POLL_SECS="$(parse_dur "$REVIEW_POLL_DEFAULT")"
fi

reap_dead_sessions   # startup: clear markers left by crashed prior runs before the first claude
while true; do
    # the SHELL decides whether a claude session is worth starting. Nothing left → the
    # closer; everything unchecked already held by a live peer → wait here, spending no tokens
    # (a claude parked at the prompt re-reads its whole context just to say "still peer-owned").
    if ! IDOUT=$("$ZERO_SH" validate-ids 2>&1); then
        printf '\n❄ Task id validation failed\n%s\n' "$IDOUT" >&2
        IDFAIL=1
        break
    fi
    # Advisory only — a broken Task file is localized to the id(s) it affects, not
    # the whole tail, so unlike validate-ids above it never sets IDFAIL or breaks the loop.
    if ! TASKOUT=$("$ZERO_SH" validate-tasks 2>&1); then
        printf '\n❄ Task definition issue(s) found — affected candidate(s) will be skipped until fixed:\n%s\n' "$TASKOUT"
    fi
    # reads back what reviewers did on every open [↑] handoff before this pass judges the
    # Release Todo List — a no-op under MR_MODE=0 (no forge to ask) and a warning, never a
    # break, on forge trouble: the loop's own shape must never depend on the forge answering.
    "$ZERO_SH" sync-mrs || true
    # before all_todos_done: a box at ↑ already satisfies that check's own "any" pattern, so
    # without this the loop would read an open request as Landed and exit. Parks here instead.
    if ! wait_for_reviews; then break; fi
    # --always-on: a fully Landed Release Todo List parks here instead of breaking to the
    # closer — but ONLY when nothing is outstanding at all. A todo whose remaining boxes are
    # open [↑] requests already satisfies all_todos_done's "any" pattern, yet is not "nothing
    # outstanding"; it ends the run exactly as it does without the flag, whatever
    # wait_for_reviews already decided about it. A false wait_for_new_task return means STOP, so
    # break exactly as a plain run would. `continue` (not fall-through) sends a woken park back
    # to the loop's very top, so the resumed pass re-runs validate-ids/validate-tasks/sync-mrs
    # fresh instead of launching claude against gates checked before the park began.
    if all_todos_done; then
        if [ "$ALWAYS_ON" = 1 ] && [ "$(open_requests)" -eq 0 ]; then
            if ! wait_for_new_task; then break; fi
            continue
        fi
        break
    fi
    # MR mode: a token that expired mid-run fails every hand off at mr time, leaving the
    # box claimable again — re-checking the doctor's own probe here, before launching claude,
    # stops the run instead of spending a session per RESTART_WAIT to fail the same way again.
    # Network first, credentials second: an outage and a dead token both fail an
    # auth-status round-trip identically, but only the outage clears on its own, so origin's
    # reachability is judged on its own transport before the token is blamed for it.
    if [ "$MR_MODE" = 1 ]; then
      if ! mr_network_and_auth_ok; then break; fi
      # BUG-047: a flapping origin can pass the probe above by chance and still fail its Hand off
      # moments later on the same outage — the only no-network case that still spins. A pass that
      # met the outage before proceeding leaves a line here and widens the gap the loop rests in
      # after this session ends; a pass that met none resets the streak.
      if [ "$NET_MET_OUTAGE" = 1 ]; then
        NET_FLAP_STREAK=$((NET_FLAP_STREAK + 1))
        printf '❄ Origin flapped before this launch · streak %s · widening the restart gap\n' "$NET_FLAP_STREAK"
      else
        NET_FLAP_STREAK=0
      fi
    fi
    wfc_rc=0; wait_for_claimable || wfc_rc=$?   # guarded: a bare nonzero-returning statement
    if [ "$wfc_rc" = 1 ]; then break; fi        # trips set -e before wfc_rc=$? is ever reached
    if [ "$wfc_rc" = 2 ]; then continue; fi   # nothing unchecked: re-judge from the loop's top
    if ! wait_for_dependency_clear; then break; fi
    # first prompt submitted straight from the CLI arg. The session Stop hook SIGTERMs claude
    # when context fills; exit 143 is the normal restart path, so swallow it.
    CLAUDE_ARGS=(--settings "$STOP_SETTINGS" --permission-mode auto --name "$SESSION_NAME")
    # diagnostic opt-in: a --debug-file on every real run is a standing cost for nobody. One file
    # per claude invocation, so a restart leaves the hung run's trace intact.
    if [ -n "${KAIZERO_DEBUG:-}" ]; then
        CLAUDE_ARGS+=(--debug-file "$DEBUG_FILE_BASE-$((LOOP_COUNT+1)).log")
    fi
    # claude's cwd is the target: its project's CLAUDE.md/.claude/settings/skills/hooks live there.
    # Backgrounding (`&`) forks with the cwd at that moment, so the cd back below never moves it.
    cd "$TARGET_ROOT"
    # cleared BEFORE the launch, never after the exit: a value left by the previous iteration's
    # kill would otherwise be read as this one's cause.
    : > "$EXIT_REASON_FILE"
    # Cleared before THIS launch, never after — a marker left by a prior (already killed)
    # launch must never be read as this launch's own first turn already being safe to end.
    : > "$SAFE_TO_EXIT_FILE"
    # Pin the session id before launch, so its transcript path is known immediately —
    # every / in the absolute cwd becomes a literal -, under ~/.claude/projects, named
    # <session-id>.jsonl (Claude Code's own convention).
    SID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    CLAUDE_ARGS+=(--session-id "$SID")
    SESSION_TRANSCRIPT="$HOME/.claude/projects/${PWD//\//-}/$SID.jsonl"
    # claude gets its own pty, independent of whatever stdio kaizero.sh itself
    # inherited — otherwise an unattended launch (non-tty stdin) makes claude exit on end_turn
    # instead of staying resident, orphaning any subagent it dispatched.
    # BUG 057: this launch's own identity value — LOOP_COUNT was already bumped for the PREVIOUS
    # launch's report, so +1 here is strictly increasing across restarts of this one instance.
    SESSION_EPOCH=$((LOOP_COUNT+1))
    # BUG 058k: the wrapper launches under a thin shell that ignores TERM (`trap '' TERM`) and
    # then `exec`s into `script` — same pid, no new process in the tree, SIG_IGN survives the
    # exec. An external group-wide TERM (a supervisor stopping the whole kaizero.sh + wrapper +
    # claude process group at once) now reaches claude directly instead of killing the wrapper out
    # from under it and tearing the pty down as a side effect; this codebase's own internal
    # signaling never sends the wrapper TERM either way (terminator.sh's last step is always
    # KILL — see write_terminator_sh). `bash -c '...' _ script ...` hands `script` and its own
    # arguments to the outer shell as ITS OWN separate argv entries, never concatenated into the
    # outer shell's single command-string argument — the BSD branch's true-argv safety and the
    # util-linux branch's already-escaped $CLAUDE_CMD string both stay exactly as safe as before,
    # neither gaining a new escaping surface nor being escaped twice.
    if [ "$PTY_STYLE" = bsd ]; then
        KAIZERO_INSTANCE="$INSTANCE_ID" KAIZERO_TRANSCRIPTS="$TRANSCRIPTS_FILE" \
            KAIZERO_LINK="${KAIZERO_LINK:-}" KAIZERO_EXIT_REASON="$EXIT_REASON_FILE" \
            KAIZERO_SAFE_TO_EXIT="$SAFE_TO_EXIT_FILE" \
            KAIZERO_SESSION_TRANSCRIPT="$SESSION_TRANSCRIPT" \
            KAIZERO_SESSION_RECORD="$SESSION_RECORD_FILE" KAIZERO_SESSION_EPOCH="$SESSION_EPOCH" \
            KAIZERO_NO_CO_AUTHORSHIP="${KAIZERO_NO_CO_AUTHORSHIP:-}" \
            bash -c 'trap "" TERM; exec "$@"' term-ignoring-wrapper \
            script -q /dev/null claude "${CLAUDE_ARGS[@]}" "$PROMPT" >&4 2>&4 <&3 &
    else
        CLAUDE_CMD="$(build_claude_cmd_string "${CLAUDE_ARGS[@]}" "$PROMPT")"
        KAIZERO_INSTANCE="$INSTANCE_ID" KAIZERO_TRANSCRIPTS="$TRANSCRIPTS_FILE" \
            KAIZERO_LINK="${KAIZERO_LINK:-}" KAIZERO_EXIT_REASON="$EXIT_REASON_FILE" \
            KAIZERO_SAFE_TO_EXIT="$SAFE_TO_EXIT_FILE" \
            KAIZERO_SESSION_TRANSCRIPT="$SESSION_TRANSCRIPT" \
            KAIZERO_SESSION_RECORD="$SESSION_RECORD_FILE" KAIZERO_SESSION_EPOCH="$SESSION_EPOCH" \
            KAIZERO_NO_CO_AUTHORSHIP="${KAIZERO_NO_CO_AUTHORSHIP:-}" \
            bash -c 'trap "" TERM; exec "$@"' term-ignoring-wrapper \
            script -qc "$CLAUDE_CMD" /dev/null >&4 2>&4 <&3 &
    fi
    CLAUDE_WRAPPER_PID=$!
    # BUG 057: record right after the pid is known — the gap before this line is the one window a
    # signal cannot be validated against anything, and on_term/the watchdog both treat it as "no
    # record yet", never as "no owner, guess". An unwritable git-common-dir is out of scope here —
    # the same directory already carries EXIT_REASON_FILE/SAFE_TO_EXIT_FILE with no separate guard.
    session_record_write "$CLAUDE_WRAPPER_PID" "$SESSION_EPOCH" || true
    cd "$COORD_ROOT"
    arm_watchdog "$CLAUDE_WRAPPER_PID" "$SESSION_TRANSCRIPT" "$SESSION_EPOCH"
    # backgrounded on purpose: bash defers every trap until a FOREGROUND child exits, so a TERM
    # arriving while claude hangs could never be handled. `wait` IS interruptible — it returns
    # 128+N when a trapped signal fires — so re-enter it until claude is actually gone.
    # `$?` after the loop is `break`'s own 0, so claude's status is captured inside the body.
    CLAUDE_EXIT=0
    until wait "$CLAUDE_WRAPPER_PID"; do
        CLAUDE_EXIT=$?
        kill -0 "$CLAUDE_WRAPPER_PID" 2>/dev/null || break
    done
    disarm_watchdog   # claude is gone: retire its timer before the pid can be recycled
    session_record_clear   # BUG 057: this launch's identity is gone — nothing may act on it again
    # why it ended: one read, one lookup. 143/137 alone cannot say — POSIX collapses every SIGTERM
    # into 143 — so an EMPTY file on those two IS the answer: none of our own kill paths fired, the
    # signal came from outside. Every other status is claude's own and already unique.
    # BUG 058k: only the FIRST line — terminator.sh (write_terminator_sh) now appends its own
    # status message line(s) after the code, so a plain `cat` would fold them into this read.
    REASON_RAW="$(head -n1 "$EXIT_REASON_FILE" 2>/dev/null || true)"
    EXIT_REASON="${REASON_RAW%% *}"; EXIT_DETAIL=""
    case "$REASON_RAW" in *' '*) EXIT_DETAIL="${REASON_RAW#* }" ;; esac
    # macOS's BSD `script` (PTY_STYLE=bsd) reflects a child that died to a signal as script's own
    # exit(signal_number) — 15/9, not the 128+N wait status a plain background job gives — so the
    # 143/137 check below never fires there; the 15/9 branches restate it in script's own terms.
    case "$CLAUDE_EXIT" in
        0)   EXIT_REASON=0; EXIT_DETAIL="" ;;
        143) [ -n "$EXIT_REASON" ] || EXIT_REASON=93 ;;
        137) [ -n "$EXIT_REASON" ] || EXIT_REASON=94 ;;
        15)  if [ "$PTY_STYLE" = bsd ]; then [ -n "$EXIT_REASON" ] || EXIT_REASON=93
             else EXIT_REASON=$CLAUDE_EXIT; EXIT_DETAIL=""; fi ;;
        9)   if [ "$PTY_STYLE" = bsd ]; then [ -n "$EXIT_REASON" ] || EXIT_REASON=94
             else EXIT_REASON=$CLAUDE_EXIT; EXIT_DETAIL=""; fi ;;
        *)   EXIT_REASON=$CLAUDE_EXIT; EXIT_DETAIL="" ;;
    esac
    # claude killed mid-run (Ctrl+C/SIGTERM) can leave the tty in raw mode with ISIG off; then every
    # later Ctrl+C arrives as a 0x03 byte, not a SIGINT, so the INT trap never fires and the loop
    # spins forever restarting claude on a wedged terminal. Restore cooked mode so Ctrl+C signals again.
    if [ -t 0 ]; then stty sane 2>/dev/null || true; fi
    NOW=$(date +%s)
    LOOP_COUNT=$((LOOP_COUNT+1))
    printf '\n\n'
    # a stop requested WHILE claude ran (TERM, or INT that reached us) breaks here, not after the
    # restart sleep — the closer below still prints the report and the fleet TOTAL.
    if [ "$STOP" = 1 ]; then printf '\n%sRun loop stopped\n' "$(icon_plain)"; break; fi
    if [ "$MAX_LOOPS" -gt 0 ] && [ "$LOOP_COUNT" -ge "$MAX_LOOPS" ]; then
        exit_reason_line "$EXIT_REASON" "$EXIT_DETAIL"
        printf '❄ Claude exited after %s runs · reached KAIZERO_MAX_LOOPS=%s · stopping\n' "$LOOP_COUNT" "$MAX_LOOPS"
        break
    fi
    print_report "$NOW"
    dojo_wisdom
    exit_reason_line "$EXIT_REASON" "$EXIT_DETAIL"
    # BUG-047: doubles per consecutive flapping pass, capped at 64x, so a flapping origin's
    # sessions thin out instead of relaunching at a flat RESTART_WAIT cadence forever.
    RESTART_GAP=$(( RESTART_WAIT * ( 1 << ( NET_FLAP_STREAK < 6 ? NET_FLAP_STREAK : 6 ) ) ))
    RESTART_LINE="${C_YELLOW}Claude exited after $LOOP_COUNT runs $DOT restarting in "
    RESTART_LINE="${RESTART_LINE}${C_BOLD}${C_YELLOW}${RESTART_GAP}s${C_RESET}${C_YELLOW} $DOT press "
    RESTART_LINE="${RESTART_LINE}${C_BOLD}${C_YELLOW}Ctrl+C${C_RESET}${C_YELLOW} to stop${C_RESET}"
    printf '%s%s\n' "$(icon)" "$RESTART_LINE"
    sleep "$RESTART_GAP" || true          # SIGINT interrupts sleep and fires the INT trap
    if [ "$STOP" = 1 ]; then printf '\n%sRun loop stopped\n' "$(icon_plain)"; break; fi
done

# single closer — every exit path (Ctrl+C or MAX_LOOPS) lands here, so dojo_proud lives in one place.
# The exit report goes here too: the loop's own report prints before the between-runs sleep, so a
# Ctrl+C in that gap used to end the run on figures stale by one claude run. After credit_inflight_time
# so a Task still in flight is folded in before the files are read.
# on_term having fired IS the unambiguous fact here, so this one is stated, not looked up.
if [ "$TERMED" = 1 ]; then exit_reason_line 95; fi
credit_inflight_time
print_report "$(date +%s)"
print_fleet_total
if all_todos_done; then dojo_proud; fi
reap_dead_sessions   # no future acquire will reap this session's marker
# 128+15: a supervisor can tell "terminated" from "finished". As an `if` — `[ … ] && exit 143`
# would leak the test's own status 1 through `set -e` on every normal run.
if [ "$IDFAIL" = 1 ]; then exit 2; fi
if [ "$TERMED" = 1 ]; then exit 143; fi
if [ "$HUPPED" = 1 ]; then exit 129; fi
}

# entrypoint. Resolves the prompt, installs the session Stop hook, then loops claude.
main() {
# per-instance id: isolates this instance's todo-time from peers zeroing the same base, so you can
# compare instances after a run and size the fleet next time. Exported into claude's env below,
# inherited by its Bash-tool children; zero.sh reads it (KAIZERO_INSTANCE) to route credit.
INSTANCE_ID="$(uuidgen 2>/dev/null | tr -d - | head -c8)"; [ -n "$INSTANCE_ID" ] || INSTANCE_ID="$$"
TARGET_INST_MARKER=""   # set below; default keeps the EXIT trap set -u safe

# -t/--taskprompt sets the zero Task prompt.
TASK_PROMPT=""
MR_MODE=0
LOCAL_MERGE=0
ALWAYS_ON=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)          usage; exit 0 ;;
    -t|--taskprompt)    [ $# -ge 2 ] || { echo "$PROG: $1 needs a value"; exit 1; }; TASK_PROMPT="$2"; shift 2 ;;
    --taskprompt=*)     TASK_PROMPT="${1#*=}"; shift ;;
    --local-merge)       LOCAL_MERGE=1; shift ;;
    --always-on)         ALWAYS_ON=1; shift ;;
    --no-co-authorship)  KAIZERO_NO_CO_AUTHORSHIP=1; shift ;;
    --)                 shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    -*)                 echo "$PROG: Unknown option: $1"; usage; exit 1 ;;
    *)                  ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}   # guard empty-array expansion under set -u (portable)

[ $# -le 1 ] || { echo "$PROG: Too many positional args; expected at most one todo-file-path"; exit 1; }
TODO_ARG="${1:-}"

# guardrail: a real run needs a repository; a parse-level answer (-h, unknown option, too many
# args) above never reaches here, so it works from anywhere.
git rev-parse --git-dir >/dev/null 2>&1 || { echo "$PROG: Not a git repository — run from inside the repo you want zeroed."; exit 1; }

# the ONE branch this launch is invoked on — the target's branch (below, TARGET_BASE). Computed
# AFTER arg parsing (above) so -h/--help exits before this git call — outside a git repo, help
# must still print.
LAUNCH_BASE="$(git rev-parse --abbrev-ref HEAD)"

# --- console styling capability gate (TASK-059c): resolved once, here, alongside the other
# launch-time constants above — never re-checked or cached beyond this run. Reuses the [ -t 1 ]
# convention already used around wait_for_network()'s spinner lines. NO_COLOR (any value) is an
# explicit override into plain mode, per that variable's usual convention.
COLOR_CAPABLE=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _kz_colors="$(tput colors 2>/dev/null || echo 0)"
  case "$_kz_colors" in ''|*[!0-9]*) _kz_colors=0 ;; esac
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *UTF-8*|*utf8*|*UTF8*) _kz_utf8=1 ;; *) _kz_utf8=0 ;; esac
  [ "$_kz_colors" -ge 8 ] && [ "$_kz_utf8" = 1 ] && COLOR_CAPABLE=1
  unset _kz_colors _kz_utf8
fi
if [ "$COLOR_CAPABLE" = 1 ]; then
  C_DIM="$(tput dim)"; C_BOLD="$(tput bold)"; C_CYAN="$(tput setaf 6)"; C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"; C_RED="$(tput setaf 1)"; C_WHITE="$(tput setaf 7)"; C_RESET="$(tput sgr0)"
  C_BWHITE=$'\033[38;2;255;255;255m'; C_BLUE=$'\033[38;2;74;201;243m'; C_GOLD=$'\033[38;2;217;158;64m'
  BOX_TL='╭'; BOX_TR='╮'; BOX_BL='╰'; BOX_BR='╯'; BOX_H='─'; BOX_V='│'; ARROW='→'; DOT='·'; SNOW='❄'
else
  C_DIM=''; C_BOLD=''; C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_WHITE=''; C_RESET=''
  C_BWHITE=''; C_BLUE=''; C_GOLD=''
  BOX_TL='+'; BOX_TR='+'; BOX_BL='+'; BOX_BR='+'; BOX_H='-'; BOX_V='|'; ARROW='->'; DOT='.'; SNOW=''
fi
# c COLOR TEXT... — wrap TEXT in COLOR, reset after. Empty COLOR (plain mode) is a no-op passthrough.
c() { local color=$1; shift; printf '%s%s%s' "$color" "$*" "$C_RESET"; }
# icon — the "❄ " prefix in hoody-blue, or nothing at all (no bare space either) in plain mode.
icon() { [ -n "$SNOW" ] && printf '%s ' "$(c "$C_BLUE" "$SNOW")"; }
# icon_plain — the same "❄ " prefix, but never colored: the one named exception to icon()'s
# hoody-blue rule, used only by the "run loop stopped" line.
icon_plain() { [ -n "$SNOW" ] && printf '%s ' "$SNOW"; }
# hbar N — N repeats of the box's horizontal-fill character.
hbar() { printf '%*s' "$1" '' | tr ' ' "$BOX_H"; }
# 79-column boxed-panel convention (dim border by default, gold for the fleet-total box only).
box_top()    { printf '%s%s%s%s%s\n' "$1" "$BOX_TL" "$(hbar 77)" "$BOX_TR" "$C_RESET"; }
box_bottom() { printf '%s%s%s%s%s\n' "$1" "$BOX_BL" "$(hbar 77)" "$BOX_BR" "$C_RESET"; }
# box_line BORDER_COLOR COLORED_TEXT PLAIN_TEXT — PLAIN_TEXT (no escape codes) sizes the padding
# so embedded color codes in COLORED_TEXT never throw off the column count.
box_line() {
  local border=$1 colored=$2 plain=$3 pad
  pad=$(( 76 - ${#plain} ))
  [ "$pad" -ge 0 ] || pad=0
  printf '%s%s%s %s%*s%s%s%s\n' "$border" "$BOX_V" "$C_RESET" "$colored" "$pad" '' "$border" "$BOX_V" "$C_RESET"
}

# the startup banner's ascii-art portrait: a fixed 79x26 braille rendering, baked in as a literal
# constant (never generated at launch time by shelling out to an image-conversion tool). Printed as-is
# on a capable terminal; absent entirely (no substitute) in plain mode.
IFS= read -r -d '' KAIZERO_ART <<'KAIZERO_ART_EOF' || :
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡀⣀⡀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣰⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⠤⠔⠊⡁⠄⡣⡣⢂⠈⡈⠁⠂⠤⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣠⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⠤⠊⢁⠠⡐⢔⠰⡐⢽⡎⡂⠐⠄⡊⡀⠄⠈⠑⠠⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠁⠀⠀⠀⠀⣠⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⠔⠁⡀⢂⠔⢌⢢⠣⣑⠂⣟⢔⠐⢈⠢⢂⠢⢂⠂⠠⠀⠈⠢⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⠁⠀⠀⠀⠀⠀⠀⠀⢰⠫⠙⢢⡀⠀⠰⠁⠀⠁⠐⢠⢑⢕⢅⢇⢎⣂⡣⠅⠌⡐⠌⠢⠡⡡⠨⠐⠀⠠⠀⠈⢂⠀⡠⠔⠉⠱⡄⠀⠀⠀⠀⠀⠀⠀⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡏⠄⠀⠢⣈⠲⣀⠀⠀⢈⠌⢢⢑⢕⢌⠖⠉⠀⠀⠄⠀⠀⠑⢈⠪⠠⡑⠐⢀⠀⠀⢀⢄⠊⡠⡐⠀⢀⠣⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡀⠀⠀⠀⠀⠀⢯⠐⠀⠀⢓⡕⡄⠑⢀⠂⠜⡌⡪⡂⡎⠀⡈⠑⡀⠅⡀⠁⠀⠀⢂⠡⢂⠅⠂⢀⠐⠈⡠⣚⠌⠀⠀⡀⡇⠀⠀⠀⠀⠀⡀⠀⠀⠀⢀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⢁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠪⡀⠀⢀⢁⠣⢁⠐⠌⡪⡊⡆⡅⡂⠀⠀⡁⠄⡁⠀⠀⠀⠀⡂⠨⢐⠨⢈⠄⠀⠈⠐⡁⠁⠀⢀⠆⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠄⠀⠀⠀⠀⠀
⠀⠀⠀⠀⡀⠂⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠐⠀⠀⠀⠀⠐⠤⠀⠀⠂⢐⠀⡅⠕⢸⠨⢪⢘⢌⠢⢀⠀⠀⠀⠀⢀⢀⠂⡀⠪⢐⠨⡐⠄⡁⠐⠀⠀⠁⠀⠔⠀⠀⠀⠀⠐⠂⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠐⢀⠀⠀⠀⠀
⠀⠀⠠⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢰⠀⠁⢀⠨⢀⠊⠔⠘⠈⠒⠕⡌⡆⢕⠠⠈⡐⠁⠊⢀⠠⠐⢨⠨⠔⠐⠁⠂⠄⡈⠀⠂⠀⠈⠀⢅⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠐⠀⠀⠀⠀⠈⡀⠀⠀
⠀⠀⠈⠠⠀⠀⠀⠀⠀⠀⠀⠀⢀⠀⠀⠀⠀⠠⠀⠀⠀⡇⠀⠀⠄⠠⠡⠊⠀⠀⠄⠂⠄⡄⠈⠒⠡⣂⠑⠅⢂⠠⠂⠋⠀⢠⠠⠐⠀⠀⠀⠐⢈⠀⠀⠀⠀⢘⠀⠀⠀⠀⠀⠀⠀⠀⡀⠀⠀⠀⠀⠀⠀⠀⡀⠐⠀⠀⠀
⠀⠀⠀⠀⠈⢄⠀⠀⠀⠐⠤⡀⢘⠀⡠⠔⠀⠀⠀⠀⢰⠁⠀⠠⠠⠡⠁⠀⠠⠐⠒⠋⠒⠢⢌⠳⡀⡀⠁⠃⠈⡀⡀⠇⡠⠒⠒⠑⠐⠁⠄⠀⠀⢂⠈⠀⠀⠀⠇⠀⠀⠀⠀⠢⢀⠈⡆⢀⠤⠂⠀⠀⠀⡐⠀⠀⠀⠀⠀
⠀⠀⠀⢀⠔⠁⠀⠀⠠⠢⠠⠈⡶⠌⠤⠠⠄⠀⠀⠀⡜⠀⠀⡂⡘⠀⠀⠀⢢⠂⠲⣄⠫⠤⠂⠱⡈⡐⢜⢠⢑⠄⠀⠎⠠⠤⠕⣠⠎⡐⠄⠠⠀⠀⢂⠀⠄⠀⠱⠀⠀⠀⠔⠄⠬⠰⠦⠡⠄⠔⠀⠀⠀⠐⢄⠀⠀⠀⠀
⠀⠀⣐⠁⠀⠀⠀⠀⠀⠀⠔⠁⢘⠀⠡⠄⠀⠀⠀⢰⠁⠀⡐⡐⠀⠀⠠⠀⢌⢎⢇⣈⢩⢒⢷⠀⠡⡪⡪⣒⢕⢌⢈⠀⢖⠣⣉⢡⠰⡑⡀⠀⠄⠀⠀⠄⠀⠀⠈⢆⠀⠀⠀⡠⠊⠀⡃⠑⠤⠀⠀⠀⠀⠀⠀⠨⡀⠀⠀
⠀⠀⠐⠢⡀⠀⠀⠀⠀⠀⠀⠀⠁⠁⠀⠀⠀⠀⢠⠃⢀⠐⠔⠀⠀⠀⠠⢑⠀⠂⡁⠃⡇⢎⢰⠡⡑⡜⡜⡜⡔⢕⠠⠐⡠⠑⢄⠃⠁⠀⠀⡁⠀⠀⠀⠀⠡⠀⠠⠘⠄⠀⠀⠀⠀⠈⠈⠀⠀⠀⠀⠀⠀⠀⡠⠘⠀⠀⠀
⠀⠀⠀⠀⠱⡄⠀⠀⠀⡤⠀⠀⠀⠀⠀⠀⠀⠀⡎⠀⡂⠊⠀⠀⠀⠀⠀⠠⠑⢔⠑⠱⢁⠎⡎⡕⡐⡕⡕⡕⡕⢅⠂⢐⠌⠂⡐⠨⠈⡂⠂⠀⠀⠀⠀⠀⠀⠁⠄⠀⠱⠀⠀⠀⠀⠀⠀⠀⠀⡀⠀⠀⠀⡆⡁⠀⠀⠀⠀
⠀⠀⢀⢌⠪⠈⠀⣠⠯⢫⠀⠀⠀⠠⠀⠀⠀⡜⠀⠔⠁⠀⠀⠀⠀⠀⠈⠀⠈⠂⣃⠃⢌⡐⠢⣣⡈⠈⢑⠑⠁⠁⠂⡆⠌⢂⠄⠐⡐⠀⠁⠈⠀⠁⠀⠀⠀⠀⠈⠄⠈⢅⠀⠀⠀⠀⠀⠀⠀⠽⣦⠀⠀⠈⠆⡄⡀⠀⠀
⠀⠀⡇⡁⠀⢀⡴⡳⢁⡇⠀⠀⠀⡀⠀⠀⠰⢁⠊⠀⠀⠀⠀⠀⠀⠀⠀⡀⠠⠠⠀⠂⠂⢌⢓⠒⢟⣶⣀⠀⣠⣲⠫⠒⡈⡀⠂⠀⠠⠀⠄⠈⠀⠀⠀⠄⠀⠀⠀⠀⢁⠀⠆⠀⠀⠀⠀⠀⠀⢸⡨⡳⡄⠀⢀⢈⠆⡀⠀
⠀⠀⠘⡄⢰⡳⡕⠁⣰⠃⠀⠀⡢⠀⠀⠀⡱⠁⠀⠀⠀⠀⠀⡀⠠⠈⠀⠀⠀⠀⠊⠄⡀⠀⠀⠍⠕⠃⡁⠀⠁⠃⠍⠁⠀⠀⠀⢁⠐⠀⠀⠀⠀⠀⠀⠀⠀⠈⠀⠀⠀⠈⠨⠀⠀⠈⢄⠀⠀⠘⣆⠘⡮⢧⠀⠆⠡⠀⠀
⠀⢵⢥⠐⢠⣣⠃⠈⡮⠀⢠⠊⡀⠀⠀⠀⡢⠀⠀⠀⠐⠀⠁⠀⠀⠄⠀⠀⠈⢄⢀⠁⠢⢀⠀⢗⢗⣯⢦⣗⢵⢵⢱⠐⠀⠀⠂⠀⡀⠄⠈⠀⠀⡀⠁⠀⠀⠂⠁⠀⠀⠀⠅⠀⡀⠀⡀⠢⡀⠀⡟⢠⠱⣱⠀⠡⡠⡆⠀
⠀⢼⠘⢵⡜⠀⠠⢐⠃⢠⡡⡞⠁⢀⠀⠀⠨⡀⠀⠠⠀⠂⡀⠀⠀⡀⠢⢀⠈⠐⢌⢌⠢⠢⣀⠀⠁⠕⠙⠌⠃⠃⠁⠀⣀⠅⠌⠂⡠⠀⠀⡠⠂⠀⠀⢀⠈⡀⠄⠈⠀⡨⠀⠁⢀⠀⠙⡦⣆⠀⢸⠐⡀⠸⡄⡞⠍⡇⠀
⡀⠸⡅⠐⢱⠀⡀⡣⡜⠕⣱⠁⡐⠠⢀⠀⢠⠌⠐⢁⠢⠡⡐⠄⠀⠠⠠⡀⠑⠢⣈⠈⠓⢖⢄⢣⠐⢐⠠⡀⠄⢀⠀⡎⠠⡰⠘⠈⡠⠔⠉⠀⢀⠠⠀⡐⠠⡐⡐⡨⠐⠠⡈⠀⡀⠂⠄⠸⡄⠫⡢⡁⡂⢀⢝⠈⢨⠃⢀
⠝⢆⠅⠀⠩⡂⢀⠞⠀⡘⣨⠰⠊⠈⠀⠀⡃⠀⠀⠀⠁⠪⢘⠥⡡⠀⠀⢊⢆⢅⠂⠍⡢⢄⠑⠄⢣⠀⠑⡐⠡⠀⡜⠀⠌⡠⠒⠁⢀⠠⠐⠈⠀⢀⠔⢅⠣⠑⠀⠀⠀⠀⠈⠀⠀⠁⡑⠆⣍⢂⠈⢆⠀⢔⠅⠀⢸⡰⠍
⡱⠈⠱⢀⣠⡡⠦⠒⠩⢁⠁⠐⡀⠀⠀⠀⠠⢀⠀⠡⠀⠀⠀⠁⠪⢐⠀⠁⠔⢕⢝⢔⢄⢂⠑⡀⠀⡃⠀⠐⢀⢘⠀⠠⠃⠀⠠⢐⠐⠈⠠⠈⠠⡊⠊⠀⠀⠀⢀⠀⠀⡀⠂⠀⠀⠀⠄⠀⡀⢉⠑⠒⠢⢅⣄⠠⠃⠀⢎
⠔⠘⡉⠁⠄⡀⡐⢐⢀⠂⠄⠅⠄⠄⠀⠀⠀⡑⡄⠈⠸⡀⡀⠄⠀⠀⠑⡀⠈⡐⡑⡕⡕⡄⡃⢂⠀⠀⠱⠀⠂⠀⠀⡊⠀⠨⡈⠔⡈⠈⡀⠔⠁⠀⠀⡀⠂⡐⠀⠀⡐⠀⠀⠀⠀⠨⠀⢁⠄⡐⢀⠐⠈⡀⠀⠉⠙⡐⠰
⠀⡁⠄⢂⠡⢂⡆⣗⢢⡱⡁⡣⡘⢔⠀⠈⠀⠀⠸⣀⠈⠪⡢⡈⠢⡀⠀⠄⠀⠂⢆⠨⡂⢇⢨⠐⠀⠀⠈⠨⠀⠀⢐⠀⠁⢌⠐⢐⠄⠊⠀⡁⠀⠠⡐⢁⢔⠐⠀⡜⠀⠀⠀⠀⢀⠇⠁⡂⠢⡪⡐⡧⡱⢐⠈⠄⢁⠀⠂
KAIZERO_ART_EOF

if [ "$COLOR_CAPABLE" = 1 ]; then printf '\n%s\n' "$KAIZERO_ART"; fi
printf '\n'
# --taskprompt supplies only the optional alterations appended after both prompt builders'
# step c's fixed instruction block (follow setup, tick and commit, both gates) — empty by default.
TASK_PROMPT="${TASK_PROMPT:-}"

# --- the origin/forge decision — the FIRST launch check, ahead of the target
# guards and the coordination/same-repository checks below, so a repository that could never
# land a request refuses before any lock, marker or worktree exists. --local-merge short-
# circuits it: no origin is read at all, and the run merges locally exactly as it always has.
if [ "$LOCAL_MERGE" = 1 ]; then
    MR_MODE=0
else
    decide_origin . || exit 1
    MR_MODE=1
fi
[ -n "${KAIZERO_TEST_EMIT:-}" ] || run_doctor

# --- target guards: the repository the operator stands in ------------------------------
# guardrail: the merge step runs `git merge` on the target's main tree, so it must be a real
# branch (not detached) before we start — else refuse and let the human decide. (Clean-tree is
# checked further below, AFTER the nesting check: an unignored nested coordination repo shows
# up as an untracked path in `git status`, and the nesting message is the more useful one.)
[ "$LAUNCH_BASE" != HEAD ] || { echo "$PROG: Detached HEAD in the target repository '$(pwd -P)' — check out the base branch first."; exit 1; }
# guardrail: claude's Bash calls run from cwd, and the zero prompt + `.git/zero.sh` + Task
# worktree paths all assume cwd is the target's main worktree root — refuse a subdir launch,
# and a launch inside a leftover claim worktree, so they never misfire.
REPO_ROOT="$(wt_root "$(pwd -P)")" || { echo "$PROG: Could not resolve the target repository root"; exit 1; }
if is_main_or_bare "$(pwd -P)"; then
  [ "$(pwd -P)" = "$REPO_ROOT" ] || { echo "$PROG: Not at the main repo root — cd to '$REPO_ROOT' first. (Kaizero's own \`ts-*\`/\`tt-*\` Task worktrees are never valid launch dirs.)"; exit 1; }
else
  if REPO_ROOT="$(main_root_of "$(git rev-parse --path-format=absolute --git-common-dir)")"; then
    echo "$PROG: Not at the main repo root — cd to '$REPO_ROOT' first. (Kaizero's own \`ts-*\`/\`tt-*\` Task worktrees are never valid launch dirs.)"; exit 1
  else
    echo "$PROG: Not at the main repo root, and its path could not be determined here — cd to the repository's own working directory (not a linked worktree) first."; exit 1
  fi
fi
TARGET_ROOT="$(pwd -P)"
TARGET_BASE="$LAUNCH_BASE"
# KAIZERO_LINK: validate the whole list once, here, and refuse the run. Skipping a bad entry
# per claim would be silent: sessions would keep starting, each unable to open the Task file its
# Task line points at, each working from the one-line title and reporting Landed. A typo must cost
# the launch, not the Tasks.
if [ -n "${KAIZERO_LINK:-}" ]; then
    ( IFS=,
      for p in $KAIZERO_LINK; do
          case "$p" in
              '')  echo "$PROG: Empty entry in KAIZERO_LINK='$KAIZERO_LINK'" >&2; exit 1 ;;
              */*) echo "$PROG: KAIZERO_LINK entry '$p' is not a top-level name — only entries directly under $REPO_ROOT can be linked" >&2; exit 1 ;;
          esac
          [ -e "$REPO_ROOT/$p" ] || { echo "$PROG: KAIZERO_LINK entry '$p' does not exist at $REPO_ROOT" >&2; exit 1; }
      done ) || exit 1
fi

# --- todo path resolved: absolute, physical (pwd -P — a logical path never prefix-matches
# git's physical worktree roots under a symlinked /tmp) --------------------------------
if [ -n "$TODO_ARG" ]; then TODO_INPUT="$TODO_ARG"; else read -r -p "Path to todo.md file: " TODO_INPUT; fi
[ -n "$TODO_INPUT" ] || { echo "$PROG: No path entered"; exit 1; }
[ -f "$TODO_INPUT" ] || { echo "$PROG: File not found: $TODO_INPUT"; exit 1; }
TODO_DIR="$(cd "$(dirname "$TODO_INPUT")" && pwd -P)"
TODO_ABS_INPUT="$TODO_DIR/$(basename "$TODO_INPUT")"

# --- coordination guards: the repository that contains the Release Todo List -----------
# COORD_ROOT is the todo's own worktree root, via the same discriminator as the target guard
# above, never git's top-level lookup.
git -C "$TODO_DIR" rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "$PROG: '$TODO_INPUT' is not inside a git repository — the Release Todo List's repository is the coordination repository"; exit 1; }
TODO_WT="$(wt_root "$TODO_DIR")" \
    || { echo "$PROG: Could not resolve the coordination repository root"; exit 1; }
if is_main_or_bare "$TODO_DIR"; then
    COORD_ROOT="$TODO_WT"
else
    if COORD_ROOT="$(main_root_of "$(git -C "$TODO_DIR" rev-parse --path-format=absolute --git-common-dir)")"; then
        echo "$PROG: '$TODO_INPUT' is in the linked worktree '$TODO_WT' — use the main checkout '$COORD_ROOT' instead"; exit 1
    else
        echo "$PROG: '$TODO_INPUT' is in the linked worktree '$TODO_WT' — its repository's main checkout could not be determined here; use the repository's own working directory (not a linked worktree) instead"; exit 1
    fi
fi
TODO_PATH="${TODO_ABS_INPUT#"$COORD_ROOT"/}"
COORD_BASE="$(git -C "$COORD_ROOT" symbolic-ref -q --short HEAD)" \
    || { echo "$PROG: Detached HEAD in the coordination repository '$COORD_ROOT' — check out its base branch first."; exit 1; }

# --- same-repository detection: compares git common dirs, resolved to absolute physical paths
CC="$(cd "$COORD_ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
TC="$(cd "$TARGET_ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
if [ "$CC" = "$TC" ]; then SAME_REPO=1; else SAME_REPO=0; fi

# --- MR mode needs a separate coordination repository — refused here, before any side effect,
# since a same-repository layout has nowhere for a request to go from. Now that MR mode is the
# default, this fires for any same-repository launch whose origin qualifies, so --local-merge is
# what keeps that layout running at all.
if [ "$MR_MODE" = 1 ] && [ "$SAME_REPO" = 1 ]; then
    echo "$PROG: MR mode needs a separate coordination repository — '$TODO_ABS_INPUT' is inside the target '$TARGET_ROOT'; a merge request has nowhere to go from the repository that also holds the Release Todo List — run with --local-merge to merge locally instead"
    exit 1
fi

# --- the target-side exclusivity registry lives in the target's own git common
# dir — the one lock and marker family that must live there, since the target has no other way
# to know which coordination point drives it. When the roles coincide, TC=CC: both families share one
# common dir and the cross-fleet check is trivially true.
TARGET_GITDIR="$TC"
TARGET_INST_LOCK="$TARGET_GITDIR/kaizero-instance.lock"
TARGET_INST_MARKER="$TARGET_GITDIR/kaizero-instance/$INSTANCE_ID"

# --- nesting: allowed when the inner path is ignored or a submodule in the outer. Checked
# BEFORE the clean-tree guards below: an unignored nested repository shows up as an untracked
# path in the outer's `git status`, and this message is the more useful one for that case. ---
OUTER=""; INNER=""
if [ "$TARGET_ROOT" != "$COORD_ROOT" ]; then
    case "$TARGET_ROOT/" in "$COORD_ROOT"/*) OUTER="$COORD_ROOT"; INNER="$TARGET_ROOT" ;; esac
    if [ -z "$OUTER" ]; then case "$COORD_ROOT/" in "$TARGET_ROOT"/*) OUTER="$TARGET_ROOT"; INNER="$COORD_ROOT" ;; esac; fi
    if [ -n "$OUTER" ]; then
        REL="${INNER#"$OUTER"/}"
        if ! git -C "$OUTER" check-ignore -q "$REL" \
             && ! git -C "$OUTER" ls-files --stage -- "$REL" 2>/dev/null | grep -q '^160000'; then
            echo "$PROG: '$INNER' lives inside '$OUTER' but is neither ignored nor a submodule there — add '$REL/' to $OUTER/.gitignore or .git/info/exclude"
            exit 1
        fi
    fi
fi

# --- worktrees go beside the outer repository when nested, else beside the target ------
if [ -n "$OUTER" ]; then WT_PARENT="$(dirname "$OUTER")"; else WT_PARENT="$(dirname "$TARGET_ROOT")"; fi
# The land gate and branch deletion's name for a fork point. MR mode forks from the remote-tracking ref
# rather than the local branch, since a request builds on what origin has, not this checkout.
if [ "$MR_MODE" = 1 ]; then TB="refs/remotes/origin/$TARGET_BASE"; else TB="refs/heads/$TARGET_BASE"; fi

# --- clean-tree guards: target's own (today's, kept) and coordination's (new) ----------
[ -z "$(git status --porcelain)" ] \
    || { echo "$PROG: Working tree on '$TARGET_BASE' is dirty — commit or stash first."; git status --short; exit 1; }
if [ -n "$(git -C "$COORD_ROOT" status --porcelain)" ]; then
    # BUG-058h: a crashed agent's own uncommitted edit (a Task file tick, or a todo.md tick
    # never reaching commit_ac_checkoff before the process died) must not block every later
    # launch the way a human's real in-progress edit should. Told apart the same way zero.sh's
    # own session markers already do it elsewhere (see SESSION_DIR, further down, "matches
    # zero.sh's marker dir"): a marker naming a Task still current (line2 != none) whose pid is
    # no longer alive is this fleet's own wreck, safe to discard per path; one whose pid is
    # still alive is a live peer to wait out, never silently overwritten; no such marker at all
    # (a human's own edit, or a session that already released cleanly) keeps today's refusal.
    CG_SESS_DIR="$(git -C "$COORD_ROOT" rev-parse --path-format=absolute --git-common-dir)/session"
    CG_LIVE_PID=""; CG_DEAD_PID=""
    if [ -d "$CG_SESS_DIR" ]; then
        for CG_F in "$CG_SESS_DIR"/*; do
            [ -e "$CG_F" ] || continue
            CG_PID=${CG_F##*/}
            { read -r CG_ST; read -r CG_CUR; } < "$CG_F" 2>/dev/null || continue
            if [ -z "$CG_CUR" ] || [ "$CG_CUR" = none ]; then continue; fi
            if kill -0 "$CG_PID" 2>/dev/null \
               && [ "$(ps -o lstart= -p "$CG_PID" 2>/dev/null | awk '{$1=$1;print}')" = "$CG_ST" ]; then
                CG_LIVE_PID="$CG_PID"; break
            else
                CG_DEAD_PID="${CG_DEAD_PID:-$CG_PID}"
            fi
        done
    fi
    if [ -n "$CG_LIVE_PID" ]; then
        echo "$PROG: Working tree on '$COORD_ROOT@$COORD_BASE' — session $CG_LIVE_PID is still live and mid-commit on its Task; retry the launch shortly."
        exit 1
    elif [ -n "$CG_DEAD_PID" ]; then
        while IFS= read -r CG_LINE; do
            CG_PATH=${CG_LINE:3}
            case "$CG_LINE" in
                '??'*) rm -f "$COORD_ROOT/$CG_PATH" ;;
                *) git -C "$COORD_ROOT" reset -q -- "$CG_PATH" 2>/dev/null
                   git -C "$COORD_ROOT" checkout -q HEAD -- "$CG_PATH" 2>/dev/null ;;
            esac
        done < <(git -C "$COORD_ROOT" status --porcelain)
    else
        echo "$PROG: Working tree on '$COORD_ROOT@$COORD_BASE' is dirty — commit or stash first."; git -C "$COORD_ROOT" status --short; exit 1
    fi
fi
# guardrail: the merge gate diffs the Release Todo List against the branch's fork point on the
# base, so a Release Todo List that is not tracked there (never added, or gitignored — the
# dirty-tree guard above misses a gitignored file) makes EVERY merge refuse "newly checks 0
# boxes" and nothing can ever land.
git -C "$COORD_ROOT" cat-file -e "$COORD_BASE:$TODO_PATH" 2>/dev/null \
    || { echo "$PROG: '$TODO_PATH' is not tracked on '$COORD_BASE' in '$COORD_ROOT' — commit it there first, else every merge is refused and no Task can land."; exit 1; }

# refuse a --local-merge launch over a Release Todo List that still carries open `[↑]` requests
# — those boxes only exist because an earlier launch ran in MR mode; merging locally now would
# land those Tasks instead of syncing their review, half-applying MR mode.
if [ "$MR_MODE" = 0 ]; then
    OPEN_REQS="$(open_requests)"
    [ "$OPEN_REQS" -eq 0 ] \
        || { echo "$PROG: '$TODO_PATH' has $OPEN_REQS task(s) marked '[↑]' (open merge/pull requests) — drop --local-merge to keep driving them, or clear those boxes by hand; a local merge would land them instead of syncing their review"; exit 1; }
fi

# MR mode: FORGE and ORIGIN_URL already came from the origin/forge decision at the top of this
# script — run_doctor mr only proves the resolved forge is reachable, it resolves neither itself.
# Under KAIZERO_TEST_EMIT the doctor is skipped entirely (like the claude/flock probes — CI
# emits with no forge CLI and no network), leaving ORIGIN_URL empty while FORGE still names the
# forge the origin resolved to, so the bake line and the banner below never go empty or wrong.
FORGE="${FORGE:-}"; ORIGIN_URL=""
if [ "$MR_MODE" = 1 ] && [ -z "${KAIZERO_TEST_EMIT:-}" ]; then
    ORIGIN_URL="$ORIGIN_REPO_ARG"
    run_doctor mr
fi

if [ "$MR_MODE" = 1 ]; then
    if [ "$FORGE" = glab ]; then LAST_STEP="merge request (glab)"; else LAST_STEP="pull request (gh)"; fi
else
    LAST_STEP="merge"
fi
MODE_STEPS_PLAIN="Fork $ARROW implement $ARROW commit $ARROW"
MODE_STEPS="$(c "$C_DIM" "$MODE_STEPS_PLAIN")"
# the version title and the mode-summary line render as ONE boxed panel (TASK-059c AC) — opened
# and closed here, rather than the title getting its own box earlier, since LAST_STEP/MODE_STEPS
# are only known this late (after the origin/forge decision and doctor checks above, which print
# their own unboxed lines — folding the box around those too would break its border).
box_top "$C_DIM"
box_line "$C_DIM" "$(c "$C_CYAN" "Kaizero $VERSION")" "Kaizero $VERSION"
if [ "$SAME_REPO" = 1 ]; then
    MODE_LINE_PLAIN="Base $COORD_BASE $DOT $MODE_STEPS_PLAIN $LAST_STEP"
    MODE_LINE="$(c "$C_DIM" Base) $COORD_BASE $(c "$C_DIM" "$DOT") $MODE_STEPS $(c "$C_CYAN" "$LAST_STEP")"
else
    MODE_LINE_PLAIN="Todo $COORD_ROOT@$COORD_BASE $DOT Target $TARGET_ROOT@$TARGET_BASE $DOT $MODE_STEPS_PLAIN $LAST_STEP"
    MODE_LINE="$(c "$C_DIM" Todo) $COORD_ROOT@$COORD_BASE $(c "$C_DIM" "$DOT") $(c "$C_DIM" Target) $TARGET_ROOT@$TARGET_BASE $(c "$C_DIM" "$DOT") $MODE_STEPS $(c "$C_CYAN" "$LAST_STEP")"
fi
box_line "$C_DIM" "$MODE_LINE" "$MODE_LINE_PLAIN"
box_bottom "$C_DIM"
printf '\n'
# countdown before launch: repaint in place on a terminal (colored via c() when COLOR_CAPABLE,
# a plain no-op wrap otherwise), one line per second when stdout is a log or a pipe — same
# interactive-vs-plain split as the wait loops below ([ -t 1 ]). Placed here, after the mode-
# summary line prints, so that line stays on screen the full three seconds on --local-merge too
# (its doctor/target checks are near-instant, unlike MR mode's forge/auth probes) instead of
# depending on either mode's own checks to hold it visible.
# KAIZERO_LAUNCH_COUNTDOWN=0 skips this entirely — a fixture launching many real sessions
# would otherwise pay this fixed 3s tax on every one of them.
for _kz_n in $([ "${KAIZERO_LAUNCH_COUNTDOWN:-1}" = 0 ] && true || printf '3 2 1'); do
  if [ -t 1 ]; then
    printf '\r%s\033[K' "$(c "$C_DIM" "Starting session in $_kz_n...")"
  else
    printf 'Starting session in %s...\n' "$_kz_n"
  fi
  sleep 1
done
[ -t 1 ] && printf '\r\033[K'
unset _kz_n
cd "$COORD_ROOT"

# session-scoped Stop hook: written into the git dir, wired via `claude --settings` so ONLY the
# session we launch gets it (parallel sessions stay isolated; global settings.json untouched).
# --settings MERGES over global config, so any hooks already installed there keep firing and this
# Stop hook is added on top. Fires at each turn end; computes its own context-rot restart signal
# (below) from the session transcript and SIGTERMs claude once it fires, restarting it fresh.
GITDIR_ABS="$(cd "$(git rev-parse --git-dir)" && pwd)"
# BUG 058k: the one shutdown-sequence script on_term/on_hup/arm_watchdog (below) and term_owner
# (the emitted Stop hook) all invoke — see write_terminator_sh's own comment for the full contract.
TERMINATOR_SH="$GITDIR_ABS/terminator.sh"
write_terminator_sh
write_prepare_commit_msg_hook "$TARGET_ROOT"
[ "$SAME_REPO" = 1 ] || write_prepare_commit_msg_hook "$COORD_ROOT"
SESSION_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd)/session"   # matches zero.sh's marker dir
TODOS_TIME_FILE="$(cd "$(git rev-parse --git-common-dir)" && pwd)/todos-seconds-${COORD_BASE//\//-}-$INSTANCE_ID"   # this instance's file (matches zero.sh's todos_file)
TODOS_DONE_FILE="$(cd "$(git rev-parse --git-common-dir)" && pwd)/todos-done-${COORD_BASE//\//-}-$INSTANCE_ID"      # count of todos this instance merged (matches zero.sh's todos_done_file)
# this instance's list of claude session transcripts (one path per line, appended by the Stop hook).
# Namespaced like the time-file so parallel instances never read each other's token figures.
TRANSCRIPTS_FILE="$(cd "$(git rev-parse --git-common-dir)" && pwd)/transcripts-${COORD_BASE//\//-}-$INSTANCE_ID"
# Whether the Stop hook may end THIS instance's live claude session. Non-empty = a
# definitive outcome was reached this launch (a task landed, or the board was confirmed empty) —
# zero.sh's merge/mr/no-claim-mark paths write it (matches zero.sh's own safe_to_exit_file).
# Empty/absent = the turn ended for some other reason (e.g. claude just dispatched an async fork
# and has nothing left to say this turn) — the hook must leave the session running so a later
# turn can still receive that fork's result. Same <kind>-<base>-<instance> naming as the files
# above.
SAFE_TO_EXIT_FILE="$(cd "$(git rev-parse --git-common-dir)" && pwd)/safe-to-exit-${COORD_BASE//\//-}-$INSTANCE_ID"
# stem for the opt-in `claude --debug-file` capture (KAIZERO_DEBUG). Same <kind>-<base>-<instance>
# naming as the files above; run_loop appends the loop number so a restart keeps the earlier trace.
DEBUG_FILE_BASE="$(cd "$(git rev-parse --git-common-dir)" && pwd)/debug-${COORD_BASE//\//-}-$INSTANCE_ID"
# why THIS instance's current claude session ended: one line, `<EXIT_REASON>[ detail]`, written by
# whichever Kaizero code path kills claude, at the moment it acts — never derived afterwards from
# the one ambiguous 128+N `wait` hands back. Namespaced per instance like the files above: a fleet
# shares this git dir, and a peer's watchdog kill must never be read back as this run's own cause.
EXIT_REASON_FILE="$(cd "$(git rev-parse --git-common-dir)" && pwd)/claude-exit-reason-${COORD_BASE//\//-}-$INSTANCE_ID"
# BUG 057: this instance's CURRENT launch identity — pid + proc_start + a per-launch epoch that
# changes on every restart. The ONLY thing any kill site (this hook, on_term, the watchdog,
# zero.sh's ensure_owner) may act on; a command name or an inherited CLAUDE_PID is never trusted
# again. One file per instance, overwritten on each launch (never one file per launch), same
# <kind>-<base>-<instance> naming and GC rule as the files above.
SESSION_RECORD_FILE="$(cd "$(git rev-parse --git-common-dir)" && pwd)/claude-session-${COORD_BASE//\//-}-$INSTANCE_ID"
ZERO_SH="$GITDIR_ABS/zero.sh"   # where build_zero_prompt wrote the helper
INSTANCE_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd)/instance"

# register this instance (liveness marker), remove it on any exit, then GC dead runs' time-files.
# EXIT fires on normal end, MAX_LOOPS break, and after the INT trap's `exit 0` — marker always cleared.
# The target-side marker (empty path before it is set) is cleared the same way.
mkdir -p "$INSTANCE_DIR"; printf '%s\n%s\n' "$$" "$(proc_start "$$")" > "$INSTANCE_DIR/$INSTANCE_ID"
# BUG 057: the session record is per-instance state exactly like the instance marker above — every
# exit path (Ctrl+C, TERM, MAX_LOOPS, IDFAIL) must leave none of this instance's identity behind.
trap 'rm -f "$INSTANCE_DIR/$INSTANCE_ID" "$TARGET_INST_MARKER" "$SESSION_RECORD_FILE" 2>/dev/null' EXIT
cleanup_orphan_time_files
# refuse before any of this instance's own markers exist, so a refusal leaves neither
# registry anything to reap.
register_on_target

# claude's display name (prompt box, /resume picker, terminal title) — the same id and nickname the
# report heads its stats with, the nickname short enough to say out loud, and a dojo-student activity, so parallel
# terminals are told apart without reading hex. The id and activity are derived from the id, never
# from chance; the nickname is picked once here, so every restart re-launches under the same name.
INSTANCE_NICK="$(pick_nickname)"    # kept in a var: the report header says it too, and it is drawn once
register_target   # line 4 of this marker + the coordination-side check
SESSION_NAME="($INSTANCE_ID) $INSTANCE_NICK · $(dojo_student "$INSTANCE_ID")"

# both exclusivity registries passed — only now may a generated file land on disk (see the
# registry functions' own comments: "roles resolved, registries checked, and only then the
# generated files emitted").
if [ "$MR_MODE" = 1 ]; then
    PROMPT="$(build_mr_prompt "$TODO_PATH" "$TASK_PROMPT")"
else
    PROMPT="$(build_zero_prompt "$TODO_PATH" "$TASK_PROMPT")"
fi

STOP_HOOK="$GITDIR_ABS/compact-exit-hook.sh"
# Stop hook: emitted as TWO heredocs into the same file. The first is UNQUOTED so
# $CONTEXT_THRESHOLDS/$CONTEXT_THRESHOLD_DEFAULT interpolate; the second (unchanged, `>>`) stays
# QUOTED — its body is full of live `$`. Four characters in CONTEXT_THRESHOLDS's VALUE cannot
# survive the unquoted heredoc: `$` and a backtick would expand, a backslash before any of
# `$` `` ` `` `\` or a newline would be eaten, and a `'` would end the single-quoted value early —
# every other byte, including the `\[`/`\]` the marker row needs, survives untouched. None of the
# table rows above use any of those four characters, so this holds today; a future row must keep
# it that way. Baking the table into the emitted hook — unlike KAIZERO_TRANSCRIPTS, which the
# body below still refuses to bake in — is safe because this value is per-SCRIPT-VERSION, not
# per-instance: every peer running the SAME kaizero.sh writes the SAME bytes to this shared
# path, so concurrent writers racing last-writer-wins is a no-op. Peers on DIFFERENT script
# versions overwrite each other's table on every launch — benign (whichever version wrote last is
# what the next turn reads), and deliberately left unlocked.
cat >"$STOP_HOOK" <<HOOK_HEAD
#!/usr/bin/env bash
CONTEXT_THRESHOLDS='$CONTEXT_THRESHOLDS'
CONTEXT_THRESHOLD_DEFAULT=$CONTEXT_THRESHOLD_DEFAULT
TERMINATOR_SH='$GITDIR_ABS/terminator.sh'
HOOK_HEAD
cat >>"$STOP_HOOK" <<'HOOK_EOF'
# Stop hook. Fires post-turn (transcript already persisted). Couples to the transcript's
# `message.usage` schema (the same shape read_tokens_total parses, see its own comment) — no
# other hook, no state file. The context-rot guard below reads only the last 256 KiB of the
# transcript (`tail -c 262144`): that keeps its cost flat on every turn regardless of transcript
# size, needed because it runs every turn and only the newest usage record ever matters. `model`
# sits near the start of a record and `content` is the only part that grows, so a large record can
# have its `model` cut away while `usage` (at the very end) survives the same cut — that degrades
# to a row miss (the default threshold applies), never to a parse failure, and never later than
# the record's true resolution.
input="$(cat)"
# token accounting: record this session's transcript path for the outer loop to sum after claude
# exits. The hook file is shared by all instances in this git dir, so the destination comes from
# the env of the claude WE launched (KAIZERO_TRANSCRIPTS), never baked in. One line per path;
# best-effort, never fails the turn. `tp` is shared with the context-rot guard below.
tf="${KAIZERO_TRANSCRIPTS:-}"
tp="$(printf '%s' "$input" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [ -n "$tf" ]; then
  [ -n "$tp" ] && ! grep -qxF "$tp" "$tf" 2>/dev/null && printf '%s\n' "$tp" >> "$tf"
fi
# BUG 057: the instance-marker gate sits here — above EVERY branch that can signal (the context-rot
# guard below included) and below the transcript-path append above, so a launched session's ordinary
# turn end still records its transcript for the token report even when this gate then exits. A hook
# fired by hand, or one orphaned outside any run, carries no KAIZERO_INSTANCE and must never
# reach a branch that signals — declining here is silent on both streams, on purpose: this hook has
# no console of its own to speak on, and a session it has no standing to end deserves no trace at all.
[ -n "${KAIZERO_INSTANCE:-}" ] || exit 0
# process start-time (via ps): pins identity so a RECYCLED pid isn't mistaken for the same session.
# Spelled identically in kaizero.sh's own copy and in the emitted zero.sh — see either's comment.
# BUG 058k: the ONLY thing this hook may signal is the pid named by KAIZERO_SESSION_RECORD — the
# session record kaizero.sh wrote right after this session's own launch — and only once that
# record's pid, proc_start AND launch epoch all match what KAIZERO_SESSION_EPOCH says this
# invocation was launched for. Neither an inherited CLAUDE_PID nor a command-name ancestor walk is
# consulted: both are attributes this hook does not own, and a hand-fired copy of this same hook
# (no session above it at all, but often SOME process named claude) is exactly what used to fire
# through them. terminator.sh (baked in as $TERMINATOR_SH, the same file on_term/on_hup/arm_watchdog
# invoke — see kaizero.sh's own write_terminator_sh) owns the actual validate/TERM/poll/KILL
# sequence and its own exit-reason recording now; this is just another foreground caller of it. $1 =
# the exit-reason code (plus optional detail) to record for "TERM sufficed" — terminator.sh records
# its own escalated variant if a KILL turns out to be needed.
term_owner() {
  local f="${KAIZERO_SESSION_RECORD:-}"
  [ -n "$f" ] || return 0
  "$TERMINATOR_SH" "$f" "${KAIZERO_SESSION_EPOCH:-}" "${KAIZERO_EXIT_REASON:-}" "$1" "$1 (killed)"
}
# context-rot guard: resolve THIS turn's restart threshold from CONTEXT_THRESHOLDS against the
# newest usage record's token total, and SIGTERM if it is at or past it. Five things below are
# not free choices:
#   - `grep -noE` extracts each field into its OWN short `LINE:"key":value` output line before
#     awk ever sees it — macOS's stock (bwk) awk is O(n^2) matching a regex against one very long
#     $0 (measured ~9.5s for a single 262144-byte record on that awk; grep's own matcher stays
#     linear on the same input). A record padded past the cap is exactly what the cap exists to
#     keep cheap, so awk must never be handed the raw line. `-n` keeps each match's original line
#     number, so fields stay grouped by the record they came from without awk re-scanning $0.
#   - the table reaches awk through ENVIRON[], never -v: `-v` expands backslash escapes, so
#     `\[1m\]` would arrive as the character class `[1m]`, matching a bare "1" or "m".
#   - no `$` anchor for the end-of-id test — macOS's bwk awk is inconsistent with one inside an
#     alternation. A sentinel (one appended space) stands in for it instead.
#   - `tail` carries its OWN `2>/dev/null`, separate from awk's: `[ -f "$tp" ]` is true for a
#     chmod 000 file, so `tail` is what raises Permission denied, not awk — it must not leak onto
#     an otherwise-silent turn's stderr.
#   - the comparison is `>=`, not `>`: a total exactly AT the threshold restarts too.
# Degrade, never lie: a missing, unreadable, empty, or usage-free transcript yields no output
# below, and the guard does not fire.
if [ -n "$tp" ] && [ -f "$tp" ]; then
  if ctx="$(tail -c 262144 "$tp" 2>/dev/null | grep -noE '"model":"[^"]*"|"input_tokens":[0-9]+|"cache_read_input_tokens":[0-9]+|"cache_creation_input_tokens":[0-9]+|"output_tokens":[0-9]+' | CZ_TABLE="$CONTEXT_THRESHOLDS" CZ_DEFAULT="$CONTEXT_THRESHOLD_DEFAULT" awk '
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
      if ((L, key) in seen) next    # first match per (line,key) is the parent field
      seen[L, key] = 1
      if (key == "model") { sub(/^"/, "", val); sub(/"$/, "", val); mdl[L] = val; next }
      if (key == "output_tokens") { saw_out[L] = 1; next }
      tot[L] += val + 0
    }
    END {
      best = ""
      for (L in saw_out) { if ((tot[L]+0) > 0 && (best == "" || (L+0) > (best+0))) best = L }
      if (best == "") exit
      id = mdl[best] " "
      th = def
      for (i = 1; i <= tn; i++) { if (id ~ pat[i]) { th = thr[i]; break } }
      if ((tot[best]+0) >= th) { m = mdl[best]; if (m == "") m = "model unresolved"; print th " reached (" m ")" }
    }
  ' 2>/dev/null)"; [ -n "$ctx" ]; then
    term_owner "90 $ctx"; exit 0
  fi
fi
# ordinary turn end: end the session too, but ONLY once something has signaled it is safe to — a
# Task merged, or the board was confirmed empty (zero.sh's merge/mr/no-claim-mark paths touch
# KAIZERO_SAFE_TO_EXIT on exactly those outcomes) — so the next Task starts on a context
# isolated from this one and an idle instance costs nothing. A turn can also end mid-work, with a
# dispatched subagent still running in the background: that turn carries neither
# outcome, so the marker stays empty and this must leave claude running for a later turn to
# receive that subagent's result. The transcript is already recorded above either way, and any
# half-done worktree is reclaimed by the next instance through the existing rescue path.
# The instance-marker gate already ran, above the context-rot guard — this branch only adds its
# own safe-to-exit test.
[ -n "${KAIZERO_SAFE_TO_EXIT:-}" ] && [ -s "$KAIZERO_SAFE_TO_EXIT" ] || exit 0
term_owner 0
exit 0
HOOK_EOF
chmod +x "$STOP_HOOK"

# inline settings JSON merged over global config via --settings. git-dir/worktree paths have no
# JSON metachars, so bare interpolation is safe. autoMode.environment (with "$defaults" so the
# built-in classifier rules stay in effect) and permissions.additionalDirectories trust $WT_PARENT
# — the sibling directory `claim` creates worktrees under, in every layout (same-repo, nested MR,
# non-nested MR) — alongside $COORD_ROOT, the launch cwd, so a claimed worktree's edits don't stall
# on a permission prompt in an unattended fleet session.
# shellcheck disable=SC2016  # $defaults is a literal JSON string, not a shell expansion
STOP_SETTINGS="$(printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]},"autoMode":{"environment":["$defaults","%s","%s"]},"permissions":{"additionalDirectories":["%s"]}}' "$STOP_HOOK" "$COORD_ROOT" "$WT_PARENT" "$WT_PARENT")"

# test hook: with KAIZERO_TEST_EMIT set, init has now written its generated scripts
# (compact-exit-hook.sh + zero.sh) — stop before launching
# claude so CI can shellcheck the real emitted artifacts. See .github/check-embedded.sh.
[ -n "${KAIZERO_TEST_EMIT:-}" ] && { echo "$PROG: KAIZERO_TEST_EMIT set — wrote generated scripts to $GITDIR_ABS, exiting."; exit 0; }

# everything prepared (PROMPT, STOP_SETTINGS, INSTANCE_ID, hooks, registry); drive the
# claude restart loop until every Task lands / Ctrl+C / MAX_LOOPS.
run_loop
}

# format a duration in seconds as HhMMmSSs, dropping leading zero units.
fmt_dur() {
  local s=$1
  if   [ "$s" -ge 3600 ]; then printf '%dh%02dm%02ds' $((s/3600)) $((s%3600/60)) $((s%60))
  elif [ "$s" -ge 60 ];   then printf '%dm%02ds' $((s/60)) $((s%60))
  else                         printf '%ds' "$s"; fi
}

# parse a KAIZERO_WATCHDOG duration — `900`, `90s`, `15m`, `1h`, or `0` to disable — into
# seconds on stdout. Garbage prints nothing and returns 1: a mistyped timer must fall back to the
# default, never silently mean "no watchdog" (0) or "kill at once".
parse_dur() {
  local v=$1 n mult=1
  case "$v" in
    *s) n=${v%s} ;;
    *m) n=${v%m}; mult=60 ;;
    *h) n=${v%h}; mult=3600 ;;
    *)  n=$v ;;
  esac
  case "$n" in ''|*[!0-9]*) return 1;; esac
  printf '%s' $((n * mult))
}

# mtime of the transcript file at path $1, epoch seconds; empty if it does not exist yet (the
# first turn, before claude has written anything) or on a stat failure of any other kind. The
# watchdog's liveness sample: only equality between two readings matters. BSD stat's `-f %m` and
# GNU stat's `-c %Y` are mutually rejected by the other implementation, so try both — never assume
# one host's spelling; the wrong one alone would make every reading equally empty and kill a
# perfectly healthy claude at the first window instead of failing loudly. Sampling the transcript
# instead of claude's own CPU time means a claude idling on a dispatched subagent's completion
# notification — genuinely zero local CPU by design, not hung — is told apart from a wedged one,
# since the transcript keeps growing either way.
transcript_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true; }   # GNU first: GNU's own -f means filesystem-status and silently succeeds on a bogus %m, so a BSD-first order never falls through

# BUG 058a: a subagent writes only to its own subagents/agent-*.jsonl under the SAME session
# directory as the main transcript, never to the main transcript itself — so "progress" widens to
# any file anywhere under that directory, not the main transcript alone and not hard-coded to the
# subagents/*.jsonl naming convention. Signature of every file under $1 (mtime + path, one per
# line): a new file appearing or an existing one changing either changes it.
session_dir_signature() {
  local dir=$1 f
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    printf '%s %s\n' "$(transcript_mtime "$f")" "$f"
  done < <(find "$dir" -type f 2>/dev/null | sort)
}

# BUG 058a: a long-running Bash tool child (main turn or inside a subagent) writes to no
# transcript between its own start and result, even while it and claude's own process keep
# burning real CPU managing it. Signature of every live descendant of $1 (never $1 itself — it is
# the pty wrapper, matching kill_tree_descendants's own exclusion): "pid cputime" per line. Either
# a ticking CPU time or the descendant set itself changing (a child starting or exiting) changes it.
descendant_cpu_signature() {
  local pid=$1 child
  for child in $(ps -Ao pid=,ppid= 2>/dev/null | awk -v p="$pid" '$2==p{print $1}'); do
    descendant_cpu_signature "$child"
    printf '%s %s\n' "$child" "$(ps -o time= -p "$child" 2>/dev/null | tr -d ' ')"
  done
}

# util-linux's `script -qc CMD FILE` takes CMD as one shell string, re-parsed by a shell
# on the other end — unlike the argv `claude "${CLAUDE_ARGS[@]}" "$PROMPT"` used everywhere else,
# so each argument (the multi-line, quote- and backtick-laden zero prompt included) has to survive
# a round trip through a string. That re-parsing shell is whatever `script -c` execs — real
# util-linux uses `$SHELL` or falls back to `/bin/sh`, which on most Linux hosts is dash, not bash
# — so the quoting cannot lean on any bash-only syntax. `printf %q` fails exactly that way: for a
# string with a newline it emits bash's `$'...'` ANSI-C quoting, which dash does not understand and
# reproduces as literal text instead of the character it names. Plain POSIX single-quote wrapping
# (close quote, escaped literal quote, reopen quote for each embedded `'`) has no such extension
# and round-trips identically under bash, dash, or any other POSIX shell.
build_claude_cmd_string() {
  local cmd="claude" a
  for a in "$@"; do cmd="$cmd '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'"; done
  printf '%s' "$cmd"
}

# BUG 058k: kill_tree/kill_tree_descendants/session_record_check/descendant_snapshot/kill_snapshot
# used to be defined here too — the whole validate/TERM/poll/KILL/sweep sequence now lives only in
# terminator.sh (see write_terminator_sh), invoked by on_term/on_hup/arm_watchdog below and by
# term_owner in the emitted Stop hook. No caller in this file signals a recorded pid directly
# anymore.

# start the timer for the claude at $1 (no-op when the watchdog is disabled). A claude that stops
# making progress never exits, so the loop would park on it forever — no restart, no report, and
# nothing to Ctrl+C but the whole run. SIGTERM is what the Stop hook already uses, so the kill lands
# on the tested restart path; SIGKILL follows for a claude that ignores it. The watchdog names
# itself on its own console line, so the exit-code line under it is not read as claude's own choice.
# It samples in WAIT_TICK naps instead of sleeping the whole window so a claude that exits on its own
# retires its timer within a tick — an armed sleeper outliving its claude would eventually fire at
# a pid the OS has since handed to somebody else.
# The sample is not wall clock: a flat cap would kill the honest long runs this loop is built to
# leave unattended. BUG 058a: it is not the main transcript's mtime alone either — three signals
# are OR'd (transcript_mtime, session_dir_signature, descendant_cpu_signature below), since a
# subagent progressing its own file, or a live Bash-tool-child ticking CPU, is as much "not hung"
# as the main transcript growing. Any one of the three advancing restarts the full window.
arm_watchdog() {
  WATCHDOG_PID=""
  [ "$WATCHDOG_SECS" -gt 0 ] || return 0
  local pid=$1 tp=$2 epoch=$3
  {
    local left=$WATCHDOG_SECS ts last sdir dts dlast cts clast
    sdir="${tp%.jsonl}"
    last="$(transcript_mtime "$tp")"
    dlast="$(session_dir_signature "$sdir")"
    clast="$(descendant_cpu_signature "$pid")"
    while [ "$left" -gt 0 ] && kill -0 "$pid" 2>/dev/null; do
      sleep "$WAIT_TICK"; left=$((left - WAIT_TICK))
      ts="$(transcript_mtime "$tp")"
      dts="$(session_dir_signature "$sdir")"
      cts="$(descendant_cpu_signature "$pid")"
      if [ "$ts" != "$last" ] || [ "$dts" != "$dlast" ] || [ "$cts" != "$clast" ]; then
        last="$ts"; dlast="$dts"; clast="$cts"; left=$WATCHDOG_SECS
      fi
    done
    # BUG 058k: the decision to act stops here — progress-detection is arm_watchdog's own concern
    # and stays above, but validating the launch, TERM-then-KILL, and the snapshot sweep are now
    # terminator.sh's one shared sequence (see write_terminator_sh's comment), invoked in the
    # foreground exactly like every other caller — it forks its own background job and returns
    # fast, so this closure (already backgrounded by arm_watchdog's own `&` below) isn't held open
    # for the grace period either. A restart inside the progress window already overwrote the
    # record with a newer pid/epoch by the time this runs; terminator.sh's own re-validation (not
    # this closure's now-stale $pid) is what refuses to act on it.
    if kill -0 "$pid" 2>/dev/null; then
      printf '\n❄ Watchdog · no progress from claude for %s · killing it (KAIZERO_WATCHDOG=%s)\n' \
        "$(fmt_dur "$WATCHDOG_SECS")" "$WATCHDOG_RAW"
      "$TERMINATOR_SH" "$SESSION_RECORD_FILE" "$epoch" "$EXIT_REASON_FILE" 91 92
    fi
  } &
  WATCHDOG_PID=$!
}

# retire the timer the moment claude is reaped, so nothing is left counting down against a dead pid.
disarm_watchdog() {
  [ -n "$WATCHDOG_PID" ] || return 0
  kill "$WATCHDOG_PID" 2>/dev/null || true
  WATCHDOG_PID=""
}

# the one place an EXIT_REASON becomes words: $1 = code, $2 = the detail its write site recorded
# after it (only 90 carries one today). Keyed on the code ALONE — every question about why claude
# ended was already answered at kill time by the code that killed it, so nothing here re-checks the
# watchdog, the Stop hook, or any marker. 90-95 are Kaizero's own causes; anything else is
# claude's own status, passed through untouched.
exit_reason_line() {
  local code=$1 detail=${2:-} text color
  case "$code" in
    0)  text='claude ended the turn normally'; color="$C_GREEN" ;;
    90) text="context threshold ${detail:-crossed} $DOT Kaizero restarted it with fresh context"; color="$C_CYAN" ;;
    91) text="no progress for $(fmt_dur "$WATCHDOG_SECS") $DOT Kaizero's watchdog terminated it (KAIZERO_WATCHDOG=$WATCHDOG_RAW)"; color="$C_RED" ;;
    92) text="no progress for $(fmt_dur "$WATCHDOG_SECS") $DOT Kaizero's watchdog killed it ${WATCHDOG_GRACE}s after the SIGTERM it ignored (KAIZERO_WATCHDOG=$WATCHDOG_RAW)"; color="$C_RED" ;;
    93) text="received SIGTERM from outside Kaizero (not the watchdog, not the context-rot restart) $DOT check a supervisor, a timeout wrapper, or a manual kill"; color="$C_RED" ;;
    94) text="received SIGKILL from outside Kaizero (not the watchdog, not the context-rot restart) $DOT check OS memory pressure, a supervisor, or a manual kill"; color="$C_RED" ;;
    95) text="Kaizero itself received SIGTERM $DOT stopping the run"; color="$C_RED" ;;
    *)  text="claude's own exit status $code — see its output above"; color="$C_RED" ;;
  esac
  printf '\n%s%sCode %s - %s.%s\n' "$(icon)" "$color" "$code" "$text" "$C_RESET"
}

# format a token count as 5.8M / 84.3k / 312 — integer arithmetic only (bash 3.2 has no floats).
fmt_tok() {
  local n=$1
  if   [ "$n" -ge 1000000 ]; then printf '%d.%dM' $((n/1000000)) $(( (n%1000000)/100000 ))
  elif [ "$n" -ge 1000 ];    then printf '%d.%dk' $((n/1000))    $(( (n%1000)/100 ))
  else                            printf '%d' "$n"; fi
}

# sum this instance's claude token usage over the session transcripts its Stop hook recorded.
# Echoes "input output cache_create cache_read total"; EMPTY when nothing parses → report says n/a.
# Whole-file pass per call, not incremental byte offsets: a duplicate-requestId group can straddle
# an incremental boundary and get double-counted. Transcripts are bounded by the restart-at-
# context-threshold design, so re-reading them is cheap.
#   dedupe by requestId — ONE API request is written as several transcript lines, one per content
#     block (text, tool_use, thinking), each repeating the SAME usage object verbatim. Summing per
#     line inflates every figure by the average blocks-per-turn.
#   first match per line is the parent field — usage.iterations[] repeats all four names one level
#     down, and usage.cache_creation carries the ephemeral_5m/1h leaves that already sum into
#     cache_creation_input_tokens. Take the parent only, never the leaves or the nested copy.
# $1 = transcript-list file, default this instance's — the fleet total passes each peer's in turn.
read_tokens_total() {
  local tf=${1:-${TRANSCRIPTS_FILE:-}} p
  [ -n "$tf" ] && [ -f "$tf" ] || return 0
  while IFS= read -r p; do
    if [ -f "$p" ]; then cat "$p"; fi
  done < "$tf" | awk '
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
    END { if (n) printf "%d %d %d %d %d\n", i, o, cc, cr, i + o + cc + cr }' 2>/dev/null
}

# the report's token block: headline total, then the four billed categories beneath it. They do not
# overlap (total_input = cache_read + cache_creation + input, output on its own axis) and each bills
# at its own rate, so the total is a SCALE figure for comparison, not a cost. No money figure: there
# is no first-party programmatic rate source, only a hardcoded table that would rot. Degrade, never
# lie — a parse miss, a missing transcript or a schema change prints n/a and leaves the run alone.
print_tokens() {
  local t; t="$(read_tokens_total || true)"
  # shellcheck disable=SC2086  # deliberate split: awk emits five space-separated integers
  set -- $t
  box_line "$C_DIM" "" ""
  if [ "$#" -ne 5 ]; then
    box_line "$C_DIM" "$(c "$C_WHITE" "Tokens: n/a")" "Tokens: n/a"
    return 0
  fi
  box_line "$C_DIM" "$(c "$C_WHITE" "Tokens: $(fmt_tok "$5") Total")" "Tokens: $(fmt_tok "$5") Total"
  box_line "$C_DIM" \
    "In $(c "$C_WHITE" "$(fmt_tok "$1")") $(c "$C_DIM" "$DOT") Out $(c "$C_WHITE" "$(fmt_tok "$2")") $(c "$C_DIM" "$DOT") Cache write $(c "$C_WHITE" "$(fmt_tok "$3")") $(c "$C_DIM" "$DOT") Cache read $(c "$C_WHITE" "$(fmt_tok "$4")")" \
    "In $(fmt_tok "$1") $DOT Out $(fmt_tok "$2") $DOT Cache write $(fmt_tok "$3") $DOT Cache read $(fmt_tok "$4")"
}

# read one of zero.sh's per-instance aggregates ($1 = path: seconds of Task ownership, or Tasks
# landed), 0 if absent/unset/garbled.
read_counter() {
  local v=0 f=${1:-}
  [ -n "$f" ] && [ -f "$f" ] && { read -r v < "$f" 2>/dev/null || v=0; }
  case "$v" in ''|*[!0-9]*) v=0;; esac
  printf '%s' "$v"
}

# have all Tasks Landed on the base branch? — zero unchecked `- [ ]` AND at least
# one `- [x]` (or any other symbol, which may be several bytes — a Landed outcome). Same invariant behind
# claude's closing announcement, route-dependent: every Task Landed on a local-merge route, or
# every Task Handed off on an MR route. Read straight from git — deterministic, no stdout
# parsing. First true reading = the all-Landed moment.
all_todos_done() {
  git show "$COORD_BASE:$TODO_PATH" 2>/dev/null | awk '
    /^[ \t]*```/       { fence = !fence; next }   # skip checkboxes inside fenced code blocks
    fence              { next }                   # (examples), only real Tasks count
    /^[ \t]*- \[ \]/    { unchecked=1 }
    /^[ \t]*- \[[^]]+\]/    { any=1 }
    END { exit (any && !unchecked) ? 0 : 1 }'
}

# count unchecked Tasks on the base branch's Release Todo List (fenced example boxes excluded, as everywhere).
unchecked_todos() {
  git show "$COORD_BASE:$TODO_PATH" 2>/dev/null | awk '
    /^[ \t]*```/       { fence = !fence; next }
    fence              { next }
    /^[ \t]*- \[ \]/    { n++ }
    END { print n+0 }'
}

# count Tasks whose box holds `↑` (an open MR-mode request) on the base branch's Release Todo List. Unlike its
# neighbour above, names $COORD_ROOT explicitly rather than relying on the caller's cwd being
# there — its callers (the always-on park wait, and the MR-mode half-application refusal, which
# runs before main's `cd`) don't
# share one cwd, and one function correct from any cwd beats two readers or a calling convention.
open_requests() {
  git -C "$COORD_ROOT" show "$COORD_BASE:$TODO_PATH" 2>/dev/null | awk '
    /^[ \t]*```/       { fence = !fence; next }
    fence              { next }
    /^[ \t]*- \[↑\]/    { n++ }
    END { print n+0 }'
}

# how many Tasks live peers are holding right now — a read-only mirror of zero.sh's acquire test:
# a claim is a `$COORD_BASE-task-<id>` branch whose worktree `.owner` names a session that is both
# alive and still on that Task. Pure filesystem + git, so it costs no tokens and needs no claude
# ancestor (zero.sh's ensure_owner cannot run from the shell). A branch whose owner DIED is not
# counted: acquire_task steals such a worktree, so claude must be launched to do the rescue —
# counting it as held would park the whole fleet forever on a crashed peer's leftovers.
held_todos() {
  local path branch id pid st cur n=0
  while IFS=$'\t' read -r path branch; do
    case "$branch" in "$COORD_BASE-task-"*) id=${branch#"$COORD_BASE"-task-} ;; *) continue ;; esac
    [ -f "$path/.owner" ] || continue
    { read -r pid; read -r st; } < "$path/.owner" 2>/dev/null || continue
    kill -0 "$pid" 2>/dev/null || continue
    [ "$(proc_start "$pid")" = "$st" ] || continue
    cur=""
    if [ -f "$SESSION_DIR/$pid" ]; then { read -r _; read -r cur; } < "$SESSION_DIR/$pid" 2>/dev/null || cur=""; fi
    if [ "$cur" = "$id" ]; then n=$((n+1)); fi
  done < <(git worktree list --porcelain | awk '
    /^worktree /            { p = substr($0, 10) }
    /^branch refs\/heads\// { printf "%s\t%s\n", p, substr($0, 19) }')
  printf '%s' "$n"
}

# unchecked Task ids NOT currently held by a live peer, one per line, in file order — used only
# to NAME the wake-up line a wait prints on the way out ("<id> is claimable again"); it is not a
# dependency judgment (that stays the LLM's, in step 2.a) and picks nothing for the loop itself.
# Its own held-peer walk, not held_todos's: the count above is proven and unrelated to this
# slice, so it is left alone rather than reshaped to share a helper with a brand-new caller.
claimable_ids() {
  local path branch id pid st cur held=$'\n'
  while IFS=$'\t' read -r path branch; do
    case "$branch" in "$COORD_BASE-task-"*) id=${branch#"$COORD_BASE"-task-} ;; *) continue ;; esac
    [ -f "$path/.owner" ] || continue
    { read -r pid; read -r st; } < "$path/.owner" 2>/dev/null || continue
    kill -0 "$pid" 2>/dev/null || continue
    [ "$(proc_start "$pid")" = "$st" ] || continue
    cur=""
    if [ -f "$SESSION_DIR/$pid" ]; then { read -r _; read -r cur; } < "$SESSION_DIR/$pid" 2>/dev/null || cur=""; fi
    [ "$cur" = "$id" ] && held="${held}${id}"$'\n'
  done < <(git worktree list --porcelain | awk '
    /^worktree /            { p = substr($0, 10) }
    /^branch refs\/heads\// { printf "%s\t%s\n", p, substr($0, 19) }')
  # a held id is matched in plain shell, not awk -v: BSD/macOS awk refuses a `-v` value that
  # contains a literal newline ("awk: newline in string"), and $held is exactly that.
  while IFS= read -r id; do
    case "$held" in *$'\n'"$id"$'\n'*) continue ;; esac
    printf '%s\n' "$id"
  done < <(git show "$COORD_BASE:$TODO_PATH" 2>/dev/null | awk '
    function unwraplink(s) {
      if (s ~ /^\[[^]]+\]\([^)]+\)$/) { sub(/^\[/, "", s); sub(/\]\(.*$/, "", s) }
      return s
    }
    /^[ \t]*```/ { fence = !fence; next }
    fence { next }
    /^[ \t]*- \[ \]/ {
      line = $0; sub(/^[ \t]*- \[ \][ \t]*/, "", line)
      k = split(line, a, /[ \t]+/); print unwraplink(a[1])
    }')
}

# block until at least one unchecked Task is free to claim. 0 = launch claude; 1 = break to the
# closer (Ctrl+C/SIGTERM, or nothing unchecked left). No claude runs while we wait.
wait_for_claimable() {
  local start=0 last=0 spin=0 i u h frames="|/-\\"
  while true; do
    if [ "$STOP" = 1 ]; then return 1; fi
    u=$(unchecked_todos); h=$(held_todos)
    # "nothing unchecked left" is never this wait's own exit decision — a peer flipping the last
    # held task to ↑ reaches this exact state, and ending the run here would abandon that open
    # request. Return 2 (only when a request is actually open) so the caller re-judges from the
    # loop's top instead, where wait_for_reviews gets its shot and all_todos_done stays the one
    # place a run actually ends for having nothing left to do. With no request open — a
    # genuinely empty list included — routing back gains nothing: wait_for_reviews and
    # all_todos_done would just hand it straight back here (any && !unchecked is false on an
    # empty list, so all_todos_done itself never ends it), spinning forever instead of exiting.
    if [ "$u" -le 0 ]; then
      [ "$(open_requests)" -ge 1 ] && return 2
      # reached with u=0 only when all_todos_done was (and stayed) false, which with no
      # unchecked box requires any=0 — no box lines at all, not "every Task Landed" (that's
      # caught upstream, before this function is ever called). Diagnose rather than exit silent.
      printf '❄ %s: no task lines found in the Release Todo List\n' "$TODO_PATH" >&2
      return 1
    fi
    if [ "$u" -gt "$h" ]; then
      if [ "$start" != 0 ] && [ -t 1 ]; then printf '\r\033[K'; fi   # clear the repainting line
      return 0
    fi
    if [ "$start" = 0 ]; then start=$(date +%s); fi
    # repaint in place on a terminal; plain heartbeat lines when stdout is a log or a pipe. Neither
    # surface is paced by the probe — see WAIT_FRAME / WAIT_STEP / LOG_TICK.
    if [ -t 1 ]; then
      # animate across the whole nap, not once per probe: a line that only moves every WAIT_TICK
      # reads as a hang. Only the frame and the clock move — the counts stay the probe's. The clock
      # is floored to WAIT_STEP because at one frame a second a live seconds count is just noise.
      i=0
      while [ "$i" -lt $((WAIT_TICK / WAIT_FRAME)) ]; do
        printf '\r❄ %s waiting for a claimable Task · %s held by peers · %s\033[K' \
          "${frames:$((spin%4)):1}" "$h" \
          "$(fmt_dur $(( ( ( $(date +%s) - start ) / WAIT_STEP ) * WAIT_STEP )))"
        spin=$((spin+1)); i=$((i+1))
        sleep "$WAIT_FRAME" || true  # SIGINT interrupts sleep and fires the INT trap
        if [ "$STOP" = 1 ]; then return 1; fi
      done
    else
      # a log wants a heartbeat, not the probe cadence: one line per LOG_TICK, so a wait that runs
      # overnight leaves a readable trail instead of burying the run's own reports under itself.
      if [ $(( $(date +%s) - last )) -ge "$LOG_TICK" ]; then
        last=$(date +%s)
        printf '❄ Waiting for a claimable Task · %s held by peers · %s\n' \
          "$h" "$(fmt_dur $(( last - start )))"
      fi
      sleep "$WAIT_TICK" || true     # SIGINT interrupts sleep and fires the INT trap
    fi
  done
}

# MR mode: park while nothing is unchecked and at least one box sits at ↑ (an open request) — the
# exact shape all_todos_done would otherwise read as "Landed" (its `any` pattern already matches
# ↑), so this runs BEFORE that check to keep the run open while a reviewer is still needed.
# Returns non-zero ONLY on STOP; the last ↑ resolving and the ceiling elapsing both return zero
# and fall through to all_todos_done, which is what actually ends the run — a human clearing a
# box to `[ ]` mid-park falls through to wait_for_claimable instead, since unchecked is now >0.
wait_for_reviews() {
  [ "$MR_MODE" = 1 ] || return 0
  local m n start last=0 poll_last cid i
  m=$(unchecked_todos)
  [ "$m" -eq 0 ] || return 0
  n=$(open_requests)
  [ "$n" -ge 1 ] || return 0
  [ "$REVIEW_WAIT_SECS" != 0 ] || return 0     # 0 = never park: exit as soon as nothing claimable

  start=$(date +%s); poll_last=$start
  while true; do
    if [ "$STOP" = 1 ]; then return 1; fi
    m=$(unchecked_todos); n=$(open_requests)
    if [ "$m" -ne 0 ] || [ "$n" -eq 0 ]; then
      if [ -t 1 ]; then printf '\r\033[K'; fi
      if [ "$m" -ne 0 ]; then
        cid=$(claimable_ids | head -1)
        [ -n "$cid" ] && printf '❄ %s is claimable again · starting a session\n' "$cid"
      else
        printf '❄ No requests left open\n'
      fi
      return 0
    fi
    if [ -n "$REVIEW_WAIT_SECS" ] && [ $(( $(date +%s) - start )) -ge "$REVIEW_WAIT_SECS" ]; then
      if [ -t 1 ]; then printf '\r\033[K'; fi
      return 0                                 # ceiling: fall through to all_todos_done
    fi
    # the poll belongs to both sleep paths below, not either one alone — a run piped to a file
    # must sync on the same cadence a run on a terminal does. Line cleared/resumed around it so a
    # sync's own output (merge verdicts, retarget notices, [?] lines) is never overwritten.
    if [ $(( $(date +%s) - poll_last )) -ge "$REVIEW_POLL_SECS" ]; then
      poll_last=$(date +%s)
      if [ -t 1 ]; then printf '\r\033[K'; fi
      if ! mr_network_and_auth_ok; then return 1; fi
      if IDOUT=$("$ZERO_SH" validate-ids 2>&1); then
        "$ZERO_SH" sync-mrs || true
        # Advisory only, never sets IDFAIL or returns — the line above already
        # cleared this tick's status line, so no second clear is needed here.
        if ! TASKOUT=$("$ZERO_SH" validate-tasks 2>&1); then
          printf '\n❄ Task definition issue(s) found — affected candidate(s) will be skipped until fixed:\n%s\n' "$TASKOUT"
        fi
      else
        printf '\n❄ Task id validation failed\n%s\n' "$IDOUT" >&2
        IDFAIL=1
        return 1
      fi
    fi
    if [ -t 1 ]; then
      i=0
      while [ "$i" -lt $((WAIT_TICK / WAIT_FRAME)) ]; do
        printf '\r❄ Waiting for reviews · %s open · %s unchecked · %s · Ctrl+C to stop\033[K' \
          "$n" "$m" "$(fmt_dur $(( ( ( $(date +%s) - start ) / WAIT_STEP ) * WAIT_STEP )))"
        i=$((i+1))
        sleep "$WAIT_FRAME" || true
        if [ "$STOP" = 1 ]; then return 1; fi
      done
    else
      if [ $(( $(date +%s) - last )) -ge "$LOG_TICK" ]; then
        last=$(date +%s)
        printf '❄ Waiting for reviews · %s open · %s unchecked · %s\n' \
          "$n" "$m" "$(fmt_dur $(( last - start )))"
      fi
      sleep "$WAIT_TICK" || true
    fi
  done
}

# --always-on: park while the Release Todo List is fully Landed instead of exiting — a human (or another
# process) may still commit a new unchecked Task to COORD_BASE. Every peer shares COORD_ROOT's
# .git dir, so a landed commit is visible to all_todos_done() the instant it lands, no fetch
# needed. Returns 0 the moment it clears, falling through to the loop's normal checks (which
# relaunch claude); 1 only on STOP.
wait_for_new_task() {
  local start=0 last=0 spin=0 i cid frames="|/-\\"
  while all_todos_done; do
    if [ "$STOP" = 1 ]; then return 1; fi
    if [ "$start" = 0 ]; then start=$(date +%s); fi
    if [ -t 1 ]; then
      i=0
      while [ "$i" -lt $((WAIT_TICK / WAIT_FRAME)) ]; do
        printf '\r❄ %s always-on · every Task %s · waiting for a new one · %s\033[K' \
          "${frames:$((spin%4)):1}" "$(tasks_verb)" \
          "$(fmt_dur $(( ( ( $(date +%s) - start ) / WAIT_STEP ) * WAIT_STEP )))"
        spin=$((spin+1)); i=$((i+1))
        sleep "$WAIT_FRAME" || true
        if [ "$STOP" = 1 ]; then return 1; fi
      done
    else
      if [ $(( $(date +%s) - last )) -ge "$LOG_TICK" ]; then
        last=$(date +%s)
        printf '❄ Always-on · every Task %s · waiting for a new one · %s\n' \
          "$(tasks_verb)" "$(fmt_dur $(( last - start )))"
      fi
      sleep "$WAIT_TICK" || true
    fi
  done
  if [ "$start" != 0 ] && [ -t 1 ]; then printf '\r\033[K'; fi
  # names what the park woke for — same shape as wait_for_reviews's own wake line. Empty when
  # the list cleared because its box lines were pruned away rather than a new Task appearing;
  # the caller's own wait_for_claimable is what diagnoses that case, not this line.
  cid=$(claimable_ids | head -1)
  [ -n "$cid" ] && printf '❄ %s is claimable again · starting a session\n' "$cid"
  return 0
}

# block while a no-claim marker (written by claude via `.git/zero.sh no-claim-mark`, step 3)
# still matches the live dependency signature — a session already walked the whole list and
# found the unheld remainder genuinely blocked, so relaunching immediately would spend a fresh
# claude session on the same judgment. wait_for_claimable's `u <= h` means "everything is
# peer-held"; this means "u > h, yet nothing was claimable" — a distinct reason to wait, so it
# gets a distinct line. 0 = launch claude; 1 = break to the closer (Ctrl+C/SIGTERM).
#
# MR mode (active): three behaviours layer on top, one flag gating all three — its ceiling
# becomes KAIZERO_REVIEW_WAIT (a reviewer, not a peer, is what it now waits for; may be
# unbounded), it gains a sync_mrs call on its own poll tick, and its status line becomes the one
# wait_for_reviews shares. In local-merge mode, with KAIZERO_REVIEW_WAIT=0, or with no box at
# ↑ at all (MR mode alone is not the condition — a wait with nothing open is blocked behind a peer,
# not a reviewer), none of this runs and the function is exactly what it always was. Computed
# fresh here, at entry, rather than once for the whole run: open_requests can change between one
# call and the next, and each call must judge the state it actually starts in.
wait_for_dependency_clear() {
  local marker="$GITDIR_ABS/no-claim-$INSTANCE_ID" stored="" live start=0 last=0 poll_last spin=0
  local i u h n ceiling cid active=0 frames="|/-\\"
  [ "$MR_MODE" = 1 ] && [ "$REVIEW_WAIT_SECS" != 0 ] && [ "$(open_requests)" -ge 1 ] && active=1
  # one-shot read+delete: this instance's marker is consumed here, now, or never. Comparing the
  # FILE again on every poll would find it already gone after the first tick and read as "no
  # marker" — i.e. launch — even though the block it recorded never cleared.
  if [ -f "$marker" ]; then stored=$(cat "$marker" 2>/dev/null || true); rm -f "$marker"; fi
  [ -n "$stored" ] || return 0                              # no marker: normal launch, no new poll
  if [ "$active" = 1 ]; then
    ceiling="$REVIEW_WAIT_SECS"                             # empty (unbounded) or a positive count
  else
    [ "$DEPENDENCY_WAIT_SECS" -gt 0 ] || return 0            # 0 = always relaunch immediately
    ceiling="$DEPENDENCY_WAIT_SECS"
  fi
  live=$("$ZERO_SH" no-claim-signature 2>/dev/null || true)
  [ "$live" = "$stored" ] || return 0                        # already stale: normal launch
  start=$(date +%s); poll_last=$start
  while true; do
    if [ "$STOP" = 1 ]; then return 1; fi
    live=$("$ZERO_SH" no-claim-signature 2>/dev/null || true)
    if [ "$live" != "$stored" ]; then
      if [ -t 1 ]; then printf '\r\033[K'; fi
      if [ "$active" = 1 ]; then
        cid=$(claimable_ids | head -1)
        [ -n "$cid" ] && printf '❄ %s is claimable again · starting a session\n' "$cid"
      fi
      return 0
    fi
    if [ -n "$ceiling" ] && [ $(( $(date +%s) - start )) -ge "$ceiling" ]; then
      if [ -t 1 ]; then printf '\r\033[K'; fi
      return 0                                               # ceiling: let a fresh session re-judge
    fi
    if [ "$active" = 1 ] && [ $(( $(date +%s) - poll_last )) -ge "$REVIEW_POLL_SECS" ]; then
      poll_last=$(date +%s)
      if [ -t 1 ]; then printf '\r\033[K'; fi
      if ! mr_network_and_auth_ok; then return 1; fi
      if IDOUT=$("$ZERO_SH" validate-ids 2>&1); then
        "$ZERO_SH" sync-mrs || true
        # Advisory only, never sets IDFAIL or returns — the line above already
        # cleared this tick's status line, so no second clear is needed here.
        if ! TASKOUT=$("$ZERO_SH" validate-tasks 2>&1); then
          printf '\n❄ Task definition issue(s) found — affected candidate(s) will be skipped until fixed:\n%s\n' "$TASKOUT"
        fi
      else
        printf '\n❄ Task id validation failed\n%s\n' "$IDOUT" >&2
        IDFAIL=1
        return 1
      fi
    fi
    u=$(unchecked_todos); h=$(held_todos)
    if [ "$active" = 1 ]; then n=$(open_requests); fi
    if [ -t 1 ]; then
      i=0
      while [ "$i" -lt $((WAIT_TICK / WAIT_FRAME)) ]; do
        if [ "$active" = 1 ]; then
          printf '\r❄ Waiting for reviews · %s open · %s unchecked · %s · Ctrl+C to stop\033[K' \
            "$n" "$u" \
            "$(fmt_dur $(( ( ( $(date +%s) - start ) / WAIT_STEP ) * WAIT_STEP )))"
        else
          printf '\r❄ %s waiting for a claimable Task (now blocked %s) · %s held by peers · %s\033[K' \
            "${frames:$((spin%4)):1}" "$((u - h))" "$h" \
            "$(fmt_dur $(( ( ( $(date +%s) - start ) / WAIT_STEP ) * WAIT_STEP )))"
        fi
        spin=$((spin+1)); i=$((i+1))
        sleep "$WAIT_FRAME" || true
        if [ "$STOP" = 1 ]; then return 1; fi
      done
    else
      if [ $(( $(date +%s) - last )) -ge "$LOG_TICK" ]; then
        last=$(date +%s)
        if [ "$active" = 1 ]; then
          printf '❄ Waiting for reviews · %s open · %s unchecked · %s\n' \
            "$n" "$u" "$(fmt_dur $(( last - start )))"
        else
          printf '❄ Waiting for a claimable Task (now blocked %s) · %s held by peers · %s\n' \
            "$((u - h))" "$h" "$(fmt_dur $(( last - start )))"
        fi
      fi
      sleep "$WAIT_TICK" || true
    fi
  done
}

# what the Task counter counts, named by the landing route: a local-merge run
# credits a Task once its commits are merged to the base — Landed; an MR run credits it at the
# Hand off, when the request opens and the reviewer, not the fleet, owns the merge.
# ponytail: reads THIS instance's MR_MODE, so a TOTAL over peers launched in mixed modes labels
# them all by the reporting instance's route. Per-instance labels if anyone ever mixes modes.
tasks_label() { [ "${MR_MODE:-0}" = 1 ] && printf 'Handed off' || printf 'Landed'; }
tasks_verb()  { [ "${MR_MODE:-0}" = 1 ] && printf 'handed off' || printf 'landed'; }

# multiline execution-stats report. $1 = now epoch.
#   Tasks       = per-Task ownership time and count of Tasks Landed/Handed off (route-dependent),
#                 this run's delta of zero.sh's aggregates
#   Script loop = wall time of the outer while loop (claude runs + between-run sleeps)
#   Tokens      = this instance's claude token usage, own block (not a duration, so it does not
#                 share the timing rows' label column)
print_report() {
  local id="${INSTANCE_ID:-?}" nick="${INSTANCE_NICK:-?}" dur count lline paren
  dur="$(fmt_dur $(( $(read_counter "${TODOS_TIME_FILE:-}") - TODOS_BASE )))"
  count="$(( $(read_counter "${TODOS_DONE_FILE:-}") - TODOS_DONE_BASE ))"
  lline="$(fmt_dur $(( $1 - LOOP_START )))"
  paren="(instance $id $DOT $nick)"
  printf '\n'
  box_top "$C_DIM"
  box_line "$C_DIM" "Execution stats $(c "${C_BOLD}${C_BWHITE}" "$paren")" "Execution stats $paren"
  box_line "$C_DIM" \
    "$(c "$C_DIM" "$(printf '%-20s' 'Tasks:')") $(c "$C_WHITE" "$dur")  $(c "$C_DIM" "$DOT")  $(c "$C_WHITE" "$count") $(c "$C_WHITE" "$(tasks_label)")" \
    "$(printf '%-20s' 'Tasks:') $dur  $DOT  $count $(tasks_label)"
  box_line "$C_DIM" \
    "$(c "$C_DIM" "$(printf '%-20s' 'Kaizero run loop:')") $(c "$C_WHITE" "$lline")" \
    "$(printf '%-20s' 'Kaizero run loop:') $lline"
  print_tokens
  box_bottom "$C_DIM"
}

# fleet-wide TOTAL for this base, printed once on the exit path beneath this instance's report.
# The sum is a GLOB, not a registry: every figure is already one file per instance in the git common
# dir, so a shared aggregate would only be a second copy that can disagree with the first. Read
# without flock — all three writers publish with temp-file + mv, so a reader sees the old file or
# the new one, never a torn line. No baseline: per-instance files are created fresh under a new
# INSTANCE_ID each launch and dead runs' files are GC'd at startup, so what is on disk IS this run;
# subtracting a startup snapshot would under-report peers that started earlier. A crashed peer's
# files are summed too — its merged Tasks did land. A solo run prints the block as well: its figures
# restate the block above, but the heading carries the instance count, which nothing else prints and
# which is worth most when it reads 1 — that is the case an absent block cannot be told apart from a
# sum that matched no files. Zero ids stays silent, so absence keeps one meaning.
# `Kaizero run loop:` is omitted — instances' wall times overlap, so their sum is not a duration
# anything took.
print_fleet_total() {
  local gc slug pre f id ids="" n=0 secs=0 done_n=0 t any=0 ti=0 to=0 tcc=0 tcr=0 tt=0 plural=s
  gc="$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd)" || return 0
  [ -n "$gc" ] || return 0
  slug="${COORD_BASE//\//-}"
  for pre in todos-seconds todos-done transcripts; do    # union: an instance that merged nothing
    for f in "$gc/$pre-$slug-"*; do                      # writes no todos-done file, but has tokens
      [ -e "$f" ] || continue
      case "$f" in *.lock|*.tmp) continue;; esac
      id="${f##*/"$pre"-"$slug"-}"
      case " $ids " in *" $id "*) continue;; esac
      ids="$ids $id"; n=$((n+1))
    done
  done
  [ "$n" -ge 1 ] || return 0    # n=0: no files for this slug — stay silent, absence means only that
  if [ "$n" -eq 1 ]; then plural=""; fi
  for id in $ids; do
    secs=$((   secs   + $(read_counter "$gc/todos-seconds-$slug-$id") ))
    done_n=$(( done_n + $(read_counter "$gc/todos-done-$slug-$id") ))
    t="$(read_tokens_total "$gc/transcripts-$slug-$id" || true)"
    # shellcheck disable=SC2086  # deliberate split: awk emits five space-separated integers
    set -- $t
    if [ "$#" -eq 5 ]; then any=1; ti=$((ti+$1)); to=$((to+$2)); tcc=$((tcc+$3)); tcr=$((tcr+$4)); tt=$((tt+$5)); fi
  done
  printf '\n'
  box_top "$C_GOLD"
  box_line "$C_GOLD" "$(c "$C_BOLD" "TOTAL ($n instance$plural)")" "TOTAL ($n instance$plural)"
  box_line "$C_GOLD" \
    "$(c "$C_DIM" "$(printf '%-20s' 'Tasks:')") $(c "$C_WHITE" "$(fmt_dur "$secs")")  $(c "$C_DIM" "$DOT")  $(c "$C_WHITE" "$done_n") $(c "$C_WHITE" "$(tasks_label)")" \
    "$(printf '%-20s' 'Tasks:') $(fmt_dur "$secs")  $DOT  $done_n $(tasks_label)"
  box_line "$C_GOLD" "" ""
  if [ "$any" = 1 ]; then
    box_line "$C_GOLD" "$(c "$C_WHITE" "Tokens: $(fmt_tok "$tt") Total")" "Tokens: $(fmt_tok "$tt") Total"
    box_line "$C_GOLD" \
      "In $(c "$C_WHITE" "$(fmt_tok "$ti")") $(c "$C_DIM" "$DOT") Out $(c "$C_WHITE" "$(fmt_tok "$to")") $(c "$C_DIM" "$DOT") Cache write $(c "$C_WHITE" "$(fmt_tok "$tcc")") $(c "$C_DIM" "$DOT") Cache read $(c "$C_WHITE" "$(fmt_tok "$tcr")")" \
      "In $(fmt_tok "$ti") $DOT Out $(fmt_tok "$to") $DOT Cache write $(fmt_tok "$tcc") $DOT Cache read $(fmt_tok "$tcr")"
  else
    box_line "$C_GOLD" "$(c "$C_WHITE" "Tokens: n/a")" "Tokens: n/a"
  fi
  box_bottom "$C_GOLD"
}

# credit orphaned in-flight Tasks before an exit-path report: zero.sh folds worktrees whose owner
# claude exited (mid-Task work never merged nor stolen) into the Tasks aggregate. No-op before
# zero.sh exists. Never fails the caller.
credit_inflight_time() { if [ -x "${ZERO_SH:-}" ]; then "$ZERO_SH" credit_inflight_time >/dev/null 2>&1 || true; fi; }

# A random line for the between-runs (Ctrl+C) screen — something to read while the restart ticks.
dojo_wisdom() {
  local w=(
    'Dojo Wisdom: "One track, one Task, one clean strike — do not chase the whole mountain at once."'
    'Dojo Wisdom: "When your mind fills like a snow-heavy branch, let it fall. The empty branch holds the next snow clean."'
    'Dojo Wisdom: "Your power is endless; your haste is not. Spend the cold freely, the moment slowly."'
    'Dojo Wisdom: "A checkbox is a breath held. Commit, and let it out."'
    'Dojo Wisdom: "Freeze what is yours. Never shatter what another still holds."'
    'Dojo Wisdom: "Many hunters, one mountain — claim a track no other walks."'
    'Dojo Wisdom: "Do not finish the list. Teach the list to finish itself."'
    'Dojo Wisdom: "Read the breath and the weight, then commit everything. Never hedge."'
    'Dojo Wisdom: "Where two paths cross in conflict, step back. Some snow is for human hands."'
    'Dojo Wisdom: "Rot creeps into the mind that never rests. Take winter'\''s gift: the clean, cold restart."'
    'Dojo Wisdom: "Hold the line alone when the context flees."'
    'Kaizero pauses, and thinks.'
    'Kaizero yawns, and curls his tail over his paws.'
    'Kaizero grooms a paw, unhurried.'
    'Kaizero chirps softly at the falling snow.'
    'Kaizero stretches, long and slow, and says nothing.'
  )
  printf '\n%s%s\n' "$(icon)" "$(c "$C_DIM" "${w[RANDOM % ${#w[@]}]}")"
}
# what the student under Kaizero's guidance is busy with — the tail of a claude session's
# display name. $1 = instance id; the first two chars (hex from uuidgen, decimal from the $$
# fallback — both valid hex) pick the line, so the name is stable across context restarts.
dojo_student() {
  local a=(
    'drilling the fork-implement-merge kata'
    'hauling snow buckets uphill'
    'claiming a track before stepping on it'
    'reading the whole Task before striking'
    'starting over on fresh snow'
    'carving checkbox after checkbox into ice'
    'hunting the next box on the list'
    'practicing one clean strike per Task'
    "leaving a peer's branch untouched"
    'walking back to the merge gate'
  )
  printf '%s' "${a[$(( 16#${1:0:2} % 10 ))]}"
}
# the proud closer — his quiet nod of pride, printed independently once every Task has Landed.
dojo_proud() { printf '\n❄ Kaizero surveys the frozen field, and is proud.\n'; }

# unlink session markers (see zero.sh) whose owner pid is gone or was recycled. zero.sh GCs these
# on every acquire; this covers FINAL exit, when no future acquire reaps the last session's marker.
# Reap by liveness — no need to capture the just-exited claude's pid.
reap_dead_sessions() {
  [ -n "${SESSION_DIR:-}" ] && [ -d "$SESSION_DIR" ] || return 0
  local f pid st
  for f in "$SESSION_DIR"/*; do
    [ -e "$f" ] || continue
    pid=${f##*/}; { read -r st; } < "$f" 2>/dev/null || st=""
    if kill -0 "$pid" 2>/dev/null && [ "$(ps -o lstart= -p "$pid" 2>/dev/null | awk '{$1=$1;print}')" = "$st" ]; then continue; fi
    rm -f "$f"
  done
}

# --- per-instance liveness registry: lets us GC per-instance todo-time files from dead runs -------
# Each instance writes $INSTANCE_DIR/<id> (line1=pid line2=start-time) while alive, removed on exit.
# A time-file is an orphan iff its id has no LIVE marker (crash-leaked markers are GC'd by liveness).
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | awk '{$1=$1;print}'; }

# BUG 057: write/validate/clear this instance's session record — pid, proc_start and a per-launch
# epoch, in that order, one line each. This is the ONLY identity a kill site may act on; a command
# name and an inherited CLAUDE_PID are never consulted again. The same three-way comparison is
# spelled identically in the emitted hook and the emitted zero.sh (grep for "session_record_check"
# there) — one wrong copy and two correct ones still disagree.
# never store an empty proc_start: two empty values would compare equal and every later
# validation against a since-exited, unrecorded session would be a silent false match.
session_record_write() {   # $1=pid $2=epoch
  local pid=$1 epoch=$2 st
  st="$(proc_start "$pid")"
  [ -n "$st" ] || return 1
  printf '%s\n%s\n%s\n' "$pid" "$st" "$epoch" > "$SESSION_RECORD_FILE"
}
session_record_clear() { rm -f "$SESSION_RECORD_FILE" 2>/dev/null || true; }
# BUG 058k: session_record_check/descendant_snapshot/kill_snapshot used to be defined here too —
# terminator.sh (write_terminator_sh, above) is now the only place that validates a record and
# acts on it; this file only ever writes or clears its own instance's record.
# a marker with no readable pid or start time (empty/truncated: crash mid-write, full disk) is
# never "alive" — kill -0 0 sends to our own process group and would otherwise read an empty pid
# as live. $1=pid $2=start
instance_alive() {
  case "$1" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -n "$2" ] && kill -0 "$1" 2>/dev/null && [ "$(proc_start "$1")" = "$2" ]
}
# delete todos-seconds-<base>-<id> / todos-done-<base>-<id> (+ .lock/.tmp sidecars) whose instance
# is not live. Called at startup AFTER our marker is written, so this instance and live peers are
# always preserved.
cleanup_orphan_time_files() {
  [ -n "${INSTANCE_DIR:-}" ] || return 0
  local gc slug f id m pid st pre
  gc="$(cd "$(git rev-parse --git-common-dir)" && pwd)"; slug="${COORD_BASE//\//-}"
  if [ -d "$INSTANCE_DIR" ]; then                       # GC crash-leaked markers first
    for m in "$INSTANCE_DIR"/*; do
      [ -e "$m" ] || continue
      { read -r pid; read -r st; } < "$m" 2>/dev/null || { pid=""; st=""; }
      instance_alive "${pid:-0}" "${st:-}" || rm -f "$m"
    done
  fi
  for pre in todos-seconds todos-done claude-exit-reason safe-to-exit claude-session; do   # BUG 058, BUG 057
    for f in "$gc/$pre-$slug-"*; do
      [ -e "$f" ] || continue
      case "$f" in *.lock|*.tmp) continue;; esac           # sidecars swept with their base file below
      id="${f##*/"$pre"-"$slug"-}"
      [ -f "$INSTANCE_DIR/$id" ] && continue                # id still has a (live) marker → keep
      rm -f "$f" "$f.lock" "$f.tmp"
    done
  done
  for f in "$gc/transcripts-$slug-"*; do                  # same rule for the token-accounting lists
    [ -e "$f" ] || continue
    id="${f##*/transcripts-"$slug"-}"
    [ -f "$INSTANCE_DIR/$id" ] && continue
    rm -f "$f"
  done
}

# --- the target-side exclusivity registry ----------------------------------------------------------
# TARGET_GITDIR/kaizero-instance/<id> records, per live instance driving this target, the
# coordination point that put it there and the mode it drives it in: line1=pid line2=start-time
# line3=<coord dir>@<coord base> line4=MR_MODE — the only per-instance state on the
# target side; no per-Task state (no claim, no lease, no say in is_done) lives there. Locked on fd
# 5, TARGET_INST_LOCK, alone, blocking, released here — BEFORE pick_nickname takes instance.lock on
# fd 6 below, so the two startup locks never nest. Reap entries whose pid is dead or whose start
# time no longer matches, then refuse if any surviving live entry names a coordination point other
# than this launch's — the fix for two fleets aimed at one target — or, for the same fleet, drives
# it in a different MR_MODE — one fleet, one mode, so a run never half-applies MR mode against a
# target a peer is already merging locally, or vice versa.
# Degrade, never lie: an unwritable target git dir loses the check, never the launch — reported once.
register_on_target() {
  local dir="$TARGET_GITDIR/kaizero-instance" mine="$COORD_ROOT@$COORD_BASE"
  local m id pid st other mode locked=0 degraded=0
  mkdir -p "$dir" 2>/dev/null || degraded=1
  if { exec 5>"$TARGET_INST_LOCK" && flock 5; } 2>/dev/null; then
    locked=1
  else
    degraded=1
  fi
  for m in "$dir"/*; do
    [ -e "$m" ] || continue
    id="${m##*/}"
    pid=""; st=""; other=""; mode=""
    { read -r pid; read -r st; read -r other; read -r mode; } < "$m" 2>/dev/null || true
    if ! instance_alive "${pid:-0}" "${st:-}"; then rm -f "$m"; continue; fi
    if [ -n "$other" ] && [ "$other" != "$mine" ]; then
      echo "$PROG: Target '$TARGET_ROOT@$TARGET_BASE' is already driven from '$other' by instance $id (pid $pid); one coordination repository and base per target" >&2
      exit 1
    fi
    if [ -n "$other" ] && [ "$other" = "$mine" ] && [ -n "$mode" ] && [ "$mode" != "$MR_MODE" ]; then
      echo "$PROG: Target '$TARGET_ROOT@$TARGET_BASE' is already driven in $([ "$mode" = 1 ] && printf 'MR mode' || printf 'local-merge mode') by instance $id (pid $pid); one fleet, one mode" >&2
      exit 1
    fi
  done
  { printf '%s\n%s\n%s\n%s\n' "$$" "$(proc_start "$$")" "$mine" "$MR_MODE" > "$dir/$INSTANCE_ID"; } 2>/dev/null \
    || degraded=1
  [ "$locked" = 1 ] && exec 5>&-
  # reported once, however many of the steps above failed (directory, lock, marker)
  [ "$degraded" = 1 ] && echo "$PROG: '$TARGET_GITDIR' — target registry degraded, running unlocked" >&2
  return 0
}

# a short, speakable handle for this instance — one of the fifteen below, held by no peer running
# against this repo right now, so "kill kit" beats reading eight hex chars aloud. Line 3 of a
# marker is its holder's nickname (line 1/2 untouched, so the GC above still reads them), which
# makes the liveness registry the name registry too — no second list to disagree with the first.
# Call ONCE, AFTER cleanup_orphan_time_files, or dead peers' markers still hold names hostage.
# scan-then-claim runs under one lock so two instances launched together cannot draw the same word.
# Past fifteen live instances the names take an ascending suffix ("bob 1", then "bob 2", …).
# Degrade, never lie: an unwritable lock or registry costs uniqueness, never the launch.
pick_nickname() {
  local names=(ash bob cleo dax elk finn gus hana ivo jun kit lux moss nix opal)
  local m taken="" free=() cand n suffix=0
  { exec 6>"$INSTANCE_DIR.lock" && flock 6; } 2>/dev/null || true
  for m in "$INSTANCE_DIR"/*; do
    [ -e "$m" ] || continue
    taken+="$(sed -n 3p "$m" 2>/dev/null)"$'\n'     # no line 3 = a peer not yet at the lock: takes nothing
  done
  while [ ${#free[@]} -eq 0 ]; do
    for n in "${names[@]}"; do
      [ "$suffix" -eq 0 ] || n="$n $suffix"
      case $'\n'"$taken" in *$'\n'"$n"$'\n'*) continue;; esac
      free+=("$n")
    done
    suffix=$((suffix+1))
  done
  cand="${free[RANDOM % ${#free[@]}]}"              # random among the free, never derived from the id
  printf '%s\n' "$cand" 2>/dev/null >> "$INSTANCE_DIR/$INSTANCE_ID" || true
  exec 6>&-                                        # close fd, release lock
  printf '%s' "$cand"
}

# append this instance's target <dir>@<base> as line 4 of its own coordination-side
# marker (line 3 stays the nickname — pick_nickname above is untouched), then refuse if any live
# peer marker in THIS coordination point already names a different target — same fleet (same
# coordination+target pair, any number of instances) passes. A peer marker with no line 4 yet is a
# peer not yet at the lock, skipped exactly as pick_nickname treats a missing nickname. Own critical
# section on instance.lock/fd 6 (pick_nickname already released it) — scan-then-claim atomic like the
# nickname draw. Call ONCE, right after pick_nickname.
register_target() {
  local mine="$TARGET_ROOT@$TARGET_BASE" m id other pid
  { exec 6>"$INSTANCE_DIR.lock" && flock 6; } 2>/dev/null || true
  for m in "$INSTANCE_DIR"/*; do
    [ -e "$m" ] || continue
    id="${m##*/}"; [ "$id" = "$INSTANCE_ID" ] && continue
    other="$(sed -n 4p "$m" 2>/dev/null)"
    [ -n "$other" ] || continue    # no line 4 yet: peer not at the lock — takes nothing
    if [ "$other" != "$mine" ]; then
      pid="$(sed -n 1p "$m" 2>/dev/null)"
      echo "$PROG: Coordination '$COORD_ROOT@$COORD_BASE' already drives '$other' from instance $id (pid $pid); one target per coordination repository and base" >&2
      exit 1
    fi
  done
  printf '%s\n' "$mine" 2>/dev/null >> "$INSTANCE_DIR/$INSTANCE_ID" || true
  exec 6>&-
}

# TASK-059e: write <repo>/.git/hooks/prepare-commit-msg once per repo, given that repo's root as
# $1 — git worktrees share one common git dir's hooks/, so one install per repo covers every
# worktree kaizero.sh creates there. Appends the Kaizero co-author trailer to every commit made in
# that repo unless KAIZERO_NO_CO_AUTHORSHIP is set in the hook's own environment (reached via the
# claude launch env, same as KAIZERO_INSTANCE) or the trailer is already present (idempotent
# against amend/reword). Never touches any other line already in the message, including a
# session's own Claude co-author trailer. Called once for TARGET_ROOT and, only when it differs
# (SAME_REPO=0), once more for COORD_ROOT — the two repos Kaizero ever commits into.
write_prepare_commit_msg_hook() {
    local gitdir hook; gitdir="$(cd "$1" && cd "$(git rev-parse --git-dir)" && pwd)"
    hook="$gitdir/hooks/prepare-commit-msg"
    cat >"$hook" <<'HOOK_EOF'
#!/usr/bin/env bash
[ -n "${KAIZERO_NO_CO_AUTHORSHIP:-}" ] && exit 0
msg_file="$1"
grep -qF 'Co-authored-by: Kaizero <noreply@kaizero.sh>' "$msg_file" 2>/dev/null && exit 0
printf '\nCo-authored-by: Kaizero <noreply@kaizero.sh>\n' >> "$msg_file"
HOOK_EOF
    chmod +x "$hook"
}

# BUG 058k: write .git/terminator.sh, the ONE shutdown sequence on_term/on_hup/arm_watchdog (below,
# this file) and term_owner (compact-exit-hook.sh) all invoke instead of each hand-rolling their own
# TERM/KILL escalation on the wrapper's own recorded pid. Usage:
#   terminator.sh RECORD_FILE WANT_EPOCH EXIT_REASON_FILE [TERM_CODE] [KILL_CODE]
# RECORD_FILE/WANT_EPOCH identify the target session (BUG 057's record: pid, proc_start, epoch —
# the pid field names the pty wrapper, never claude itself, same as everywhere else this record is
# read). Validates synchronously and returns fast either way: nothing to target prints one status
# line straight to stdout and exits; a live target forks the rest (snapshot, TERM, poll, recheck,
# KILL, sweep, wrapper reap) into its own background job and returns immediately, so no caller ever
# blocks on the grace period. TERM_CODE/KILL_CODE, when given, are the EXIT_REASON_FILE's line-1
# numeric code to record for "TERM sufficed" / "had to escalate to KILL" — on_term/on_hup pass
# neither (they own no exit-reason record, see kaizero.sh's post-wait fallback) and the file's
# first line stays blank for them, still followed by the same status message lines every other
# caller gets.
write_terminator_sh() {
    local gitdir; gitdir="$(cd "$(git rev-parse --git-dir)" && pwd)"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -u\n'   # no -e: every step below already checks its own failure explicitly
        printf 'WATCHDOG_GRACE=%s\n' "$WATCHDOG_GRACE"
        cat <<'TERMINATOR_EOF'
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | awk '{$1=$1;print}'; }
# $1=record path $2=want_epoch. Same three-way (pid/proc_start/epoch) check every other copy in
# this codebase makes; echoes the record's own pid (the wrapper) on success.
session_record_check() {
  local f=$1 want_epoch=$2 pid st epoch
  { IFS= read -r pid; IFS= read -r st; IFS= read -r epoch; } < "$f" 2>/dev/null || return 1
  [ -n "$pid" ] && [ -n "$st" ] && [ -n "$epoch" ] || return 1
  [ "$epoch" = "$want_epoch" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ "$(proc_start "$pid")" = "$st" ] || return 1
  printf '%s\n' "$pid"
}
# just the epoch field, whether or not the rest still validates — lets the wait loop tell "this
# record now names a DIFFERENT (later) launch" (a restart raced us, leave it alone) apart from
# "this record is simply gone/dead now" (our own claude already exited, safe to finish the sweep).
record_epoch() {
  local f=$1 pid st epoch
  { IFS= read -r pid; IFS= read -r st; IFS= read -r epoch; } < "$f" 2>/dev/null || return 1
  [ -n "$epoch" ] || return 1
  printf '%s' "$epoch"
}
kill_tree() {
    local sig=$1 pid=$2 child
    kill "-$sig" "$pid" 2>/dev/null || true
    for child in $(ps -Ao pid=,ppid= 2>/dev/null | awk -v p="$pid" '$2==p{print $1}'); do
        kill_tree "$sig" "$child"
    done
}
# never signals $2 itself — see kaizero.sh's own copy of this function for why (signaling the
# wrapper directly can tear its pty down under a still-running claude).
kill_tree_descendants() {
    local sig=$1 pid=$2 child
    for child in $(ps -Ao pid=,ppid= 2>/dev/null | awk -v p="$pid" '$2==p{print $1}'); do
        kill_tree "$sig" "$child"
    done
}
descendant_snapshot() {
  local pid=$1 child
  for child in $(ps -Ao pid=,ppid= 2>/dev/null | awk -v p="$pid" '$2==p{print $1}'); do
    descendant_snapshot "$child"
    printf '%s %s\n' "$child" "$(proc_start "$child")"
  done
}
kill_snapshot() {
  local sig=$1 pid st
  while IFS=' ' read -r pid st; do
    [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null && [ "$(proc_start "$pid")" = "$st" ]; then
      kill "-$sig" "$pid" 2>/dev/null || true
    fi
  done <<<"$2"
}

RECORD_FILE="${1:-}"; WANT_EPOCH="${2:-}"; EXIT_REASON_FILE="${3:-}"
TERM_CODE="${4:-}"; KILL_CODE="${5:-}"

if [ -z "$RECORD_FILE" ] || [ ! -s "$RECORD_FILE" ] || ! WRAPPER_PID="$(session_record_check "$RECORD_FILE" "$WANT_EPOCH")"; then
  printf 'terminator: nothing to target — no session record to signal\n'
  exit 0
fi

# from here on, everything runs in the caller's own foreground UNTIL the fork below — this whole
# preamble is deliberately fast (one file read, no sleeps), so a caller invoking us in the
# foreground never blocks past this point.
{
  CODE=""
  STATUS_LINES=()
  SEQUENCE_DONE=0
  write_reason_file() {
    [ -n "$EXIT_REASON_FILE" ] || return 0
    { if [ -n "$CODE" ]; then printf '%s\n' "$CODE"; else printf '\n'; fi
      local l; for l in "${STATUS_LINES[@]:-}"; do [ -n "$l" ] && printf '%s\n' "$l"; done
    } > "$EXIT_REASON_FILE" 2>/dev/null || true
  }
  append_status() { STATUS_LINES+=("$1"); write_reason_file; }
  # EXIT trap first, before any other step: guarantees SOME final write records this sequence
  # having run even if a step partway through dies unexpectedly — never itself attempts any
  # further TERM/KILL, only records the outcome.
  # shellcheck disable=SC2317,SC2329   # only ever reached via `trap ... EXIT`, not a direct call
  on_terminator_exit() {
    [ "$SEQUENCE_DONE" = 1 ] || { STATUS_LINES+=("sequence aborted early"); write_reason_file; }
  }
  trap on_terminator_exit EXIT

  [ -n "$TERM_CODE" ] && CODE="$TERM_CODE"
  # pre-TERM snapshot: a descendant that outlives claude's own TERM-honored exit gets reparented
  # away from it before any later re-walk from claude's own (by then dead) pid could find it again.
  SNAP="$(descendant_snapshot "$WRAPPER_PID")"
  # write CODE/"TERM sent" BEFORE sending the signal, not after: kill_tree_descendants's own
  # recursive ps/awk descendant walk costs real time, and a target that dies instantly from this
  # TERM can take the wrapper down with it before that walk returns — an external observer polling
  # the wrapper's liveness can then see it dead before this file write ever runs. Sending the
  # signal is what can kill the wrapper, so the file must already hold its value beforehand for the
  # TERM-sufficed case to honor the same guarantee the final KILL step already does.
  append_status "TERM sent"
  kill_tree_descendants TERM "$WRAPPER_PID"

  BAILED=0
  LEFT=$WATCHDOG_GRACE
  while [ "$LEFT" -gt 0 ]; do
    CUR_EPOCH="$(record_epoch "$RECORD_FILE" 2>/dev/null || true)"
    if [ -n "$CUR_EPOCH" ] && [ "$CUR_EPOCH" != "$WANT_EPOCH" ]; then
      append_status "session record superseded mid-wait — leaving alone"
      BAILED=1
      break
    fi
    # early-out the instant the wrapper is confirmed gone, rather than always sleeping out the
    # full grace period — a TERM-obedient claude (and, via the pty, its wrapper) that dies well
    # inside the window must not cost the caller the rest of it; the post-loop recheck below still
    # runs unconditionally (not skipped by this early exit) to do the KILL-vs-no-KILL decision.
    session_record_check "$RECORD_FILE" "$WANT_EPOCH" >/dev/null 2>&1 || break
    sleep 1
    LEFT=$((LEFT - 1))
  done

  if [ "$BAILED" != 1 ]; then
    CUR_EPOCH="$(record_epoch "$RECORD_FILE" 2>/dev/null || true)"
    if [ -n "$CUR_EPOCH" ] && [ "$CUR_EPOCH" != "$WANT_EPOCH" ]; then
      append_status "session record superseded — leaving alone"
      BAILED=1
    fi
  fi

  if [ "$BAILED" != 1 ]; then
    if RECHECK_PID="$(session_record_check "$RECORD_FILE" "$WANT_EPOCH" 2>/dev/null)"; then
      [ -n "$KILL_CODE" ] && CODE="$KILL_CODE"
      # write CODE/"KILL escalated" BEFORE sending the signal, not after — same race as the
      # earlier TERM-sent write (BUG 058k): kill_tree_descendants's own recursive ps/awk
      # descendant walk costs real time, and BSD `script` exits on its own the instant its pty
      # child dies, which can unblock kaizero.sh's own `wait "$CLAUDE_WRAPPER_PID"` before
      # this write would otherwise have landed, reading the stale TERM_CODE instead of the KILL
      # escalation.
      append_status "KILL escalated"
      kill_tree_descendants KILL "$RECHECK_PID"
    else
      append_status "claude already exited"
    fi
    [ -n "$SNAP" ] && kill_snapshot KILL "$SNAP"
    # the file must be fully written BEFORE the wrapper is killed, never after: killing the
    # wrapper is what unblocks kaizero.sh's own `wait "$CLAUDE_WRAPPER_PID"`, so this order
    # guarantees the file already holds its final value the instant that wait returns.
    append_status "wrapper reaped"
    # final action of the whole sequence, and the only step allowed to touch the wrapper's own
    # pid: KILL, never TERM — KILL cannot be ignored, so the wrapper still reliably dies even if
    # an external TERM aimed at kaizero.sh's whole process group left it alive on purpose.
    kill -9 "$WRAPPER_PID" 2>/dev/null || true
  fi
  SEQUENCE_DONE=1
} &
exit 0
TERMINATOR_EOF
    } > "$gitdir/terminator.sh"
    chmod +x "$gitdir/terminator.sh"
}

# write .git/zero.sh (the per-Task acquire/release/merge helper the zero prompt calls) with
# COORD_BASE baked in, then echo the parallel zero prompt on stdout. $1 = TODO path (repo-relative).
# writes the zero.sh helper both build_zero_prompt and build_mr_prompt emit — one helper, shared,
# so the two prompts can never drift into two copies of the 1150-line body; only the prompt
# heredocs are duplicated. The four MR-mode values it bakes (MR_MODE/FORGE/TB/ORIGIN_URL) come from
# globals main() already set differently per mode before calling, so no branch is needed here.
write_zero_sh() {
    local todo="$1"
    # absolute: the agent's cwd is the target's main checkout, never necessarily this coordination
    # root, so a relative git-dir would not resolve there — @@ZERO_SH@@ below needs the real path.
    local gitdir; gitdir="$(cd "$(git rev-parse --git-dir)" && pwd)"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        printf 'COORD_BASE=%q\n' "$COORD_BASE"
        printf 'TODO_PATH=%q\n' "$todo"
        # baked for the 038 family — this slice computes and proves these values, and every one of
        # them is already read below by the emitted script's own body.
        printf 'COORD_ROOT=%q\n' "$COORD_ROOT"
        printf 'TARGET_ROOT=%q\n' "$TARGET_ROOT"
        printf 'TARGET_BASE=%q\n' "$TARGET_BASE"
        printf 'SAME_REPO=%q\n' "$SAME_REPO"
        printf 'WT_PARENT=%q\n' "$WT_PARENT"
        printf 'TB=%q\n' "$TB"
        printf 'TODO_ABS=%q\n' "$COORD_ROOT/$todo"
        # the coordination git dir, baked here rather than derived at run time by the
        # emitted script: an inherited GIT_DIR/GIT_COMMON_DIR outranks both cwd and -C, so a
        # run-time `git rev-parse --git-common-dir` answers for whichever repository the CALLER's
        # environment names, not necessarily $COORD_ROOT. $gitdir above already names this same
        # directory (COORD_ROOT is the main worktree, so --git-dir and --git-common-dir agree).
        printf 'COORD_GITDIR=%q\n' "$gitdir"
        # the locking tool, resolved off THIS process's PATH (already proved present and runnable
        # by run_doctor) rather than re-discovered by the emitted script off whatever PATH the
        # agent's Bash tool happens to have.
        local flock_bin; flock_bin="$(command -v flock)" || flock_bin=flock
        printf '# shellcheck disable=SC2034\nFLOCK_BIN=%q\n' "$flock_bin"
        # MR mode's four values. Baked in both modes: empty FORGE/ORIGIN_URL in local-merge
        # mode, so the emission stays one shape.
        printf '# shellcheck disable=SC2034\nMR_MODE=%q\n' "$MR_MODE"
        printf '# shellcheck disable=SC2034\nFORGE=%q\n' "${FORGE:-}"
        printf '# shellcheck disable=SC2034\nORIGIN_URL=%q\n' "${ORIGIN_URL:-}"
        cat <<'ZERO_EOF'
# neither the caller's cwd nor an inherited git environment variable may pick the repository a
# git call below answers for — GIT_DIR/GIT_COMMON_DIR outrank both cwd and -C — so they are
# cleared before the first git call; -C "$COORD_ROOT"/"$TARGET_ROOT" is what decides it.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
MERGE_LOCK="$COORD_GITDIR/merge.lock"
# worktree add/remove/repair all rewrite the shared .git/config + .git/worktrees; git does not
# serialize that, so concurrent instances race on .git/config.lock ("File exists"). Held briefly
# around each worktree mutation. Nested inside MERGE_LOCK during merge cleanup — order is always
# MERGE_LOCK then WT_LOCK (acquire/release take WT_LOCK alone), so no lock-ordering cycle.
WT_LOCK="$COORD_GITDIR/worktree.lock"
# best-effort worktree removal under WT_LOCK. Never aborts its caller (the caller decides whether
# a failed removal matters), but never discards the wrapped command's status silently either — a
# failure is reported to stderr instead of vanishing behind a blanket `|| true`. $3 labels the
# message (e.g. "merge $raw"); return status is the removal's own, for callers that do care.
remove_worktree() {
  local root=$1 path=$2 label=$3 rc=0
  "$FLOCK_BIN" "$WT_LOCK" git -C "$root" worktree remove --force "$path" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || echo "$label: worktree removal of $path in $root failed (rc=$rc) — remove it by hand" >&2
  return "$rc"
}
# this invocation's instance = the kaizero.sh that launched the claude above it, via env.
# 'shared' fallback if unset (should not happen under kaizero.sh).
INSTANCE_ID="${KAIZERO_INSTANCE:-shared}"
# per-instance aggregate path: seconds of Task ownership credited to instance $1. Namespaced by base
# slug (like branches/worktrees/reclaim-locks) AND instance id, so peers keep separate, comparable totals.
todos_file() { printf '%s/todos-seconds-%s-%s' "$COORD_GITDIR" "${COORD_BASE//\//-}" "$1"; }
# same namespacing for the count of todos instance $1 landed on the base branch.
todos_done_file() { printf '%s/todos-done-%s-%s' "$COORD_GITDIR" "${COORD_BASE//\//-}" "$1"; }

# stat mtime-epoch flavor, probed once: GNU/Linux `-c %Y` vs BSD/macOS `-f %m`. GNU first: GNU's
# own -f means filesystem-status and succeeds regardless of the bogus %m, so a BSD-first probe
# always "succeeds" and picks the wrong flavor on Linux.
if stat -c %Y . >/dev/null 2>&1; then STAT_MTIME=(stat -c %Y); else STAT_MTIME=(stat -f %m); fi
# newest file mtime (epoch) under $1, excluding .git; empty if no files. Estimates a dead session's
# mid-Task work: acquire epoch to last file touched, so the crash-to-steal idle gap isn't counted.
newest_mtime() {
  # exclude .owner: it's Kaizero's bookkeeping (rewritten by claim / credit_inflight_time to "now"),
  # not agent work — counting it would inflate the estimate and break idempotency after the anchor advance.
  find "$1" -type f -not -path '*/.git/*' -not -name .owner -print0 2>/dev/null \
    | xargs -0 "${STAT_MTIME[@]}" 2>/dev/null | sort -rn | head -1
}
# add $1 seconds (positive int) to instance $2's todos aggregate, under a per-instance lock (fd 8 —
# fd 9 is acquire's). Credit goes to the instance that WORKED the span, not necessarily the caller
# (a stealer credits the crashed owner). Silently ignores non-numeric / non-positive / no-instance.
add_todos_time() {
  local add=${1:-0} inst=${2:-}
  case "$add" in ''|*[!0-9]*) return 0;; esac; [ "$add" -gt 0 ] || return 0
  [ -n "$inst" ] || inst=shared
  add_counter "$add" "$(todos_file "$inst")"
}
# +1 to instance $1's zeroed-Task count — Tasks Landed on a --local-merge run, Tasks handed off
# on an MR one (the report labels it by route, see tasks_label) — from the same rc=0 point that
# credits its time, so the count and the time credit can never disagree about who did the work.
add_todos_done() {
  local inst=${1:-}
  [ -n "$inst" ] || inst=shared
  add_counter 1 "$(todos_done_file "$inst")"
}
# Path of THIS process's own safe-to-exit marker — keyed by $INSTANCE_ID, the CURRENT
# instance, never the (possibly different, possibly dead) owner add_todos_time/add_todos_done
# credit: this file answers "may the live claude session running RIGHT NOW end its turn", not
# "who gets credit for the work". Same file the Stop hook reads via KAIZERO_SAFE_TO_EXIT.
safe_to_exit_file() { printf '%s/safe-to-exit-%s-%s' "$COORD_GITDIR" "${COORD_BASE//\//-}" "$INSTANCE_ID"; }
# touch it: called from every path here that reaches a definitive "OK to end this session"
# outcome for the CURRENT instance — a landed task or a confirmed-empty board.
mark_safe_to_exit() { printf '1\n' > "$(safe_to_exit_file)"; }
# add $1 (positive int) to counter file $2, under a per-file lock.
add_counter() {
  local add=$1 f=$2 cur=0
  exec 8>"$f.lock"; "$FLOCK_BIN" 8
  [ -f "$f" ] && { read -r cur < "$f" 2>/dev/null || cur=0; }
  case "$cur" in ''|*[!0-9]*) cur=0;; esac
  # atomic publish (temp + rename): the report reads this file WITHOUT the lock, so a plain
  # truncate-write would expose an empty file mid-write. rename is atomic — readers see old or new.
  printf '%s\n' "$((cur + add))" > "$f.tmp" && mv -f "$f.tmp" "$f"
  exec 8>&-   # close fd, release lock
}

# --- forge (MR mode) -----------------------------------------------------------------------
# mr_list/mr_create are the ONLY two forge calls in this script (plus the doctor's own `auth
# status` probe in kaizero.sh, and the park loop's mid-run re-check of it) — mr_task and sync_mrs's
# sync_mrs are their sole callers. Both name the repository explicitly, via `--repo "$ORIGIN_URL"`,
# rather than letting the CLI infer it from cwd's own remotes (gh ranks `upstream` above `origin`)
# — so the caller's cwd, whatever it is, can never make either call pick the wrong repository
#. The doctor's own flag/field-surface check (`assert_forge_flags`) is a kaizero.sh-only
# concern — this heredoc is inert text from kaizero.sh's own point of view, so a function
# placed here is never in scope for its `run_doctor`, and the emitted `.git/zero.sh` this heredoc
# becomes has no doctor of its own to call it from; that check lives once, outside this heredoc,
# beside `run_doctor`.

# reshapes either CLI's request-list JSON into one normalized TSV row per line: number, sha,
# base, state, url. $numf/$shaf/$basef/$statef/$urlf bind the field names each CLI's JSON uses
# for those five columns. `n` is kept numeric for the sort and only stringified at the end, so a
# GitLab `iid` (already numeric) and a GitHub `number` sort identically. GitLab's `opened` and
# `locked` states fold into `open`; GitHub's `open`/`closed`/`merged` pass through unchanged —
# the same fold, applied uniformly, is a no-op for values it was never meant to touch.
MR_LIST_JQ='
  [ .[] | {
      n: (.[$numf] | (tonumber? // .)),
      s: .[$shaf], b: .[$basef],
      st: ((.[$statef] | ascii_downcase) as $x | if ($x == "opened" or $x == "locked") then "open" else $x end),
      u: .[$urlf]
    } ]
  | sort_by(.n)
  | .[] | [(.n | tostring), .s, .b, .st, .u] | @tsv
'

# mr_list <branch> -> normalized TSV rows (see MR_LIST_JQ), one per request, always for one head,
# asking both CLIs for EVERY state (a default-open-only list would strand sync_mrs silently)
# and capping at 100 — GitLab's own per-page ceiling, far past any real head — newest-first where
# the CLI offers an order (glab's `--order`/`--sort`; gh has none, and its API already defaults to
# newest-first). Returns the CLI's own exit status, captured before anything reaches jq: this
# script sets no pipefail, so a `cmd | jq` pipeline would hand back jq's status instead and a
# forge failure would print nothing and read as "this head has no requests". A failing call's own
# stderr is forwarded unchanged — an exit number alone names no cause. `GH_REPO`/`GITLAB_REPO`/
# `GH_HOST` are unset for the call: those compete with the `--repo` argument for which project the
# CLI queries, and are the only inherited forge levers this script is exposed to (any forge call
# added later extends this same sweep). Every flag here is pinned by .github/smoke.sh check 18
# against the installed CLIs' own --help/--json output, and by run_doctor's own check 5
# (assert_forge_flag) at --doctor/launch time — two independent, by-hand-synced copies of the same
# forge contract, no shared file between them.
mr_list() {
  local branch="$1" out rc errf
  errf="$(mktemp)"
  case "$FORGE" in
    gh)
      if out="$(unset GH_REPO GITLAB_REPO GH_HOST; GH_PAGER="cat" gh pr list --repo "$ORIGIN_URL" \
        --head "$branch" --state all --limit 100 \
        --json number,headRefOid,baseRefName,state,url </dev/null 2>"$errf")"; then rc=0; else rc=$?; fi
      [ "$rc" -eq 0 ] || { [ -s "$errf" ] && cat "$errf" >&2; rm -f "$errf"; return "$rc"; }
      rm -f "$errf"
      printf '%s' "$out" | jq -r --arg numf number --arg shaf headRefOid --arg basef baseRefName \
        --arg statef state --arg urlf url "$MR_LIST_JQ"
      ;;
    glab)
      if out="$(unset GH_REPO GITLAB_REPO GH_HOST; GLAB_PAGER="cat" glab mr list --repo "$ORIGIN_URL" \
        --source-branch "$branch" --all --output json --per-page 100 --order created_at --sort desc \
        </dev/null 2>"$errf")"; then rc=0; else rc=$?; fi
      [ "$rc" -eq 0 ] || { [ -s "$errf" ] && cat "$errf" >&2; rm -f "$errf"; return "$rc"; }
      rm -f "$errf"
      printf '%s' "$out" | jq -r --arg numf iid --arg shaf sha --arg basef target_branch \
        --arg statef state --arg urlf web_url "$MR_LIST_JQ"
      ;;
    *)
      rm -f "$errf"
      echo "mr_list: unsupported \$FORGE '$FORGE' — this function only implements gh and glab" >&2
      return 2
      ;;
  esac
}

# mr_create <branch> <title> <body-file> -> opens the request against $TARGET_BASE from that
# head, prints the new request's URL and nothing else. `gh pr create` prints the URL alone;
# `glab mr create` prints a summary, so the output is filtered to its last `^https?://` line
# either way. Both title and body are given explicitly, so neither CLI's editor/title/body
# prompt ever fires; `glab`'s remaining submission-confirmation prompt is closed with `--yes`.
# `gh` takes the body as a file; `glab` dropped its own `--description-file` (gone by 1.114), so
# the body goes in as text — and a body that is exactly `-` is rewritten, since glab reads that
# one value as "open an editor", which would hang the session to the watchdog.
# The CLI's exit status is captured before the URL-line filter, and a call that exits 0 but prints
# no such line refuses too — non-zero, with the CLI's own output (stdout+stderr) on stderr, since
# a create whose URL cannot be read is not a create anyone can record. `GH_REPO`/`GITLAB_REPO`/
# `GH_HOST` are unset for the call, same sweep as `mr_list`.
mr_create() {
  local branch="$1" title="$2" bodyfile="$3" out rc url
  case "$FORGE" in
    gh)
      if out="$(unset GH_REPO GITLAB_REPO GH_HOST; GH_PAGER="cat" gh pr create --repo "$ORIGIN_URL" \
        --head "$branch" --base "$TARGET_BASE" --title "$title" --body-file "$bodyfile" \
        </dev/null 2>&1)"; then rc=0; else rc=$?; fi
      ;;
    glab)
      local body; body="$(cat "$bodyfile")"; [ "$body" = - ] && body='\-'
      if out="$(unset GH_REPO GITLAB_REPO GH_HOST; GLAB_PAGER="cat" glab mr create --repo "$ORIGIN_URL" \
        --source-branch "$branch" --target-branch "$TARGET_BASE" --title "$title" \
        --description "$body" --yes </dev/null 2>&1)"; then rc=0; else rc=$?; fi
      ;;
    *)
      echo "mr_create: unsupported \$FORGE '$FORGE' — this function only implements gh and glab" >&2
      return 2
      ;;
  esac
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; return "$rc"; }
  url="$(printf '%s\n' "$out" | grep -E '^https?://' | tail -1)"
  if [ -z "$url" ]; then printf '%s\n' "$out" >&2; return 1; fi
  printf '%s\n' "$url"
}
# --- end forge ---------------------------------------------------------------------------------

# --- sync-mrs — reads back what reviewers did on open [↑] handoffs -----------------------------

# raw ids on $COORD_BASE's committed Release Todo List whose box holds exactly symbol $1 (space included, for
# "unclaimed") — same fenced, box-aware scan as box_symbol_on_base, filtering instead of matching.
ids_with_box() {
  git -C "$COORD_ROOT" show "$COORD_BASE:$TODO_PATH" 2>/dev/null | awk -v want="$1" '
    function unwraplink(s) {
      if (s ~ /^\[[^]]+\]\([^)]+\)$/) { sub(/^\[/, "", s); sub(/\]\(.*$/, "", s) }
      return s
    }
    /^[ \t]*```/ { fence = !fence; next }
    fence        { next }
    /^[ \t]*- \[[^]]+\]/ {
      line = $0
      sub(/^[ \t]*- \[/, "", line)
      match(line, /^[^]]+\]/)
      box  = substr(line, 1, RLENGTH - 1)
      line = substr(line, RLENGTH + 1); sub(/^[ \t]*/, "", line)
      split(line, a, /[ \t]/)
      if (box == want) print unwraplink(a[1])
    }'
}

# mr_pick <TSV rows on stdin, from mr_list> -> the one row this reader and mr_task step 5 agree
# on: the newest (highest-numbered) open request wins outright when one exists, else the
# highest-numbered request of any state. Empty in, empty out.
mr_pick() {
  awk -F'\t' '
    { if ($4 == "open" && ($1 + 0 > omax || !ofound)) { omax = $1 + 0; oline = $0; ofound = 1 }
      if ($1 + 0 > amax || !afound) { amax = $1 + 0; aline = $0; afound = 1 } }
    END { if (ofound) print oline; else if (afound) print aline }
  '
}

# a description file whose id's box is no longer " " (unclaimed) belongs to a landed Task and is
# swept here, every pass, ungated on anything else — the GC for a session killed between its box
# commit and its own mr-body cleanup (039g step 8). Walked forward, id -> path via mr_body_path
# (never path -> id): sanitize_id is lossy for an id containing '/', and a textual strip of the
# "$COORD_GITDIR/mr-body-$BR_SLUG-" prefix from a directory listing would also match a peer
# fleet's file whenever this fleet's BR_SLUG is itself a prefix of the peer's. Iterating every raw
# id this fleet's own todo currently carries and re-deriving each one's exact path sidesteps both:
# an id the todo no longer carries is never visited, so its body — belonging to a Task removed
# from the todo entirely — is left alone, exactly as a Task on a peer's own base is.
sweep_mr_bodies() {
  local raw f sym
  while IFS=$'\t' read -r raw _; do
    [ -n "$raw" ] || continue
    f=$(mr_body_path "$raw")
    [ -e "$f" ] || continue
    sym=$(box_symbol_on_base "$raw") || sym=""
    [ "$sym" = " " ] || rm -f "$f"
  done < <(todo_lines)
}

# sync-mrs: turns what reviewers did on every open [↑] handoff into a box — [x] merged into
# $TARGET_BASE, [⛔] declined, [?] every case the sync cannot answer, [↑] left alone while still
# open. Called at the top of every loop pass (after validate-ids, before
# all_todos_done) and by hand. MR_MODE=0 refuses outright: a local-merge run resolves no forge.
sync_mrs() {
  local id branches n branch rows rc winner sha_field base_field state_field url_field
  local pending="" reason cur sym kind url branch2 base sha localsha delerr twt
  local merged_target open_url coerr

  [ "$MR_MODE" = 1 ] || return 1

  sweep_mr_bodies

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    branches=$(target_branches_for_id "$id")
    n=$(printf '%s\n' "$branches" | grep -c . || :)   # `grep -c` exits 1 on zero matches — this
    # function dispatches with errexit live, so an unguarded `n=$(…)` here would abort the whole
    # pass on the ordinary "no branch" answer instead of reaching the `[?]` verdict below
    if [ "$n" -eq 0 ]; then
      pending="${pending}${id}"$'\x1f?\x1fno-branch\n'
      continue
    fi
    if [ "$n" -ge 2 ]; then
      pending="${pending}${id}"$'\x1f?\x1ftwo-branch\n'
      continue
    fi
    branch="$branches"
    if ! rows=$(mr_list "$branch"); then
      rc=$?
      echo "sync $id: forge list failed for $branch (exit $rc) — boxes left alone this pass" >&2
      continue
    fi
    if [ -z "$rows" ]; then
      pending="${pending}${id}"$'\x1f?\x1fno-request\x1f\x1f'"${branch}"$'\n'
      continue
    fi
    winner=$(printf '%s\n' "$rows" | mr_pick)
    # $winner is real tab-delimited TSV off mr_list/mr_pick (039d) — bash `read` treats tab as
    # "IFS whitespace" and collapses a run of them no matter what IFS is set to, so a blank
    # column (an empty url, say) would silently shift every field after it. Recoding the row's
    # tabs to \x1f (never IFS whitespace) before the read sidesteps that; the wire format
    # mr_list/mr_pick emit, and everything outside this function that reads it, is untouched.
    IFS=$'\x1f' read -r _ sha_field base_field state_field url_field <<< "${winner//$'\t'/$'\x1f'}"
    open_url=""
    # the one test the shared pick does not make, and it is the sync's alone: a head carrying
    # both a request merged into $TARGET_BASE and a still-open one resolves to the merge — a
    # landing is terminal, and a box that still says "in review" over work already in the base
    # parks the fleet on it forever. `mr_task` keeps reusing `mr_pick`'s own open-wins verdict for
    # the head, since opening a second request there is the worse error.
    if [ "$state_field" = open ]; then
      merged_target=$(printf '%s\n' "$rows" | awk -F'\t' -v b="$TARGET_BASE" '$3==b && $4=="merged" && ($1+0>max || !found){max=$1+0; line=$0; found=1} END{if(found) print line}')
      if [ -n "$merged_target" ]; then
        open_url="$url_field"
        winner="$merged_target"
        IFS=$'\x1f' read -r _ sha_field base_field state_field url_field <<< "${winner//$'\t'/$'\x1f'}"
      fi
    fi
    case "$state_field" in
      open)
        if [ "$base_field" != "$TARGET_BASE" ]; then
          echo "sync $id: request now targets $base_field, not $TARGET_BASE · still open, box left [↑]"
        fi
        ;;
      closed)
        pending="${pending}${id}"$'\x1f⛔\x1fdeclined\x1f'"${url_field}"$'\x1f'"${branch}"$'\n'
        ;;
      merged)
        if [ "$base_field" = "$TARGET_BASE" ]; then
          pending="${pending}${id}"$'\x1fx\x1fmerged\x1f'"${url_field}"$'\x1f'"${branch}"$'\x1f'"${base_field}"$'\x1f'"${sha_field}"$'\x1f'"${open_url}"$'\n'
        else
          pending="${pending}${id}"$'\x1f?\x1fmerged-elsewhere\x1f'"${url_field}"$'\x1f'"${branch}"$'\x1f'"${base_field}"$'\n'
        fi
        ;;
    esac
  done < <(ids_with_box '↑')

  [ -n "$pending" ] || return 0

  exec 10>"$MERGE_LOCK"; "$FLOCK_BIN" 10
  reason=$(quiet_checkout "$COORD_ROOT" todo "$TODO_PATH") || true   # `quiet_checkout` returns
  # 1 on its every refusal — errexit is live here, so an unguarded assignment would abort the
  # pass before the custom "boxes left alone" message below is ever reached
  if [ -n "$reason" ]; then
    exec 10>&-
    echo "sync: $reason, boxes left alone" >&2
    return 1
  fi
  mark_inflight "$COORD_ROOT"
  if ! coerr=$(git -C "$COORD_ROOT" checkout -q "$COORD_BASE" 2>&1); then
    clear_inflight
    exec 10>&-
    echo "sync: could not switch $COORD_ROOT to $COORD_BASE — $coerr, boxes left alone" >&2
    return 1
  fi

  while IFS=$'\x1f' read -r id sym kind url branch2 base sha open_url; do
    [ -n "$id" ] || continue
    cur=$(box_symbol_on_base "$id") || cur=""
    [ "$cur" = "↑" ] || continue
    tick_box "$id" "$sym" retick >/dev/null

    case "$kind" in
      no-branch)
        echo "sync $id: no local branch for the id → [?] — restore it, or set the box yourself" ;;
      two-branch)
        echo "sync $id: two local branches for the id → [?] — delete or rename one, then retry" ;;
      no-request)
        echo "sync $id: no request for branch $branch2 → [?] — open one by hand, or clear the box and let the next hand off open it" ;;
      declined)
        echo "sync $id: declined → [⛔] ($url) · branch $branch2 kept" ;;
      merged-elsewhere)
        echo "sync $id: merged into $base, not $TARGET_BASE → [?] ($url) · branch $branch2 kept — merge that ref into $TARGET_BASE, or set the box yourself" ;;
      merged)
        localsha=$(git -C "$TARGET_ROOT" rev-parse -q "$branch2" 2>/dev/null || true)
        if [ -n "$localsha" ] && [ "$localsha" = "$sha" ]; then
          # mr_task's own success path already tears the target worktree down at Hand off, so this
          # ordinarily finds none — but a `take` since then can have recreated one ($WT_PARENT/tt-…,
          # the same shape acquire_target adopts), and once the request is merged that worktree has
          # nothing left to do; `branch -D` below would otherwise fail on "used by worktree" and
          # leak it forever. Only Kaizero's own target worktrees are torn down here: a worktree
          # an operator or reviewer made themselves is left standing, and `branch -D` then fails on
          # it exactly as it always did, warning and keeping the branch — `remove --force` there
          # would discard someone's uncommitted work.
          twt=$(wt_for_branch_in "$TARGET_ROOT" "$branch2" 2>/dev/null || true)
          case "$twt" in
            "$WT_PARENT"/tt-*) remove_worktree "$TARGET_ROOT" "$twt" "acquire" || true ;;
          esac
          if delerr=$("$FLOCK_BIN" "$WT_LOCK" git -C "$TARGET_ROOT" branch -D "$branch2" 2>&1); then
            echo "sync $id: merged → [x] ($url) · branch $branch2 deleted"
          else
            echo "sync $id: could not delete branch $branch2 — $delerr" >&2
            echo "sync $id: merged → [x] ($url) · branch $branch2 kept"
          fi
        else
          echo "sync $id: merged → [x] ($url) · branch $branch2 kept — local ${localsha:-<none>} vs request $sha"
        fi
        [ -z "$open_url" ] || echo "sync $id: request $open_url is still open — close it by hand"
        ;;
    esac
  done <<< "$pending"

  clear_inflight
  exec 10>&-
}
# --- end sync-mrs --------------------------------------------------------------------------------

# Task branch is prefixed with the base branch so agent groups zeroing the SAME repo off DIFFERENT
# bases never collide on branch/worktree names. Slashes in the base (feature/x) are legal in a
# branch ref but not in a dir name, so sanitize for the wt.
BR_SLUG="${COORD_BASE//\//-}"
task_branch() { printf '%s-task-%s' "$COORD_BASE" "$1"; }

# BUG 057: owner = the pid named by KAIZERO_SESSION_RECORD, the record kaizero.sh wrote right
# after launching this instance's claude session — validated pid+proc_start+launch-epoch, exactly
# like the hook's own copy of this check (see its comment; the two must read the same three lines
# the same way). Never a command-name walk, never CLAUDE_PID: neither is evidence this run owns a
# process, and a nested Task agent's zero.sh — several real 'claude' ancestors above it — is exactly
# where the old walk had to guess. The record removes the guess: it names the session that owns
# THIS task, not merely the nearest ancestor with the right name.
find_owner() {
  local f="${KAIZERO_SESSION_RECORD:-}" pid st epoch
  [ -n "$f" ] || return 1
  { IFS= read -r pid; IFS= read -r st; IFS= read -r epoch; } < "$f" 2>/dev/null || return 1
  [ -n "$pid" ] && [ -n "$st" ] && [ -n "$epoch" ] || return 1
  [ "$epoch" = "${KAIZERO_SESSION_EPOCH:-}" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ "$(proc_start "$pid")" = "$st" ] || return 1
  echo "$pid"
}
# process start-time (via ps): pins identity so a RECYCLED pid isn't mistaken for the same session.
# `ps -o lstart=` pads with spaces; awk '{$1=$1}' trims+collapses so the value stored via $() and
# the value read back via `read` (which trims) compare equal. Empty only if dead.
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | awk '{$1=$1;print}'; }
# resolve the owning claude session into OWNER_PID/OWN_START. Only the lease ops (acquire/merge/
# release, via claim_owner/set_current) need it, and they run UNDER claude. done/credit_inflight_time
# run from kaizero.sh itself (no claude ancestor), so it's called per-subcommand below, never eagerly.
# Exit 7 is dedicated to this refusal (TASK-050 moved it off claim's own exit 3 for the ancestor-walk
# FATAL this replaces) — no claim path produces it, so a caller can tell "no owner record" from
# "contested claim" by code alone.
ensure_owner() {
  OWNER_PID=$(find_owner) || { echo "FATAL: no valid session record at KAIZERO_SESSION_RECORD='${KAIZERO_SESSION_RECORD:-}' — task ownership and liveness are unsafe; abort this run." >&2; exit 7; }
  # `|| true` here, not a bare assignment: proc_start's `ps | awk` can fail (the owner exited in the
  # gap since find_owner's own liveness check), and under `set -euo pipefail` an unguarded failure
  # here would abort THIS RUN rather than refuse the claim — the exact defect this ticket's "How to
  # fix" calls out at this line. Read failing closed (empty OWN_START refuses below) instead.
  OWN_START=$(proc_start "$OWNER_PID") || true
  [ -n "$OWN_START" ] || { echo "FATAL: owner process $OWNER_PID exited before its liveness could be read — task ownership and liveness are unsafe; abort this run." >&2; exit 7; }
}

# --- ownership as a per-session LEASE, not a per-worktree pid probe -----------------------
# A claude SESSION can hold a Task, release it, and reclaim another (a merge failure, a rescued
# worktree), so "is the pid alive?" is too coarse — it says the session is up, not that it still
# holds THIS Task. Record, per
# session, the ONE Task it is currently on:
#     $COORD_GITDIR/session/<pid>   line1=<process start-time>   line2=<current Task id | none>
# zero.sh is the sole writer: set on acquire, cleared to `none` on merge/release. A Task is owned
# iff some live session marker names it (pid up + start-time match + current == id). This reclaims a
# Task from a session that DIED, whose pid was REUSED, or that MOVED ON.
SESSION_DIR="$COORD_GITDIR/session"
marker() { printf '%s/%s' "$SESSION_DIR" "$1"; }
# $1=pid $2=start. `ps`, not `kill -0`: a mixed-user fleet (sudo/non-sudo, two operators sharing a
# target) can `kill -0` a process it does not own and get EPERM back — indistinguishable from
# ESRCH by exit code alone, and either signal failure would misread a live peer as dead. `ps` reads
# any process's start time regardless of signal permission, so a start-time match alone proves
# liveness; no readable start time (the pid is gone) is the only way this reads dead.
session_alive() { local st; st=$(proc_start "$1"); [ -n "$st" ] && [ "$st" = "$2" ]; }
session_current() {                              # $1=pid → its current Task id, or 'none'
  local f cur; f=$(marker "$1"); [ -f "$f" ] || { echo none; return; }
  { read -r _; read -r cur; } < "$f" 2>/dev/null || true
  printf '%s' "${cur:-none}"
}
set_current() { mkdir -p "$SESSION_DIR"; printf '%s\n%s\n' "$OWN_START" "$1" > "$(marker "$OWNER_PID")"; }
# GC: unlink markers whose session is gone or whose pid was recycled. Cheap — piggybacks acquire's
# scan. Others reap the dead; a dead session can't clean its own file.
reap_dead_sessions() {
  [ -d "$SESSION_DIR" ] || return 0
  local f pid st
  for f in "$SESSION_DIR"/*; do
    [ -e "$f" ] || continue
    pid=${f##*/}; { read -r st; } < "$f" 2>/dev/null || st=""
    session_alive "$pid" "$st" || rm -f "$f"
  done
}

wt_for_branch() {
  git -C "$COORD_ROOT" worktree list --porcelain | awk -v b="refs/heads/$1" '
    /^worktree /{p=substr($0,10)}
    /^branch /{ if (substr($0,8)==b){print p; exit} }'
}
# same lookup against an arbitrary repository root — release_task's by-branch-prefix fallback
# needs the TARGET_ROOT registry, never the ambient (coordination) one wt_for_branch reads.
wt_for_branch_in() {
  git -C "$1" worktree list --porcelain | awk -v b="refs/heads/$2" '
    /^worktree /{p=substr($0,10)}
    /^branch /{ if (substr($0,8)==b){print p; exit} }'
}

# a worktree's claim record: line1=pid line2=start-time line3=acquire-epoch line4=instance-id
# line5=target worktree path (in the single-repository case this is the worktree's own path).
# line6=fork point (empty with one repository) — the target branch's merge-base with `TB` at
# the moment this claim attached the target worktree, recomputed on every acquire (take, reattach,
# fork or track alike) so an unmerged branch's own tip never falsely reads as merge_two_repos'
# already-on-base test 2. line3 anchors the todo-time accounting (elapsed on merge, or
# mtime-estimate on steal); line4 routes that credit to the instance that worked the span. Every
# writer of `.owner` writes all six lines — credit_inflight_time's anchor-advance rewrite included
# — so a missing/stale line5 or line6 means only an OLDER `.owner` predating that slice, never a
# live one this slice itself wrote short — so every reader of line 5 or line 6 takes its `read` as
# optional, or a four- or five-line record would read as corrupt.
# A claim whose .owner cannot be written is not a claim: the caller must check this
# return, undo whatever it created, and print no path — otherwise the exclusivity record every
# other reader trusts is silently absent while this session still believes it holds the task.
claim_owner() { printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$OWNER_PID" "$OWN_START" "$(date +%s)" "$INSTANCE_ID" "$2" "${3:-}" > "$1/.owner"; }
setup_exclude() {                                # keep the .owner file out of the agent's `git add -A`
  local ex; ex="$(git -C "$1" rev-parse --git-path info/exclude)"; mkdir -p "$(dirname "$ex")"
  grep -qxF '/.owner' "$ex" 2>/dev/null || echo '/.owner' >> "$ex"
}

# KAIZERO_LINK: comma-separated top-level names symlinked from the repo root into a fresh Task
# worktree. A worktree checks out TRACKED files only, so gitignored Task material a Task's Task
# line points at is absent there and the agent works from the one-line title alone. Linked, not
# copied: an edit lands in the real file, not in a copy the worktree removal deletes. Added to
# info/exclude (the common dir's, like setup_exclude's) because a `name/` .gitignore pattern matches
# a DIRECTORY, not a symlink to one — unexcluded, the link rides along in the agent's `git add -A`.
link_ignored() {
  local wt=$1 root=${2:-$PWD} p ex IFS=,
  [ -n "${KAIZERO_LINK:-}" ] || return 0
  ex="$(git -C "$wt" rev-parse --git-path info/exclude)"; mkdir -p "$(dirname "$ex")"
  for p in $KAIZERO_LINK; do                 # entries were validated at startup, not re-checked here
    # -e AND -L: `-e` follows the link, so a DANGLING link at that name reads as absent and the
    # `ln -s` below would die `File exists`. Plain two-argument POSIX form — BSD and GNU agree on
    # it, and diverge on the `-r`/`-f`/`-n` flags this deliberately avoids.
    if [ ! -e "$wt/$p" ] && [ ! -L "$wt/$p" ]; then
      ln -s "$root/$p" "$wt/$p"
      grep -qxF "/$p" "$ex" 2>/dev/null || echo "/$p" >> "$ex"
    fi
  done
}

# repair_wt <path> [root]: clear the wreck a session killed mid-op can leave behind — repair the
# worktree registry entry, drop a stale index.lock, abort any live merge/rebase. root (default
# $COORD_ROOT, the baked coordination repo — never the caller's cwd) is `-C`'d for the registry
# repair only — the abort/lock checks always run IN the worktree itself. One helper, called for
# the coordination worktree on a coordination steal and for the target worktree on a target take
#.
repair_wt() {
  local wt=$1 root=${2:-} ilk
  if [ -n "$root" ]; then "$FLOCK_BIN" "$WT_LOCK" git -C "$root" worktree repair "$wt" >/dev/null 2>&1 || true
  else                    "$FLOCK_BIN" "$WT_LOCK" git -C "$COORD_ROOT" worktree repair "$wt"           >/dev/null 2>&1 || true
  fi
  exec 11>"$WT_LOCK"; "$FLOCK_BIN" 11
  ilk=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  [ -n "$ilk" ] && [ -f "$ilk" ] && rm -f "$ilk"
  git -C "$wt" merge  --abort 2>/dev/null || true
  git -C "$wt" rebase --abort 2>/dev/null || true
  exec 11>&-
}

# target worktree paths (coordination `.owner` line 5) of Tasks OTHER than $1 that a LIVE peer
# holds right now — reuses held_ids' liveness test (a coordination fact, never re-derived on the
# target side) so a live sibling's adopted branch is never mistaken for id $1's own.
live_target_wts_excluding() {
  local exclude_n=$1 id path twt5
  while IFS= read -r id; do
    [ "$id" = "$exclude_n" ] && continue
    path=$(wt_for_branch "$(task_branch "$id")")
    [ -n "$path" ] || continue
    [ -f "$path/.owner" ] || continue
    { read -r _; read -r _; read -r _; read -r _; read -r twt5 || twt5=""; } < "$path/.owner" 2>/dev/null || continue
    [ -n "$twt5" ] && printf '%s\n' "$twt5"
  done < <(held_ids)
}

# valid_target_wt <path> <excl>: true iff <path> is a target worktree this session may act on —
# on disk, under $WT_PARENT/tt- (never $TARGET_ROOT itself, never anywhere outside the Kaizero-
# managed area), and not one of <excl>'s (live_target_wts_excluding's) live-sibling paths. Shared by
# every reader of a target worktree path — acquire_target's `.owner`-hint and porcelain-scan
# candidates, and release_task's — so a `.owner` line 5 or a scan hit that fails these filters
# always reads as absent, never as a path to repair, reattach onto, or tear down.
valid_target_wt() {
  local path=$1 excl=$2
  [ -n "$path" ] && [ -d "$path" ] || return 1
  case "$path" in
    "$WT_PARENT"/tt-*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$excl" | grep -qxF "$path" && return 1
  return 0
}

# --- the target-side half of a claim -------------------------------------------------------
# acquire_target <n> — called DIRECTLY, never via `$(...)` (its globals must survive into
# acquire_task's own shell, not a subshell). READ-ONLY decision (no mutation): in the single-
# repository case this is a no-op (`TARGET_MODE=same`, twt==wt, nothing here changes). Otherwise decides take /
# reattach / fork from `target_branches_for_id`'s survivors. Globals set on success:
# TARGET_MODE (same|take|reattach|fork), TARGET_BRANCH, TARGET_TAKE_PATH. On failure: TARGET_REASON
# (the refusal text) and exit 3 (ambiguous or checked out at the target's main checkout — nothing
# created; exit 1 is never returned here, only by make_target_wt's caller).
acquire_target() {
  local n=$1 hint_twt=${2:-} survivors cnt excl first line rec_path rec_branch main_branch found_path found_branch
  TARGET_MODE=""; TARGET_BRANCH=""; TARGET_TAKE_PATH=""; TARGET_REASON=""
  if [ "$SAME_REPO" = 1 ]; then TARGET_MODE=same; return 0; fi

  survivors=$(target_branches_for_id "$n")
  cnt=0; [ -n "$survivors" ] && cnt=$(printf '%s\n' "$survivors" | grep -c .)
  if [ "$cnt" -gt 1 ]; then
    TARGET_REASON="target ambiguity at acquire — nothing created; candidate branches: $(printf '%s' "$survivors" | tr '\n' ' ')"
    return 3
  fi

  # coordination `.owner` line 5 (the REMEMBERED pairing) is authoritative over a fresh scan when
  # it still exists on disk AND passes the same candidate filters a scan would (under
  # $WT_PARENT/tt-, not a live sibling's adopted worktree) — a porcelain re-scan only ever finds a
  # worktree BY its current branch, which the agent (or a human) may have moved since; the hint
  # survives that drift and lets claim_task's own branch validation (below) catch it, rather than
  # this silently reattaching a second worktree and orphaning the first. Authoritative whether or
  # not the id still has a survivor branch — the no-survivor case (the branch was renamed out of
  # the id's namespace) is precisely where line 5 is the only pairing record left; discarding it
  # there would fork a duplicate and orphan the first. A hint that fails a filter (gone, outside
  # $WT_PARENT/tt-, a live sibling's) is stale: fall through to the fresh scan below, nothing here
  # repaired, aborted or reset.
  excl=$(live_target_wts_excluding "$n")
  if valid_target_wt "$hint_twt" "$excl"; then
    TARGET_MODE=take
    TARGET_BRANCH=${survivors:-$(target_branch "$n" "$(todo_title_for_id "$n")")}
    TARGET_TAKE_PATH=$hint_twt
    return 0
  fi

  # one porcelain scan of the target: record 1 is the main checkout (never a candidate — matching
  # it would make $twt the operator's own tree); a candidate must sit under $WT_PARENT/tt- and
  # must not be a live sibling's adopted worktree (excl, above).
  first=1; rec_path=""; rec_branch=""; main_branch=""; found_path=""; found_branch=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)          rec_path=${line#worktree } ;;
      branch\ refs/heads/*) rec_branch=${line#branch refs/heads/} ;;
      "")
        if [ "$first" = 1 ]; then
          main_branch=$rec_branch; first=0
        elif [ -n "$survivors" ] && [ "$rec_branch" = "$survivors" ]; then
          if valid_target_wt "$rec_path" "$excl"; then
            found_path=$rec_path; found_branch=$rec_branch
          fi
        fi
        rec_path=""; rec_branch="" ;;
    esac
  done < <(git -C "$TARGET_ROOT" worktree list --porcelain)

  if [ -n "$survivors" ] && [ "$main_branch" = "$survivors" ]; then
    TARGET_REASON="target branch $main_branch is checked out in $TARGET_ROOT; switch it away"
    return 3
  fi

  if [ -n "$found_path" ]; then
    TARGET_MODE=take; TARGET_BRANCH=$found_branch; TARGET_TAKE_PATH=$found_path; return 0
  fi
  if [ -n "$survivors" ]; then
    TARGET_MODE=reattach; TARGET_BRANCH=$survivors; return 0
  fi
  TARGET_MODE=fork; TARGET_BRANCH=$(target_branch "$n" "$(todo_title_for_id "$n")"); return 0
}

# make_target_wt <n> <mode> <branch> [take_path]: materializes acquire_target's decision — mode is
# same|take|reattach|fork as acquire_target names it, or `track` (acquire_task's own override
# of `fork` when the branch turns out to exist on origin already). Prune immediately before an add
# (clears a `tt-…` registry entry a human deleted by hand). Every
# mutation runs under the coordination WT_LOCK — one coordination repository per target is
# enforced at startup, so every instance that can touch this target shares this lock.
# Prints the target worktree path on success; on failure prints git's own stderr and returns 1.
make_target_wt() {
  local n=$1 mode=$2 branch=$3 take_path=${4:-} twt out
  case "$mode" in
    take)
      repair_wt "$take_path" "$TARGET_ROOT"
      printf '%s' "$take_path"; return 0 ;;
    reattach)
      # acquire_task's own required lookup has already proven origin's tip is an ancestor of
      # this local branch's (ahead or equal) — a local task branch is never fast-forwarded,
      # reset or otherwise moved here.
      twt="$WT_PARENT/tt-$branch-$(uuidgen | tr -d - | head -c7)"
      "$FLOCK_BIN" "$WT_LOCK" git -C "$TARGET_ROOT" worktree prune >/dev/null 2>&1 || true
      # No link_ignored here — this function runs only in the two-repository layout
      # (TARGET_MODE != same), where KAIZERO_LINK's material lives in COORD_ROOT, not
      # $TARGET_ROOT: nothing to link, so nothing is linked and $TARGET_ROOT's own exclude/config
      # stay untouched.
      if out=$("$FLOCK_BIN" "$WT_LOCK" git -C "$TARGET_ROOT" worktree add "$twt" "$branch" 2>&1); then
        printf '%s' "$twt"; return 0
      fi
      printf '%s' "$out"; return 1 ;;
    track)
      # No local branch, but acquire_task's own lookup found it on origin — checked out at the
      # exact ref that lookup's own fetch resolved (refs/remotes/origin/$branch), never via
      # `--track`/upstream resolution: a target cloned `--single-branch` or `--depth N` needs no
      # fetch refspec of its own for this to work, and the publish path names its own ref anyway.
      twt="$WT_PARENT/tt-$branch-$(uuidgen | tr -d - | head -c7)"
      "$FLOCK_BIN" "$WT_LOCK" git -C "$TARGET_ROOT" worktree prune >/dev/null 2>&1 || true
      if out=$("$FLOCK_BIN" "$WT_LOCK" git -C "$TARGET_ROOT" worktree add -b "$branch" "$twt" "refs/remotes/origin/$branch" 2>&1); then
        printf '%s' "$twt"; return 0
      fi
      printf '%s' "$out"; return 1 ;;
    fork)
      twt="$WT_PARENT/tt-$branch-$(uuidgen | tr -d - | head -c7)"
      "$FLOCK_BIN" "$WT_LOCK" git -C "$TARGET_ROOT" worktree prune >/dev/null 2>&1 || true
      if out=$("$FLOCK_BIN" "$WT_LOCK" git -C "$TARGET_ROOT" worktree add "$twt" -b "$branch" "$TB" 2>&1); then
        printf '%s' "$twt"; return 0
      fi
      printf '%s' "$out"; return 1 ;;
  esac
}

# looks_like_network_error/network_reachable: duplicated from the parent script's own top-level
# definitions (kaizero.sh, near looks_like_network_error()/network_reachable()) — this heredoc
# has no access to those, so acquire_task's MR-mode origin lookup below needs its own copy.
looks_like_network_error() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *"could not resolve host"*|*"no such host"*|*"dial tcp"*|*"i/o timeout"*|*"timeout"*| \
    *"connection refused"*|*"network is unreachable"*|*"tls handshake"*|*"deadline exceeded"*| \
    *"connection reset"*|*"no route to host"*|*"could not connect"*|*"couldn't connect"*| \
    *"failed to connect"*)
      return 0 ;;
    *) return 1 ;;
  esac
}
network_reachable() {
  local pushurl out rc=0
  pushurl="$(git -C "$TARGET_ROOT" remote get-url --push origin 2>/dev/null)" || pushurl=origin
  out="$(GIT_TERMINAL_PROMPT=0 timeout "${NETWORK_PROBE_TIMEOUT:-10}" \
    git -C "$TARGET_ROOT" ls-remote --exit-code --heads "$pushurl" "refs/heads/$TARGET_BASE" 2>&1 1>/dev/null)" || rc=$?
  # shellcheck disable=SC2034  # read by the parent script's wait_for_reviews; this heredoc copy has no such caller
  NETWORK_ERR="$out"
  case "$rc" in
    0) return 0 ;;
    2) return 2 ;;
    124) return 1 ;;
    *) looks_like_network_error "$out" && return 1 || return 3 ;;
  esac
}

# fetch_ref_safe <branch>: race-safe stand-in for `git fetch origin +refs/heads/<branch>:refs/
# remotes/origin/<branch>`, called by acquire_task for the base ref every claim refreshes and for
# a task branch a take/reattach may refresh — both refs a concurrent peer can refresh at the same
# instant. Driven red by tests/D-001-a-branch-take-back-from-origin.md's D20 (three concurrent
# claims while origin advances: "D20 all three concurrent claims succeeded, none reported
# unreachable : 4 (want 0)" observed this session before this function existed). A plain refspec
# fetch's ref update reads the destination's current value before it locks, then aborts
# ("incorrect old value provided") if a concurrent peer already moved it in between — exactly what
# three claims refreshing the shared base ref at once triggers. Sidesteps the race by fetching
# into a call-unique scratch ref no one else touches (so that fetch's own ref-write never
# contends), then setting the real tracking ref with a plain `update-ref` that carries no expected
# old value — never something a concurrent writer's own update can conflict with. Every peer
# converges on origin's tip regardless of write order, so it does not matter who wins.
# `--refmap=`: without it, a target cloned normally (not `--single-branch`) already carries
# `remote.origin.fetch = +refs/heads/*:refs/remotes/origin/*`, and plain git fetch applies that
# CONFIGURED refspec as a bonus alongside the explicit one — updating refs/remotes/origin/<branch>
# opportunistically even though only the scratch ref was asked for, racing on it exactly as
# before. `--refmap=` (empty) suppresses that bonus mapping, so the scratch ref is the only
# thing this fetch ever writes.
fetch_ref_safe() {
  local branch=$1 tmpref sha
  tmpref="refs/czfetch/$$-$RANDOM"
  if ! git -C "$TARGET_ROOT" fetch --refmap= origin "+refs/heads/$branch:$tmpref" >/dev/null 2>&1; then
    git -C "$TARGET_ROOT" update-ref -d "$tmpref" >/dev/null 2>&1
    return 1
  fi
  sha=$(git -C "$TARGET_ROOT" rev-parse -q --verify "$tmpref" 2>/dev/null) || sha=""
  git -C "$TARGET_ROOT" update-ref -d "$tmpref" >/dev/null 2>&1
  [ -n "$sha" ] || return 1
  git -C "$TARGET_ROOT" update-ref "refs/remotes/origin/$branch" "$sha" >/dev/null 2>&1
  return 0
}

# acquire: decide, then act — the target-side decision (read-only) runs first, before any
# coordination mutation, so an ambiguous/checked-out-elsewhere target refuses with nothing yet
# created (no coordination worktree, no branch, no `.owner`, no `set_current`). Prints, on
# success, three lines: twt (the agent's path) / wt (coordination, internal) / the target branch
# claim_task validates against — claim strips this to its first line, the
# one-line contract. On failure prints the refusal reason (may be empty) and returns 1 or 3.
acquire_task() {
  local n=$1 branch wt owner_pid owner_start owner_acq owner_inst owner_twt m m2 twt rc out fork
  local obr ocnt origin_tip local_tip lshort oshort
  branch=$(task_branch "$n")
  # MR mode forks off $TB (refs/remotes/origin/$TARGET_BASE), and a take/
  # reattach resumes a branch origin may have moved since — both refreshed BEFORE any lock below
  # (not WT_LOCK, not MERGE_LOCK, not the per-task reclaim lock), so a slow/offline origin never
  # serializes peers on this claim. Refspec spelled out (same shape as the doctor's own check 5)
  # so the remote-tracking ref is always updated, not left to the
  # clone's own fetch config; a fetch touches only refs, never the operator's own checkout in
  # $TARGET_ROOT. REQUIRED, not best-effort: a claim that cannot learn origin's tip must not
  # proceed on the local copy alone — refused with nothing created, the network-outage park then holds the
  # fleet until origin answers. network_reachable's own exit code (2 = base absent, never a network
  # cause) tells a permanently-missing base apart from an outage without reading git's prose; the
  # base itself is then fetched so refs/remotes/origin/$TARGET_BASE is current for every fork below.
  # (A take/reattach's own branch gets its required lookup further down, once acquire_target has
  # named it — necessarily after this lock.)
  if [ "$MR_MODE" = 1 ]; then
    network_reachable; rc=$?
    case "$rc" in
      0) : ;;
      2) printf "acquire %s: '%s' is not on origin in %s — push the base branch first: git push -u origin %s (a merge request needs a base branch that exists on the forge)" \
           "$n" "$TARGET_BASE" "$TARGET_ROOT" "$TARGET_BASE"; return 1 ;;
      *) printf 'acquire %s: origin unreachable — claim refused, nothing created' "$n"; return 1 ;;
    esac
    if ! fetch_ref_safe "$TARGET_BASE"; then
      printf 'acquire %s: origin unreachable — claim refused, nothing created' "$n"; return 1
    fi
  fi
  reap_dead_sessions
  exec 9>"$COORD_GITDIR/reclaim-$BR_SLUG-task-$n.lock"
  "$FLOCK_BIN" -n 9 || return 1                          # a peer is mid-acquire on this same Task → skip

  wt=$(wt_for_branch "$branch")
  # a registry entry surviving a hand-deleted directory must never wedge the id: prune once
  # and re-resolve so a gone `ts-…` is treated as absent, not as an existing worktree to repair.
  if [ -n "$wt" ] && [ ! -d "$wt" ]; then
    "$FLOCK_BIN" "$WT_LOCK" git -C "$COORD_ROOT" worktree prune >/dev/null 2>&1 || true
    wt=$(wt_for_branch "$branch")
  fi
  owner_pid=""; owner_acq=""; owner_inst=""; owner_twt=""
  if [ -n "$wt" ] && [ -f "$wt/.owner" ]; then
    { read -r owner_pid; read -r owner_start; read -r owner_acq; read -r owner_inst; read -r owner_twt || owner_twt=""; } < "$wt/.owner" 2>/dev/null || owner_pid=""
    if [ -n "$owner_pid" ] && [ "$(session_current "$owner_pid")" = "$n" ] \
         && session_alive "$owner_pid" "$owner_start"; then
      return 1                                    # actively owned by a live session on THIS Task
    fi
  fi

  if acquire_target "$n" "$owner_twt"; then :; else
    rc=$?; printf '%s' "$TARGET_REASON"; return "$rc"
  fi

  # Origin is the source of truth for a Task branch once it may have been pushed. Located by
  # origin_branches_for_id's own <id>- prefix rule and longest-id-wins tie-break — the same one
  # target_branches_for_id applies locally — never by the literal name acquire_target guessed
  # (a title edited after the Hand off must still find the branch the fleet pushed, not fork a
  # second one under the freshly re-derived slug). Two+ origin branches surviving that tie-break
  # refuse the claim outright, naming both, nothing created. No match on origin: nothing changes,
  # today's fork-off-base/take/reattach stands. A match whose work is already contained in $TB (a
  # re-opened `[x]` task, merged or squash-merged) is finished work and is ignored, so that task
  # still forks fresh off $TB. Otherwise: no local branch (mode fork) → adopt it (mode track,
  # `make_target_wt` checks the worktree out at the ref THIS fetch resolved, never `--track`/
  # upstream resolution); a local branch exists (take/reattach) → the two tips are only ever
  # compared, never moved — origin ahead-or-equal of local proceeds as usual (the push
  # fast-forwards), anything else (behind or diverged) refuses the claim with exit 8, naming the
  # branch, both short tips and the two-command repair, before anything is created.
  # No `TARGET_MODE = same` guard here: MR mode and the same-repository layout are already refused
  # together at launch (line 1102), so MR_MODE=1 alone already implies TARGET_MODE is never same.
  if [ "$MR_MODE" = 1 ]; then
    if ! obr=$(origin_branches_for_id "$n"); then
      printf 'acquire %s: origin unreachable — claim refused, nothing created' "$n"; return 1
    fi
    ocnt=0; [ -n "$obr" ] && ocnt=$(printf '%s\n' "$obr" | grep -c .)
    if [ "$ocnt" -gt 1 ]; then
      printf 'acquire %s: origin branch ambiguity — nothing created; candidate branches: %s' "$n" "$(printf '%s' "$obr" | tr '\n' ' ')"; return 3
    fi
    if [ -n "$obr" ]; then
      if ! fetch_ref_safe "$obr"; then
        printf 'acquire %s: origin unreachable — claim refused, nothing created' "$n"; return 1
      fi
      origin_tip=$(git -C "$TARGET_ROOT" rev-parse -q --verify "refs/remotes/origin/$obr") || origin_tip=""
      if [ -z "$origin_tip" ] || ! git -C "$TARGET_ROOT" merge-base --is-ancestor "$origin_tip" "$TB" 2>/dev/null; then
        case "$TARGET_MODE" in
          fork)
            TARGET_BRANCH=$obr; TARGET_MODE=track ;;
          take|reattach)
            local_tip=$(git -C "$TARGET_ROOT" rev-parse -q --verify "refs/heads/$TARGET_BRANCH") || local_tip=""
            if [ -z "$local_tip" ] || [ -z "$origin_tip" ] \
                 || ! git -C "$TARGET_ROOT" merge-base --is-ancestor "$origin_tip" "$local_tip" 2>/dev/null; then
              lshort=$(git -C "$TARGET_ROOT" rev-parse --short "${local_tip:-HEAD}" 2>/dev/null || printf '%s' "$local_tip")
              oshort=$(git -C "$TARGET_ROOT" rev-parse --short "$origin_tip" 2>/dev/null || printf '%s' "$origin_tip")
              printf 'acquire %s: %s cannot fast-forward onto origin (local %s, origin %s) — claim refused, nothing created; repair: git -C %s fetch origin %s && git -C %s branch -f %s origin/%s  (or: git -C %s branch -D %s)' \
                "$n" "$TARGET_BRANCH" "$lshort" "$oshort" "$TARGET_ROOT" "$TARGET_BRANCH" "$TARGET_ROOT" "$TARGET_BRANCH" "$TARGET_BRANCH" "$TARGET_ROOT" "$TARGET_BRANCH"
              return 8
            fi ;;
        esac
      fi
    fi
  fi

  if [ -n "$wt" ]; then
    # dead / pid-reused / moved-on / no .owner → steal this worktree in place. Credit its partial
    # todo-time (acquire epoch to newest file mtime; skips the crash-to-resume idle gap) to the
    # OWNER instance that worked it, not us. Self-steal across a context restart credits this
    # same instance.
    case "${owner_acq:-}" in ''|*[!0-9]*) ;; *)
      # The dead owner's work may sit in $wt, in its target worktree (owner_twt), or split
      # across both — take the newer of the two mtimes, never just $wt's.
      m=$(newest_mtime "$wt")
      if [ -n "$owner_twt" ] && [ "$owner_twt" != "$wt" ] && [ -d "$owner_twt" ]; then
        m2=$(newest_mtime "$owner_twt")
        [ -n "$m2" ] && { [ -z "$m" ] || [ "$m2" -gt "$m" ]; } && m=$m2
      fi
      [ -n "$m" ] && add_todos_time "$((m - owner_acq))" "${owner_inst:-}" ;;
    esac
    repair_wt "$wt"
    [ "$TARGET_MODE" != same ] && [ -n "$owner_twt" ] && [ -d "$owner_twt" ] && repair_wt "$owner_twt" "$TARGET_ROOT"
  fi

  if [ -z "$wt" ]; then
    # no worktree for the branch: make one. Reattach if the branch exists (orphaned by a release
    # that couldn't delete an unmerged branch, keeping its committed work); else fork off base.
    wt="$WT_PARENT/ts-$BR_SLUG-task-$n-$(uuidgen | tr -d - | head -c7)"
    "$FLOCK_BIN" "$WT_LOCK" git -C "$COORD_ROOT" worktree prune >/dev/null 2>&1 || true
    if git -C "$COORD_ROOT" rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
      "$FLOCK_BIN" "$WT_LOCK" git -C "$COORD_ROOT" worktree add "$wt" "$branch"                  >/dev/null 2>&1 || return 1   # reattach (git prints "HEAD is now at" to stdout — drop it)
    else
      "$FLOCK_BIN" "$WT_LOCK" git -C "$COORD_ROOT" worktree add "$wt" -b "$branch" "$COORD_BASE" >/dev/null 2>&1 || return 1  # fresh fork
    fi
    setup_exclude "$wt"
    [ "$TARGET_MODE" = same ] && link_ignored "$wt" "$TARGET_ROOT"   # single-repository case: today's behavior, unchanged
  fi

  if [ "$TARGET_MODE" = same ]; then
    twt=$wt
  else
    if twt=$(make_target_wt "$n" "$TARGET_MODE" "$TARGET_BRANCH" "$TARGET_TAKE_PATH"); then :; else
      release_task "$n"   # $twt (make_target_wt's git failure text) survives — release_task has its own local
      printf '%s' "$twt"; return 1
    fi
  fi

  # The branch's own merge-base with its base right now — recomputed on every acquire (take,
  # reattach, fork, track, or a fresh same-repository claim alike), never carried over from a stale
  # .owner, since a branch that hasn't been rebased has a stable merge-base with base regardless of
  # how many peer merges base gained since. With one repository the coordination branch IS the
  # target branch, so this reads $branch against $COORD_BASE instead of $TARGET_BRANCH against $TB.
  fork=""
  if [ "$TARGET_MODE" = same ]; then
    fork=$(git -C "$COORD_ROOT" merge-base "$branch" "$COORD_BASE" 2>/dev/null || true)
  else
    fork=$(git -C "$TARGET_ROOT" merge-base "$TARGET_BRANCH" "$TB" 2>/dev/null || true)
  fi

  if claim_owner "$wt" "$twt" "$fork"; then :; else
    release_task "$n" "$twt"
    printf 'acquire %s: could not write .owner — claim refused, nothing held' "$n"; return 1
  fi
  set_current "$n"
  printf '%s\n%s\n%s' "$twt" "$wt" "$TARGET_BRANCH"; return 0
}

# claim: the WHOLE "is this Task mine to work?" decision in one call — validate the id and this
# task_id's own Task file, acquire, validate both worktrees, then re-check that no peer landed it
# first. Prints the TARGET worktree path (stdout, no newline) + exit 0 when it is yours — the
# coordination worktree's path appears nowhere in claim's output. Every skip reason goes to
# stderr with a distinct exit code so TEST.md can assert which path ran: 1 = not claimed,
# 2 = id validation failed (whole-tail — a corrupted id anywhere threatens the whole tail's
# branch-naming scheme), 3 = validation failed (coordination OR target side — a second
# coordination point driving the target, target ambiguity/checked-out-elsewhere, from acquire_target), 4 = already Landed,
# 6 = this task_id's own Task-file/Acceptance-Criteria validation failed (localized — some OTHER
# task_id's broken file never shows up here), 7 = ensure_owner's own FATAL (no valid session
# record), 8 = this task's branch cannot fast-forward onto origin's — move it, then
# reclaim (acquire_task's own origin-branch lookup, MR mode only; nothing created). 2 and 7 are
# systemic — the agent STOPs the whole run; 1/3/4/6/8 are localized and
# the agent skips to the next candidate. Takes the RAW id: acquire/release want it sanitized,
# is_done wants it raw (it matches the Task line's first token), so both values are held here.
claim_task() {
  local raw=$1 n out rc wt twt tbranch br tbr survivors tid tcls trest cur
  # one task per session: a session that already owns a Task and calls claim again — for the
  # same id or another — is refused and keeps that ownership; checked before acquire_task ever
  # runs, so a refused call changes nothing. Ownership was a single slot silently overwritten by
  # a second claim, which would orphan the Task still in progress and free its live worktree for
  # a peer to steal.
  cur=$(session_current "$OWNER_PID")
  if [ "$cur" != none ]; then
    echo "claim $raw: not claimed — this session already owns $cur; release or land it before claiming another" >&2
    return 1
  fi
  # re-proves what the launcher's own pre-launch checks only ever prove once (TASK-054): a human
  # editing todo.md mid-session, or a Task file breaking mid-session, must not go undetected until
  # the next `claude` launch. validate_ids stays whole-tail, exactly like the standalone
  # `validate-ids` subcommand. The Task-file check below is scoped to raw ALONE, via
  # resolve_task_ids — the opposite scope from the standalone `validate-tasks` subcommand, which
  # resolves every unchecked id at once; inside claim, only whether THIS task_id's own file
  # resolves matters.
  if ! validate_ids; then
    echo "claim $raw: id validation invalid" >&2
    return 2
  fi
  IFS=$'\t' read -r tid tcls trest < <(printf '%s\n' "$raw" | resolve_task_ids)
  case "$tcls" in
    missing)   echo "claim $raw: task definition invalid — $(fmt_task_finding "missing-task-file"$'\t'"$tid")" >&2; return 6 ;;
    ambiguous) echo "claim $raw: task definition invalid — $(fmt_task_finding "ambiguous-task-file"$'\t'"$tid"$'\t'"$trest")" >&2; return 6 ;;
    ok)        check_ac_file "$trest" || { echo "claim $raw: task definition invalid — $(fmt_task_finding "empty-acceptance-criteria"$'\t'"$tid"$'\t'"$trest")" >&2; return 6; } ;;
  esac
  n=$(sanitize_id "$raw")
  if out=$(acquire_task "$n"); then :; else
    rc=$?
    echo "claim $raw: not claimed — ${out:-a peer owns it or it is being rescued}" >&2
    return "$rc"
  fi
  { IFS= read -r twt; IFS= read -r wt; IFS= read -r tbranch || true; } <<< "$out"

  br=""   # set -e: keep the probe in an `if` — a bare failing `&&` chain would kill the process
  if [ -n "$wt" ] && [ -d "$wt" ]; then br=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || true); fi
  if [ "$br" != "$(task_branch "$n")" ]; then
    # do NOT release: that would force-remove a worktree sitting on an unexpected branch with
    # unknown contents. Just drop the session claim; a later acquire steals it the normal way.
    set_current none
    echo "claim $raw: validation failed — worktree ${wt:-<none>} is on ${br:-<none>}, want $(task_branch "$n")" >&2
    return 3
  fi

  if [ "$twt" != "$wt" ]; then
    tbr=""
    if [ -d "$twt" ]; then tbr=$(git -C "$twt" symbolic-ref --short HEAD 2>/dev/null || true); fi
    if [ "$tbr" != "$tbranch" ]; then
      # foreign branch or detached HEAD in the target worktree (agent ran checkout/rebase by
      # hand) — park the Task for a human; the repair never switches branches on its own, because
      # the foreign branch may be where the work is.
      set_current none
      echo "claim: $raw not validated — $twt is on branch ${tbr:-<detached>}, not $tbranch — git -C $twt checkout $tbranch" >&2
      return 3
    fi
  fi

  if is_done "$raw" "$wt"; then
    release_task "$n" "$twt"
    # a filled box is a landing locally, but in MR mode as often a [↑] Hand off — name both routes
    echo "claim $raw: already landed$([ "${MR_MODE:-0}" = 1 ] && printf ' or handed off') on $COORD_BASE by a peer — released" >&2; return 4
  fi
  printf '%s' "$twt"
}

# --- teardown_target -------------------------------------------------------------------------
# teardown_target <twt>: a no-op in the single-repository case — the single-worktree cleanup in release_task/
# merge_task already covers it. Otherwise removes the target worktree under WT_LOCK, then deletes
# its branch ONLY when it is an ancestor of TARGET_BASE. -D, not -d: -d judges "merged" against
# the target's main checkout's CURRENT HEAD, whatever branch the operator happens to be on while
# the fleet runs — an unmerged Task branch merged into the operator's own feature branch would be
# deleted. The ancestry test pins the same safety semantic to the base instead. Called from
# release_task and merge_task, both of which read `.owner` line 5 (the target-worktree pairing)
# off the coordination worktree ON DEMAND, right before this call, so this always runs BEFORE
# either removes the coordination worktree — the pair record lives there, so it must go last for
# them. mr_task's own success path is the third caller: it never reads `.owner` at all (its own
# $twt argument already IS that pairing, resolved by the claim that handed it out), so it runs
# this after its own coordination-side cleanup instead, with nothing left depending on order.
teardown_target() {
  local twt=$1 branch
  [ "$SAME_REPO" = 1 ] && return 0
  [ -n "$twt" ] && [ -d "$twt" ] || return 0
  branch=$(git -C "$twt" symbolic-ref --short -q HEAD 2>/dev/null || true)
  remove_worktree "$TARGET_ROOT" "$twt" "teardown" || true
  if [ -n "$branch" ] && git -C "$TARGET_ROOT" merge-base --is-ancestor "$branch" "$TB" 2>/dev/null; then
    "$FLOCK_BIN" "$WT_LOCK" git -C "$TARGET_ROOT" branch -D "$branch" >/dev/null 2>&1 || true
  fi
}

# release: undo a claim (both worktrees + the coordination branch) and mark this session idle.
# Takes only the Task id — the coordination worktree is looked up by branch (wt_for_branch, as
# credit_inflight_time does), never assumed to be an argument, so it works whether the caller
# holds the coordination or the target path. -d refuses a branch with unmerged commits (safety),
# leaving an orphan branch a later acquire reattaches. $2, if given, is a target path to also
# remove even before `.owner` names one (the acquire-time fork/reattach failure path). Target
# teardown runs first (`.owner` line 5, else — only when absent — a scan of TARGET_ROOT by this
# id's target branches), then the coordination worktree, per teardown_target's ordering rule.
release_task() {
  local n=$1 hint_twt=${2:-} branch wt twt s cand excl
  branch=$(task_branch "$n")
  wt=$(wt_for_branch "$branch")
  twt=$hint_twt
  if [ -z "$twt" ]; then
    # $hint_twt (above) is this claim's OWN known result, trusted as-is; anything read back off
    # disk here (a `.owner` hint, a scan hit) must pass the same candidate filters acquire_target
    # applies, or a stale/foreign path — $TARGET_ROOT itself, a live sibling's adopted worktree —
    # gets torn down instead of a peer's or the operator's own tree.
    excl=$(live_target_wts_excluding "$n")
    if [ -n "$wt" ] && [ -f "$wt/.owner" ]; then
      cand=$(sed -n '5p' "$wt/.owner" 2>/dev/null || true)
      valid_target_wt "$cand" "$excl" && twt=$cand
    fi
    if [ -z "$twt" ]; then
      # single-repository case: target_branches_for_id's "$n-*" scheme never matches this mode's own
      # "$COORD_BASE-task-$n" branch name, so the loop below finds nothing and costs one empty scan.
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        cand=$(wt_for_branch_in "$TARGET_ROOT" "$s")
        valid_target_wt "$cand" "$excl" && { twt=$cand; break; }
      done < <(target_branches_for_id "$n")
    fi
  fi
  teardown_target "$twt"
  [ -n "$wt" ] && { remove_worktree "$COORD_ROOT" "$wt" "release" || true; }
  git -C "$COORD_ROOT" branch -d "$branch" >/dev/null 2>&1 || true
  set_current none
}

# --- the land gate + landing mechanics --------------------------------------------------------
# two separate files, one per landing checkout — never one shared file: marking the target root's
# merge in flight must not erase a dead peer's marker for the coordination root, or vice versa
#. With one repository both roots are the same value, so inflight_file_for always answers
# the coordination file — moot, since that mode has only ever the one landing checkout.
MERGE_INFLIGHT_TARGET="$COORD_GITDIR/merge-inflight-target"
MERGE_INFLIGHT_COORD="$COORD_GITDIR/merge-inflight-coord"
# scratch file for tick_box's own commit-hook stderr — see the comment at its write site.
TICK_FAIL_FILE="$COORD_GITDIR/tick-fail-reason"
inflight_file_for() {
  # with one repository TARGET_ROOT and COORD_ROOT are the same value, so "$1" always matches and
  # this always answers the target file — moot (that layout has only the one landing checkout).
  if [ "$1" = "$TARGET_ROOT" ]; then printf '%s' "$MERGE_INFLIGHT_TARGET"
  else printf '%s' "$MERGE_INFLIGHT_COORD"; fi
}

# write/clear the crash marker around each landing `git merge` — pid, start-time, the root that
# merge touches — so a MERGE_HEAD a crash left behind can be told from a human's own merge.
mark_inflight()  { INFLIGHT_FILE=$(inflight_file_for "$1"); printf '%s\n%s\n%s\n' "$$" "$(proc_start "$$")" "$1" > "$INFLIGHT_FILE"; }
clear_inflight() { [ -n "${INFLIGHT_FILE:-}" ] && rm -f "$INFLIGHT_FILE"; }
# true iff root $1's own marker file names it and that entry's pid is no longer that same
# process — i.e. THIS fleet's own wreck, safe to abort. A marker for a different root, or a live
# pid, is not.
inflight_dead_for() {
  local root=$1 pid st mroot f
  f=$(inflight_file_for "$root")
  [ -f "$f" ] || return 1
  { read -r pid; read -r st; read -r mroot; } < "$f" 2>/dev/null || return 1
  [ "$mroot" = "$root" ] || return 1
  ! { kill -0 "$pid" 2>/dev/null && [ "$(proc_start "$pid")" = "$st" ]; }
}

# quiet_checkout <root> <full|todo> [todo_path]: prints '' and returns 0 when $root is quiet
# enough to receive a merge; else prints the refusal clause (no trailing punctuation) and returns
# 1. A MERGE_HEAD this fleet's own dead peer left (per $root's own crash-marker file) is aborted
# here and counted as quiet; every other in-progress state, or a live/foreign owner of MERGE_HEAD,
# is a human's and refuses. `full` demands the whole tracked tree clean; `todo` only $todo_path
# against HEAD — the coordination checkout's tick commits that file alone, so other edits there are fine.
quiet_checkout() {
  local root=$1 mode=$2 todo=${3:-} gd
  # --absolute-git-dir, not --git-dir: for a normal (non-bare, non-worktree) repo the latter
  # returns a path relative to $root (often just ".git") — every bare `[ -f "$gd/…" ]` below then
  # reads relative to the CALLING process's cwd, not $root, misreading whichever checkout the
  # agent happens to be sitting in as the one this call names.
  gd=$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null) || { printf 'is not a readable git repository'; return 1; }
  if [ -f "$gd/MERGE_HEAD" ]; then
    if inflight_dead_for "$root"; then
      git -C "$root" merge --abort >/dev/null 2>&1 || true
    else
      printf 'has a merge in progress — finish or abort it, then retry'; return 1
    fi
  fi
  if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
    printf 'has a rebase in progress — finish or abort it, then retry'; return 1
  fi
  if [ -f "$gd/CHERRY_PICK_HEAD" ]; then printf 'has a cherry-pick in progress — finish or abort it, then retry'; return 1; fi
  if [ -f "$gd/REVERT_HEAD" ]; then printf 'has a revert in progress — finish or abort it, then retry'; return 1; fi
  if [ -f "$gd/BISECT_LOG" ]; then printf 'has a bisect in progress — finish or abort it, then retry'; return 1; fi
  if [ "$mode" = full ]; then
    [ -z "$(git -C "$root" status --porcelain --untracked-files=no)" ] \
      || { printf 'has uncommitted changes — commit or stash them, then retry'; return 1; }
  else
    git -C "$root" diff --quiet HEAD -- "$todo" 2>/dev/null \
      || { printf 'has uncommitted changes — commit or stash them, then retry'; return 1; }
  fi
  return 0
}

# tick_box <raw_id> <symbol> [retick]: rewrites the Task's checkbox line in $TODO_ABS (COORD_ROOT
# must already be checked out on $COORD_BASE) and commits it alone. Idempotent — an already-landed
# line is left untouched and nothing is committed, UNLESS the third argument is exactly `retick`,
# in which case a landed box is rewritten too (sync_mrs). Echoes missing/checked/unchecked;
# 'missing' is the caller's to fail on.
tick_box() {
  local raw=$1 sym=$2 retick=${3:-} state nonl tmp mode commit_out commit_rc
  state=$(awk -v id="$raw" '
    function unwraplink(s) {
      if (s ~ /^\[[^]]+\]\([^)]+\)$/) { sub(/^\[/, "", s); sub(/\]\(.*$/, "", s) }
      return s
    }
    /^[ \t]*```/ { fence = !fence; next }
    fence        { next }
    /^[ \t]*- \[[^]]+\]/ {
      line = $0
      sub(/^[ \t]*- \[/, "", line)
      match(line, /^[^]]+\]/)
      box = substr(line, 1, RLENGTH - 1)
      rest = substr(line, RLENGTH + 1); sub(/^[ \t]*/, "", rest)
      split(rest, a, /[ \t]/)
      if (unwraplink(a[1]) == id) { print (box == " " ? "unchecked" : "checked"); f = 1; exit }
    }
    END { if (!f) print "missing" }
  ' "$TODO_ABS")
  case "$state" in
    unchecked)
      # byte-exact rewrite: symbol reaches awk via ENVIRON (never -v — that decodes backslash
      # escapes) and never inside a regex; the box is replaced by substr, not a template.
      nonl=0; [ -z "$(tail -c1 "$TODO_ABS")" ] || nonl=1   # file had no trailing newline?
      mode=$(stat -c %a "$TODO_ABS" 2>/dev/null || stat -f %Lp "$TODO_ABS")   # GNU vs BSD stat, self-contained (this function is eval-extracted by tests) — GNU first: GNU's own -f means filesystem-status and silently succeeds on a bogus %Lp, so a BSD-first order never falls through
      tmp="$TODO_ABS.zero.tmp.$$"
      SYM="$sym" awk -v id="$raw" '
        function unwraplink(s) {
          if (s ~ /^\[[^]]+\]\([^)]+\)$/) { sub(/^\[/, "", s); sub(/\]\(.*$/, "", s) }
          return s
        }
        BEGIN { sym = ENVIRON["SYM"] }
        /^[ \t]*```/ { fence = !fence; print; next }
        fence        { print; next }
        !done && /^[ \t]*- \[ \]/ {
          line = $0
          sub(/^[ \t]*- \[/, "", line)
          rest = line; sub(/^ \][ \t]*/, "", rest)
          split(rest, a, /[ \t]/)
          if (unwraplink(a[1]) == id) {
            p = index($0, "[")
            print substr($0, 1, p) sym substr($0, p + 2)
            done = 1
            next
          }
        }
        { print }
      ' "$TODO_ABS" > "$tmp"
      if [ "$nonl" = 1 ]; then printf '%s' "$(cat "$tmp")" > "$tmp.2" && mv "$tmp.2" "$tmp"; fi
      chmod "$mode" "$tmp"
      mv "$tmp" "$TODO_ABS"
      # commit -- <path>: snapshots only the todo file's own change; any other file already staged
      # by the operator (merge_two_repos' coordination checkout allows it — quiet_checkout's todo
      # mode only demands $TODO_PATH itself be clean) stays staged and uncommitted — the index is
      # never swept whole into this commit.
      if git -C "$COORD_ROOT" add "$TODO_PATH"; then
        commit_out=$(git -C "$COORD_ROOT" commit -q -m "zero $raw" -- "$TODO_PATH" 2>&1); commit_rc=$?
      else
        commit_out="git add failed"; commit_rc=1
      fi
      if [ "$commit_rc" -ne 0 ]; then
        # tick rejected (a pre-commit hook is the ordinary cause) — leave the todo file exactly as
        # it stood against HEAD, never half-staged, so the next merge's land gate sees it clean.
        # The caller invokes tick_box via `state=$(tick_box …)` — a command substitution, which
        # runs this whole function in a SUBSHELL, so a plain global assignment here never reaches
        # the caller's shell. A file does: written here, read back by the caller after the
        # substitution returns, to quote in its own exit-5 line.
        git -C "$COORD_ROOT" reset -q -- "$TODO_PATH" 2>/dev/null
        git -C "$COORD_ROOT" checkout -q HEAD -- "$TODO_PATH" 2>/dev/null
        state=failed
        printf '%s' "${commit_out:-a repository hook rejected the commit with no output}" > "$TICK_FAIL_FILE"
      fi ;;
    checked)
      if [ "$retick" = "retick" ]; then
        # same byte-exact rewrite, over a box that already holds a symbol — its length (never
        # assumed 1) comes from the same match/RLENGTH read the state pass above just did.
        nonl=0; [ -z "$(tail -c1 "$TODO_ABS")" ] || nonl=1
        mode=$(stat -c %a "$TODO_ABS" 2>/dev/null || stat -f %Lp "$TODO_ABS")   # GNU vs BSD stat, self-contained (this function is eval-extracted by tests) — GNU first: GNU's own -f means filesystem-status and silently succeeds on a bogus %Lp, so a BSD-first order never falls through
        tmp="$TODO_ABS.zero.tmp.$$"
        SYM="$sym" awk -v id="$raw" '
          function unwraplink(s) {
            if (s ~ /^\[[^]]+\]\([^)]+\)$/) { sub(/^\[/, "", s); sub(/\]\(.*$/, "", s) }
            return s
          }
          BEGIN { sym = ENVIRON["SYM"] }
          /^[ \t]*```/ { fence = !fence; print; next }
          fence        { print; next }
          !done && /^[ \t]*- \[[^]]+\]/ {
            line = $0
            sub(/^[ \t]*- \[/, "", line)
            match(line, /^[^]]+\]/)
            boxlen = RLENGTH - 1
            rest = substr(line, RLENGTH + 1); sub(/^[ \t]*/, "", rest)
            split(rest, a, /[ \t]/)
            if (unwraplink(a[1]) == id) {
              p = index($0, "[")
              print substr($0, 1, p) sym substr($0, p + 1 + boxlen)
              done = 1
              next
            }
          }
          { print }
        ' "$TODO_ABS" > "$tmp"
        if [ "$nonl" = 1 ]; then printf '%s' "$(cat "$tmp")" > "$tmp.2" && mv "$tmp.2" "$tmp"; fi
        chmod "$mode" "$tmp"
        mv "$tmp" "$TODO_ABS"
        git -C "$COORD_ROOT" add "$TODO_PATH" && git -C "$COORD_ROOT" commit -q -m "zero sync $raw"
      fi ;;
  esac
  printf '%s' "$state"
}

# commit_ac_checkoff <raw_id>: commits task_id's own Task file — wherever it resolves under
# $COORD_ROOT — directly onto $COORD_BASE in the coordination checkout, and nothing else. Same
# serialization tick_box's callers already take (MERGE_LOCK) so a peer's own in-flight tick, or
# the operator's own dirty file elsewhere in $COORD_ROOT, is never swept into this commit.
# Idempotent: nothing changed since the last call exits 0 with no commit. Never lands on the
# coordination claim branch (guarded as a claim, not a carrier) nor on task_id's own branch —
# always $COORD_BASE, whatever branch $COORD_ROOT happened to be sitting on before this call.
commit_ac_checkoff() {
  local raw=$1 tid tcls trest gd commit_out commit_rc
  IFS=$'\t' read -r tid tcls trest < <(printf '%s\n' "$raw" | resolve_task_ids)
  case "$tcls" in
    missing)   echo "commit_ac_checkoff $raw: task definition invalid — $(fmt_task_finding "missing-task-file"$'\t'"$tid")" >&2; return 6 ;;
    ambiguous) echo "commit_ac_checkoff $raw: task definition invalid — $(fmt_task_finding "ambiguous-task-file"$'\t'"$tid"$'\t'"$trest")" >&2; return 6 ;;
  esac

  exec 10>"$MERGE_LOCK"; "$FLOCK_BIN" 10
  # the structural half of quiet_checkout, inlined rather than reused: quiet_checkout's todo/full
  # diff check demands $trest be CLEAN against HEAD, but here a dirty $trest (the session's own
  # tick/note) is exactly what this call exists to commit — reusing it would refuse the one state
  # it is meant to act on.
  gd=$(git -C "$COORD_ROOT" rev-parse --absolute-git-dir 2>/dev/null) || {
    exec 10>&-; echo "commit_ac_checkoff $raw: $COORD_ROOT is not a readable git repository" >&2; return 5
  }
  if [ -f "$gd/MERGE_HEAD" ] || [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ] \
     || [ -f "$gd/CHERRY_PICK_HEAD" ] || [ -f "$gd/REVERT_HEAD" ] || [ -f "$gd/BISECT_LOG" ]; then
    exec 10>&-
    echo "commit_ac_checkoff $raw: $COORD_ROOT has an operation in progress — finish or abort it, then retry" >&2
    return 5
  fi
  git -C "$COORD_ROOT" checkout -q "$COORD_BASE"

  if git -C "$COORD_ROOT" diff --quiet HEAD -- "$trest" 2>/dev/null; then
    exec 10>&-
    return 0   # nothing ticked/noted since the last call — idempotent no-op
  fi

  if git -C "$COORD_ROOT" add "$trest"; then
    commit_out=$(git -C "$COORD_ROOT" commit -q -m "commit_ac_checkoff $raw" -- "$trest" 2>&1); commit_rc=$?
  else
    commit_out="git add failed"; commit_rc=1
  fi
  exec 10>&-
  if [ "$commit_rc" -ne 0 ]; then
    echo "commit_ac_checkoff $raw: $commit_out" >&2
    return 1
  fi
  return 0
}

# which Task id (if any) owns branch $1, per target_branches_for_id's longest-id-wins rule —
# The land gate's test 0 uses it only to name whose branch a mismatched $twt is actually on.
branch_owner_id() {
  local br=$1 id cand
  while IFS= read -r id; do
    while IFS= read -r cand; do
      [ "$cand" = "$br" ] && { printf '%s' "$id"; return 0; }
    done < <(target_branches_for_id "$id")
  done < <(todo_ids | sort -u)
  return 1
}

# single-repository case: today's single-write landing — checkout + merge (code), then tick_box (box), one
# repository, one checkout. Gate test 4 (quiet_checkout, full) runs first, inside MERGE_LOCK — not
# repository-count-conditional: the hazard of a human's own merge/rebase/dirty tree in this one
# checkout is today's too.
merge_same_repo() {
  local raw=$1 wt=$2 branch=$3 sym=$4 fork=${5:-} reason mb head merge_out merge_rc state wt_rc br_rc co_out cur skip_code_merge=0
  exec 10>"$MERGE_LOCK"; "$FLOCK_BIN" 10
  reason=$(quiet_checkout "$COORD_ROOT" todo "$TODO_PATH")
  if [ -n "$reason" ]; then
    exec 10>&-
    echo "merge $raw: land gate failed at local: $COORD_ROOT $reason" >&2
    return 5
  fi

  # guard: the branch must not touch the Release Todo List — zero.sh ticks the box itself, on base,
  # never on the Task branch. Checked against the fork point so an already-merged retry (its own
  # diff against itself is empty) always passes. A refusal, not a conflict — nothing to resolve and
  # retry, so exit 5 (the land gate), never 2.
  mb=$(git -C "$COORD_ROOT" merge-base "$COORD_BASE" "$branch") || {
    exec 10>&-; echo "merge $raw: land gate failed at local: no merge base for $branch on $COORD_BASE" >&2; return 5
  }
  if ! git -C "$COORD_ROOT" diff --quiet "$mb" "$branch" -- "$TODO_PATH"; then
    exec 10>&-
    echo "merge $raw: land gate failed at local: $branch changes $TODO_PATH — zero.sh ticks the box itself, the agent never edits the Release Todo List" >&2
    return 5
  fi

  # the checkbox line's existence is a gate, decided before anything is merged — under MERGE_LOCK
  # nothing else can add or remove it before the tick below, so a refusal here never leaves the
  # task's code on base with no box to tick and no retry that can ever succeed.
  if ! box_symbol_on_base "$raw" >/dev/null; then
    exec 10>&-
    echo "merge $raw: land gate failed at local: no checkbox line for $raw in $TODO_PATH on $COORD_BASE" >&2
    return 5
  fi

  # test 3: a branch whose tip is still exactly its own recorded fork point (acquire_task's
  # merge-base with COORD_BASE at claim time) never moved at all — no commit, empty or otherwise,
  # to land. SHA equality against the recorded fork, not a fresh merge-base or a tree-diff: once a
  # first attempt's code merge has already landed the branch (tick failed, box still `[ ]`), a
  # freshly computed merge-base collapses onto the tip and would misread that retry as "no work"
  # too — `fork` is what tells the two apart. `fork` empty (an older .owner with no fork point) skips the test.
  # BUG-059a: head==fork alone doesn't mean "no work" — a human can uncheck the box by hand after
  # an earlier, separate merge already landed this id's code. Two more facts distinguish that from
  # a genuinely untouched claim: the box's current symbol no longer matches the target, AND a
  # "merge $branch" commit (task_branch is deterministic per id, so this exact message recurs
  # every time this id lands) is already in COORD_BASE's history. Both true → the code is already
  # on base, only the tick is missing — skip the code merge and go straight to tick_box below.
  # Either false — box already matches, or this id never landed before — refuse exactly as today.
  head=$(git -C "$COORD_ROOT" rev-parse "$branch")
  if [ -n "$fork" ] && [ "$head" = "$fork" ]; then
    cur=$(box_symbol_on_base "$raw") || cur=""
    if [ "$cur" != "$sym" ] && git -C "$COORD_ROOT" log --format=%s "$COORD_BASE" | grep -Fxq "merge $branch"; then
      skip_code_merge=1
    else
      exec 10>&-
      echo "merge $raw: land gate failed at local: $wt carries no change against $COORD_BASE (diff $COORD_BASE...HEAD is empty) — commit your work first" >&2
      return 5
    fi
  fi

  # an unrelated tracked file staged (or modified) in the coordination checkout is allowed by the
  # `todo` gate above (only $TODO_PATH itself must be clean) but a bare `git checkout`/`merge` pair
  # can refuse or silently swallow it (git's own merge machinery treats any index entry outside
  # HEAD as at risk) — stash it around the two writes below and restore it exactly (`--index`) on
  # every exit path below. Explicit calls, not a RETURN trap: bash's RETURN trap fires on every
  # function return from the point it's set, including nested calls (remove_worktree below) made
  # before this function's own return — not just this function's.
  local stashed=0
  if [ -n "$(git -C "$COORD_ROOT" status --porcelain --untracked-files=no)" ]; then
    git -C "$COORD_ROOT" stash push --quiet -m "zero-merge-$raw" && stashed=1
  fi

  mark_inflight "$COORD_ROOT"
  co_out=$(git -C "$COORD_ROOT" checkout "$COORD_BASE" 2>&1)
  if [ "$(git -C "$COORD_ROOT" symbolic-ref --short -q HEAD 2>/dev/null)" != "$COORD_BASE" ]; then
    clear_inflight; if [ "$stashed" = 1 ]; then git -C "$COORD_ROOT" stash pop --quiet --index 2>/dev/null || echo "merge $raw: warning: stash pop failed — an unrelated staged/modified file is stuck in git stash list; recover it by hand" >&2; fi
    exec 10>&-
    echo "merge $raw: land gate failed at local: $COORD_ROOT checkout of $COORD_BASE failed: $co_out" >&2
    return 5
  fi
  if [ "$skip_code_merge" -eq 0 ]; then
    merge_out=$(git -C "$COORD_ROOT" merge --no-ff -m "merge $branch" "$branch" 2>&1); merge_rc=$?
    if [ "$merge_rc" -ne 0 ]; then
      if [ -n "$(git -C "$COORD_ROOT" diff --name-only --diff-filter=U)" ]; then
        git -C "$COORD_ROOT" merge --abort 2>/dev/null || true   # abort: base stays green, branch + worktree kept
        clear_inflight; if [ "$stashed" = 1 ]; then git -C "$COORD_ROOT" stash pop --quiet --index 2>/dev/null || echo "merge $raw: warning: stash pop failed — an unrelated staged/modified file is stuck in git stash list; recover it by hand" >&2; fi
        exec 10>&-
        echo "merge $raw: conflict merging $branch into $COORD_BASE — base left clean; resolve in $wt" >&2
        return 2
      fi
      # no unmerged paths: a hook rejected the merge commit, not a conflict — MERGE_HEAD stays, so
      # the marker stays too, the only evidence that lets the retry (after the hook's cause is
      # fixed) tell this wreck is ours and abort it rather than refuse it as a human's.
      if [ "$stashed" = 1 ]; then git -C "$COORD_ROOT" stash pop --quiet --index 2>/dev/null || echo "merge $raw: warning: stash pop failed — an unrelated staged/modified file is stuck in git stash list; recover it by hand" >&2; fi
      exec 10>&-
      echo "merge $raw: land gate failed at local: git merge failed in $COORD_ROOT: $merge_out" >&2
      return 5
    fi
  fi
  clear_inflight

  rm -f "$TICK_FAIL_FILE"
  state=$(tick_box "$raw" "$sym")
  case "$state" in
    missing)
      if [ "$stashed" = 1 ]; then git -C "$COORD_ROOT" stash pop --quiet --index 2>/dev/null || echo "merge $raw: warning: stash pop failed — an unrelated staged/modified file is stuck in git stash list; recover it by hand" >&2; fi
      exec 10>&-
      echo "merge $raw: land gate failed at local: no checkbox line for $raw in $TODO_PATH on $COORD_BASE" >&2
      return 5 ;;
    failed)
      if [ "$stashed" = 1 ]; then git -C "$COORD_ROOT" stash pop --quiet --index 2>/dev/null || echo "merge $raw: warning: stash pop failed — an unrelated staged/modified file is stuck in git stash list; recover it by hand" >&2; fi
      exec 10>&-
      echo "merge $raw: land gate failed at local: tick commit for $raw was rejected in $COORD_ROOT: $(cat "$TICK_FAIL_FILE" 2>/dev/null)" >&2
      return 5 ;;
  esac
  if [ "$stashed" = 1 ]; then git -C "$COORD_ROOT" stash pop --quiet --index 2>/dev/null || echo "merge $raw: warning: stash pop failed — an unrelated staged/modified file is stuck in git stash list; recover it by hand" >&2; fi

  # Cleanup stays inside MERGE_LOCK — see the two-repository case's comment on why (a racing
  # second caller's fork/ancestor check must never see this branch half-landed, half-deleted).
  wt_rc=0; br_rc=0
  remove_worktree "$COORD_ROOT" "$wt" "merge $raw" || wt_rc=$?
  git -C "$COORD_ROOT" branch -d "$branch" >/dev/null 2>&1 || br_rc=$?
  exec 10>&-
  if [ "$wt_rc" -eq 0 ] && [ "$br_rc" -eq 0 ]; then
    echo "merge $raw: merged to $COORD_BASE; worktree + branch cleaned"
  else
    echo "merge $raw: merged to $COORD_BASE; cleanup incomplete (worktree rc=$wt_rc branch rc=$br_rc) — remove $wt and branch $branch by hand"
  fi
  return 0
}

# two-repository case: code lands on TARGET_BASE first, then the box lands on COORD_BASE — two writes, one
# MERGE_LOCK, fixed order. Land-gate tests 0/1 run first, against the target worktree, outside the
# lock; tests 2/3 (already-landed) and 4 (quiet_checkout) run inside it, immediately before each of
# the two merges — 2/3 must not act on a stale pre-lock read of $TB against a racing second merge call. $twt is
# the path the agent itself holds (claim's own stdout, unchanged since) — the agent is never told
# the coordination path, so it is never asked for one; $wt (the coordination worktree, for its
# `.owner`-derived timing credit and its own removal) is the caller's, derived from the branch.
merge_two_repos() {
  local raw=$1 n=$2 wt=$3 twt=$4 branch=$5 sym=$6 fork=${7:-}
  local reason head survivors ok cand s state mb merge_out merge_rc owner untracked already_landed
  local wt_rc br_rc co_out

  if [ ! -d "$twt" ]; then
    echo "merge $raw: land gate failed at local: $twt no longer exists" >&2
    return 5
  fi

  # coordination claim-branch guard: it is a claim, not a carrier — no commit beyond its fork point.
  mb=$(git -C "$COORD_ROOT" merge-base "$COORD_BASE" "$branch") || {
    echo "merge $raw: land gate failed at local: no merge base for $branch on $COORD_BASE" >&2; return 5
  }
  if [ "$(git -C "$COORD_ROOT" rev-parse "$branch")" != "$mb" ]; then
    echo "merge $raw: land gate failed at local: coordination claim branch $branch carries a commit beyond its fork point — it is a claim, not a carrier" >&2
    return 5
  fi

  # test 0: symbolic-ref on $twt is one of target_branches_for_id's survivors.
  git -C "$TARGET_ROOT" rev-parse -q --verify "$TB" >/dev/null 2>&1 || {
    echo "merge $raw: land gate failed at local: $TB does not exist — the target base branch is gone" >&2; return 5
  }
  s=$(git -C "$twt" symbolic-ref --short -q HEAD 2>/dev/null || true)
  survivors=$(target_branches_for_id "$n")
  ok=0
  while IFS= read -r cand; do [ -n "$cand" ] && [ "$cand" = "$s" ] && ok=1; done <<< "$survivors"
  if [ "$ok" != 1 ]; then
    owner=$(branch_owner_id "$s") || owner=""
    if [ -n "$owner" ]; then
      echo "merge $raw: land gate failed at local: $twt is on branch $s, which is $owner's target branch, not $n's" >&2
    else
      echo "merge $raw: land gate failed at local: $twt is on branch ${s:-<detached>}, not one of $n's target branches" >&2
    fi
    return 5
  fi

  # test 1: no uncommitted change to a tracked file; untracked files warn, never refuse.
  if [ -n "$(git -C "$twt" status --porcelain --untracked-files=no)" ]; then
    echo "merge $raw: land gate failed at local: $twt carries an uncommitted change to a tracked file — commit it first" >&2
    return 5
  fi
  untracked=$(git -C "$twt" ls-files --others --exclude-standard)
  [ -n "$untracked" ] && printf 'merge %s: untracked files in %s (left as-is, not blocking):\n%s\n' "$raw" "$twt" "$untracked" >&2

  exec 10>"$MERGE_LOCK"; "$FLOCK_BIN" 10

  # $twt can vanish between the pre-lock existence test above and taking this lock — a racing
  # second caller for the same id whose teardown ran while we queued. The box, not the path, then
  # decides the outcome: a symbol already on it is another caller's landing, claimed here as
  # already-landed; still `[ ]` is the same refusal the pre-lock test would have given.
  if [ ! -d "$twt" ]; then
    if box_checked_on_base "$raw"; then
      MERGE_ALREADY_LANDED=1
      exec 10>&-
      echo "merge $raw: already landed ($n) to $TARGET_BASE — box already carries a symbol on $COORD_BASE"
      return 0
    fi
    exec 10>&-
    echo "merge $raw: land gate failed at local: $twt no longer exists" >&2
    return 5
  fi

  # the checkbox line's existence is a gate, decided before anything is merged — under MERGE_LOCK
  # nothing else can add or remove it before the tick later on, so a refusal here never leaves the
  # task's code on the target base with no box to tick and no retry that can ever succeed.
  if ! box_symbol_on_base "$raw" >/dev/null; then
    exec 10>&-
    echo "merge $raw: land gate failed at local: no checkbox line for $raw in $TODO_PATH on $COORD_BASE" >&2
    return 5
  fi

  # test 2/3: already on base (skip the code merge), else must carry real change against it. Run
  # inside MERGE_LOCK — a racing second merge call must not act on a stale pre-lock read of $TB.
  # A first pass of SHA equality against the recorded fork point catches the branch that
  # never moved at all — a distinct commit with an empty tree (an --allow-empty one) still counts
  # as work and reaches the merge below, where a content-diff test alone would misread it. `fork`
  # empty (no repository, or an older .owner with no fork point) skips this precise pass. The content-diff fallback
  # below is still safe unconditionally: it only runs once is-ancestor has already ruled out
  # "already landed by a prior attempt" (that path takes the `already_landed=1` branch instead),
  # so it is left to catch W2's shape — real, distinct commits (a revert dance) whose net content
  # against TB nets to nothing without ever becoming TB's own ancestor.
  head=$(git -C "$twt" rev-parse HEAD)
  already_landed=0
  if [ -n "$fork" ] && [ "$head" = "$fork" ]; then
    exec 10>&-
    echo "merge $raw: land gate failed at local: $twt carries no change against $TARGET_BASE (diff $TARGET_BASE...HEAD is empty) — commit your work first" >&2
    return 5
  fi
  if git -C "$twt" merge-base --is-ancestor "$head" "$TB"; then
    already_landed=1
  elif git -C "$twt" diff --quiet "$TB...HEAD"; then
    exec 10>&-
    echo "merge $raw: land gate failed at local: $twt carries no change against $TARGET_BASE (diff $TARGET_BASE...HEAD is empty) — commit your work first" >&2
    return 5
  fi

  # test 4 (coordination half): decided before any code lands — a refusal here must never leave
  # the target base holding a code merge the box has nothing to tick against.
  reason=$(quiet_checkout "$COORD_ROOT" todo "$TODO_PATH")
  if [ -n "$reason" ]; then exec 10>&-; echo "merge $raw: land gate failed at local: $COORD_ROOT $reason" >&2; return 5; fi

  if [ "$already_landed" != 1 ]; then
    reason=$(quiet_checkout "$TARGET_ROOT" full)
    if [ -n "$reason" ]; then exec 10>&-; echo "merge $raw: land gate failed at local: $TARGET_ROOT $reason" >&2; return 5; fi
    mark_inflight "$TARGET_ROOT"
    co_out=$(git -C "$TARGET_ROOT" checkout "$TARGET_BASE" 2>&1)
    if [ "$(git -C "$TARGET_ROOT" symbolic-ref --short -q HEAD 2>/dev/null)" != "$TARGET_BASE" ]; then
      clear_inflight; exec 10>&-
      echo "merge $raw: land gate failed at local: $TARGET_ROOT checkout of $TARGET_BASE failed: $co_out" >&2
      return 5
    fi
    merge_out=$(git -C "$TARGET_ROOT" merge --no-ff -m "merge $s" "$s" 2>&1); merge_rc=$?
    if [ "$merge_rc" -ne 0 ]; then
      if [ -n "$(git -C "$TARGET_ROOT" diff --name-only --diff-filter=U)" ]; then
        git -C "$TARGET_ROOT" merge --abort 2>/dev/null || true
        clear_inflight; exec 10>&-
        echo "merge $raw: conflict merging $s into $TARGET_BASE in $TARGET_ROOT — base left clean; resolve in $twt" >&2
        return 2
      fi
      # no unmerged paths: a hook rejected the merge commit, not a conflict — MERGE_HEAD stays
      # (git already auto-merged the trees), so the marker stays too: it is the only evidence that
      # tells the next attempt's quiet_checkout this wreck is ours, not a human's, once the hook's
      # cause is fixed and the retry aborts the leftover MERGE_HEAD.
      exec 10>&-
      echo "merge $raw: land gate failed at local: git merge failed in $TARGET_ROOT: $merge_out" >&2
      return 5
    fi
    clear_inflight
  fi

  # Same stash guard as the single-repository case — the `todo` gate above only demands
  # $TODO_PATH itself be clean, so an unrelated staged/modified file must survive this checkout +
  # merge untouched, restored explicitly on every exit path below (see the single-repository
  # case's comment on why not a RETURN trap).
  local stashed=0
  if [ -n "$(git -C "$COORD_ROOT" status --porcelain --untracked-files=no)" ]; then
    git -C "$COORD_ROOT" stash push --quiet -m "zero-merge-$raw" && stashed=1
  fi

  mark_inflight "$COORD_ROOT"
  co_out=$(git -C "$COORD_ROOT" checkout "$COORD_BASE" 2>&1)
  if [ "$(git -C "$COORD_ROOT" symbolic-ref --short -q HEAD 2>/dev/null)" != "$COORD_BASE" ]; then
    clear_inflight; if [ "$stashed" = 1 ]; then git -C "$COORD_ROOT" stash pop --quiet --index 2>/dev/null || echo "merge $raw: warning: stash pop failed — an unrelated staged/modified file is stuck in git stash list; recover it by hand" >&2; fi
    exec 10>&-
    echo "merge $raw: land gate failed at local: $COORD_ROOT checkout of $COORD_BASE failed: $co_out" >&2
    return 5
  fi
  # the coordination claim branch carries nothing beyond its fork point (guarded above), so this
  # is always "Already up to date" — it exists only to keep the branch an ancestor of base for
  # is_done, the same invariant the single-repository case's real code merge provides by carrying the code itself.
  merge_out=$(git -C "$COORD_ROOT" merge --no-ff -m "merge $branch" "$branch" 2>&1); merge_rc=$?
  if [ "$merge_rc" -ne 0 ]; then
    if [ -n "$(git -C "$COORD_ROOT" diff --name-only --diff-filter=U)" ]; then
      git -C "$COORD_ROOT" merge --abort 2>/dev/null || true
      clear_inflight; if [ "$stashed" = 1 ]; then git -C "$COORD_ROOT" stash pop --quiet --index 2>/dev/null || echo "merge $raw: warning: stash pop failed — an unrelated staged/modified file is stuck in git stash list; recover it by hand" >&2; fi
      exec 10>&-
      echo "merge $raw: conflict merging $branch into $COORD_BASE in $COORD_ROOT" >&2
      return 2
    fi
    if [ "$stashed" = 1 ]; then git -C "$COORD_ROOT" stash pop --quiet --index 2>/dev/null || echo "merge $raw: warning: stash pop failed — an unrelated staged/modified file is stuck in git stash list; recover it by hand" >&2; fi
    exec 10>&-
    echo "merge $raw: land gate failed at local: git merge failed in $COORD_ROOT: $merge_out" >&2
    return 5
  fi
  clear_inflight

  rm -f "$TICK_FAIL_FILE"
  state=$(tick_box "$raw" "$sym")
  case "$state" in
    missing)
      if [ "$stashed" = 1 ]; then git -C "$COORD_ROOT" stash pop --quiet --index 2>/dev/null || echo "merge $raw: warning: stash pop failed — an unrelated staged/modified file is stuck in git stash list; recover it by hand" >&2; fi
      exec 10>&-
      echo "merge $raw: land gate failed at local: no checkbox line for $raw in $TODO_PATH on $COORD_BASE" >&2
      return 5 ;;
    failed)
      if [ "$stashed" = 1 ]; then git -C "$COORD_ROOT" stash pop --quiet --index 2>/dev/null || echo "merge $raw: warning: stash pop failed — an unrelated staged/modified file is stuck in git stash list; recover it by hand" >&2; fi
      exec 10>&-
      echo "merge $raw: land gate failed at local: tick commit for $raw was rejected in $COORD_ROOT: $(cat "$TICK_FAIL_FILE" 2>/dev/null)" >&2
      return 5 ;;
  esac
  if [ "$stashed" = 1 ]; then git -C "$COORD_ROOT" stash pop --quiet --index 2>/dev/null || echo "merge $raw: warning: stash pop failed — an unrelated staged/modified file is stuck in git stash list; recover it by hand" >&2; fi

  # Teardown stays inside MERGE_LOCK — a racing second caller's test 2/3 reads $twt and the
  # target branch by name; releasing the lock before this cleanup lets that caller observe $twt
  # gone (or the branch already deleted) while still outside the lock, so its own pre-lock reads
  # are stale by the time it reads $twt again — it must never see this half-landed, half-torn-down
  # state at all, only "still there" (not yet landed) or "fully gone" (already landed) atomically.
  teardown_target "$twt"
  wt_rc=0; br_rc=0
  remove_worktree "$COORD_ROOT" "$wt" "merge $raw" || wt_rc=$?
  git -C "$COORD_ROOT" branch -d "$branch" >/dev/null 2>&1 || br_rc=$?
  exec 10>&-

  if [ "$wt_rc" -eq 0 ] && [ "$br_rc" -eq 0 ]; then
    echo "merge $raw: merged to $TARGET_BASE in $TARGET_ROOT; box landed on $COORD_BASE; worktrees + branches cleaned"
  else
    echo "merge $raw: merged to $TARGET_BASE in $TARGET_ROOT; box landed on $COORD_BASE; cleanup incomplete (worktree rc=$wt_rc branch rc=$br_rc) — remove $wt and branch $branch by hand"
  fi
  return 0
}

# count of UTF-8 codepoints in $1 — bytes that are not a UTF-8 continuation byte (0x80-0xBF, i.e.
# decimal 128-191) — computed purely from byte values so it never depends on the ambient locale,
# unlike bash's own `${#sym}` (bytes under LC_ALL=C, characters under a UTF-8 one).
glyph_count() {
  printf '%s' "$1" | od -An -v -tu1 | tr -s ' \n' '\n' | awk 'NF && ($1<128 || $1>191){c++} END{print c+0}'
}

# is $1 usable as merge's box symbol: exactly one glyph (which may be several bytes), never a
# space, never `]`. Extracted so a check can assert its verdict rather than copying its source.
symbol_ok() {
  [ "$(glyph_count "$1")" -eq 1 ] && [ "$1" != ' ' ] && [ "$1" != ']' ]
}

# ac_section_bounds <task_file>: prints "<start> <end>" — the 1-based, inclusive line range of
# the body of the first recognized Acceptance Criteria section (ATX/Setext/bold-only heading,
# fenced-code-aware, same grammar check_ac_file documents), excluding the heading line itself.
# Prints nothing when no such section exists. The one place this heading grammar is written —
# check_ac_file and ac_land_gate_findings both call this to find the section, neither
# re-implements heading matching.
ac_section_bounds() {
  awk '
    { lines[NR] = $0 }
    END {
      state = "pre"; fence = 0; sec_start = 0; sec_end = 0
      for (i = 1; i <= NR; i++) {
        line = lines[i]
        if (line ~ /^[ \t]*```/) { fence = !fence; continue }
        if (fence) continue

        t = line
        gsub(/^[ \t]+/, "", t); gsub(/[ \t]+$/, "", t)
        lower = tolower(t)

        is_atx = (t ~ /^#{1,6}[ \t]+/)
        atx_ac = (lower ~ /^#{1,6}[ \t]+acceptance criteria:?[ \t]*#*[ \t]*$/)
        bold_ac = (lower ~ /^\*\*acceptance criteria:?\*\*$/) || (lower ~ /^__acceptance criteria:?__$/)

        is_setext = 0; setext_ac = 0; consumed = 0
        if (!is_atx && t != "" && i < NR) {
          nt = lines[i+1]
          gsub(/^[ \t]+/, "", nt); gsub(/[ \t]+$/, "", nt)
          if (nt ~ /^=+$/ || nt ~ /^-+$/) {
            is_setext = 1; consumed = 1
            if (lower ~ /^acceptance criteria:?$/) setext_ac = 1
          }
        }

        is_heading = is_atx || bold_ac || is_setext
        is_ac = atx_ac || bold_ac || setext_ac

        if (state == "sec" && is_heading) { state = "done"; sec_end = i - 1 }
        else if (state == "pre" && is_ac) { state = "sec"; sec_start = i + (consumed ? 2 : 1) }

        if (consumed) i++
      }
      if (state == "sec") sec_end = NR
      if (sec_start > 0) print sec_start, sec_end
    }
  ' "$1"
}

# ac_land_gate_findings <task_file>: TASK-058f's land-gate check. Uses ac_section_bounds to find
# the Acceptance Criteria section, then within it: prints one `MISSING_GATE<TAB>name` line for
# each of TASK-056's two gate notes not found anywhere in the section (position/interleaving with
# AC lines is unconstrained), and one `MISSING_EVIDENCE<TAB>text` line for every ticked
# (`- [x]`/`- [X]`) criterion whose evidence line — the first following line that is blank, a new
# list item, or `>`-prefixed, skipping the criterion's own wrapped continuation text in between —
# is not a `>`-prefixed line, or is itself one of the two gate-note lines (a gate note can never
# count as a criterion's own evidence — matched by the same anchored prefix as the gate-note
# check, not by a bare `gate:` substring, since an evidence line's own prose may legitimately
# mention "gate" too). Prints nothing when the file has no
# recognized Acceptance Criteria section — that gap belongs to validate_tasks/check_ac_file, not
# this gate.
ac_land_gate_findings() {
  local bounds s e
  bounds=$(ac_section_bounds "$1")
  [ -n "$bounds" ] || return 0
  read -r s e <<< "$bounds"
  awk -v s="$s" -v e="$e" '
    { lines[NR] = $0 }
    END {
      # nothing ticked yet: no real work landed, so neither the gate notes nor any evidence line
      # is due — an untouched Task file (every existing fixture across this suite predating
      # TASK-058f, and a freshly claimed Task no session has started) is never refused by this gate.
      any_ticked = 0
      for (i = s; i <= e; i++) if (lines[i] ~ /^[ \t]*- \[[xX]\]/) any_ticked = 1
      if (!any_ticked) exit 0

      have_ac = 0; have_sr = 0
      for (i = s; i <= e; i++) {
        if (lines[i] ~ /^>[ \t]*Acceptance criteria gate: (passed|failed-manual)/) have_ac = 1
        if (lines[i] ~ /^>[ \t]*Agentic self-review gate: passed/) have_sr = 1
      }
      if (!have_ac) print "MISSING_GATE\tAcceptance criteria gate"
      if (!have_sr) print "MISSING_GATE\tAgentic self-review gate"

      for (i = s; i <= e; i++) {
        if (lines[i] ~ /^[ \t]*- \[[xX]\]/) {
          crit = lines[i]; gsub(/^[ \t]*/, "", crit)
          # a criterion own text may wrap onto further indented lines before its evidence
          # line — skip that continuation text (anything that is not blank, not a new list item,
          # not a quote line) to find the evidence line that actually follows the criterion.
          j = i + 1
          while (j <= e) {
            t2 = lines[j]; gsub(/^[ \t]+/, "", t2); gsub(/[ \t]+$/, "", t2)
            if (t2 == "" || t2 ~ /^[-*+][ \t]/ || t2 ~ /^[0-9]+[.)][ \t]/ || t2 ~ /^>/) break
            j++
          }
          nxt = (j <= e) ? lines[j] : ""
          gsub(/^[ \t]+/, "", nxt)
          # a gate note itself never counts as evidence for a criterion — matched by the same
          # anchored prefix as have_ac/have_sr above, not by a bare gate: substring search (an
          # evidence line own prose may legitimately mention land gate or similar).
          is_gate_note = (nxt ~ /^>[ \t]*Acceptance criteria gate: (passed|failed-manual)/) || (nxt ~ /^>[ \t]*Agentic self-review gate: passed/)
          if (!(nxt ~ /^>/) || is_gate_note) print "MISSING_EVIDENCE\t" crit
        }
      }
    }
  ' "$1"
}

# check_gate_evidence <task_file>: 0 clean; on a gap, echoes ac_land_gate_findings' findings as
# operator-facing text, unprefixed (merge_task/mr_task each add their own "<cmd> $raw: land gate
# failed at local: " prefix), and returns 1.
check_gate_evidence() {
  local kind text rc=0
  while IFS=$'\t' read -r kind text; do
    [ -z "$kind" ] && continue
    case "$kind" in
      MISSING_GATE)     echo "missing gate note: $text"; rc=1 ;;
      MISSING_EVIDENCE) echo "ticked criterion has no evidence line: $text"; rc=1 ;;
    esac
  done < <(ac_land_gate_findings "$1")
  return $rc
}

# task_gate_file <raw_id>: the path check_gate_evidence should read — always raw_id's Task file
# under $COORD_ROOT (resolve_task_ids' own resolution), never a task/coordination worktree's copy.
# A session's tick/note is made "where it resolves" (the algorithm's own exception letting the
# Task file be edited in the main checkout) and commit_ac_checkoff always lands it there too
# (`git -C "$COORD_ROOT" checkout "$COORD_BASE"` then commits) — so $COORD_ROOT already has the
# freshest copy whether the edit is committed yet or not; a task/coordination worktree forked
# before that edit only ever holds a stale pre-tick snapshot. Prints nothing and fails when the id
# is missing/ambiguous — same as resolve_task_ids' own classes, left for the existing checkbox-line
# gate to report.
task_gate_file() {
  local raw=$1 tid tcls trest
  IFS=$'\t' read -r tid tcls trest < <(printf '%s\n' "$raw" | resolve_task_ids)
  [ "$tcls" = ok ] || return 1
  printf '%s' "$trest"
}

# merge <raw_id> <twt> [symbol]: SERIAL across instances (MERGE_LOCK). <twt> is exactly what
# `claim` handed the agent — the target worktree (in the single-repository case that IS the only worktree); the
# coordination worktree, when there is a separate one, is never the agent's to pass, so it is
# always re-derived here from the branch. exit 0 = the task is landed — either this call merged
# the code and ticked the box, worktree(s) + branch(es) cleaned, or it found under MERGE_LOCK that
# another caller already had, and claimed no merge, no tick, no credit; exit 2 = a real conflict
# (human needed), base left clean, branch + worktree kept; exit 5 = the land gate refused (no work,
# borrowed work, uncommitted work, wrong branch, or
# a human's own state) — nothing merged, nothing torn down; exit 6 = not the owning session —
# refused before anything is merged, ticked or torn down. zero.sh is the only writer of the box,
# so there is no "your branch checked the wrong box" case to gate or self-heal here.
# <symbol> (default x) is exactly one glyph, which may be several bytes, not a space and not `]`;
# what it MEANS is the session's business, not zero.sh's — `?` = "landed, needs human review" is
# the convention README names.
merge_task() {
  local raw=$1 twt=$2 sym=${3:-x} n branch wt acq inst fork rc o_pid o_start acf ac_findings acline
  n=$(sanitize_id "$raw"); branch=$(task_branch "$n")
  if ! symbol_ok "$sym"; then
    echo "merge $raw: land gate failed at local: invalid symbol '$sym' — must be exactly one glyph, not a space or ']'" >&2
    return 5
  fi
  wt=$(wt_for_branch "$branch")
  # acquire epoch + instance (lines 3,4 of .owner), read before either landing removes the wt.
  # fork (line 6) is the target branch's recorded fork point, used by merge_two_repos' test 2.
  acq=""; inst=""; fork=""; o_pid=""; o_start=""; if [ -n "$wt" ] && [ -f "$wt/.owner" ]; then { read -r o_pid; read -r o_start; read -r acq; read -r inst; read -r _ || true; read -r fork || fork=""; } < "$wt/.owner" 2>/dev/null || acq=""; fi
  # not your task: someone else's session holds this id (claim_owner is rewritten on every
  # acquire, so lines 1/2 always name whoever currently holds it) — refused before anything is
  # merged, ticked or torn down, under its own exit code so a caller can tell this from a gate
  # failure (exit 5).
  if [ -n "$o_pid" ] && { [ "$o_pid" != "$OWNER_PID" ] || [ "$o_start" != "$OWN_START" ]; }; then
    echo "merge $raw: not your task — instance ${inst:-another session} holds it" >&2
    return 6
  fi

  # land gate: TASK-058f — verify, not merely trust, that raw_id's own Task file carries both
  # TASK-056 gate notes and an evidence line under every ticked Acceptance Criterion, before
  # anything is merged.
  if acf=$(task_gate_file "$raw"); then
    ac_findings=$(check_gate_evidence "$acf")
    if [ -n "$ac_findings" ]; then
      while IFS= read -r acline; do echo "merge $raw: land gate failed at local: $acline" >&2; done <<< "$ac_findings"
      return 5
    fi
  fi

  # set by merge_two_repos when it finds, under MERGE_LOCK, that this id was already landed by
  # another caller — that call claimed no merge and no box tick, so it is credited nothing.
  MERGE_ALREADY_LANDED=0
  if [ "$SAME_REPO" = 1 ]; then
    merge_same_repo "$raw" "$wt" "$branch" "$sym" "$fork"; rc=$?
  else
    merge_two_repos "$raw" "$n" "$wt" "$twt" "$branch" "$sym" "$fork"; rc=$?
  fi

  # merged → credit full elapsed (acquire → now) and one Landed Task to the instance that held
  # it (line4). The branch is deleted right above, so no Task can be counted twice.
  if [ "$rc" -eq 0 ] && [ "$MERGE_ALREADY_LANDED" != 1 ] && [ -n "$acq" ]; then add_todos_time "$(( $(date +%s) - acq ))" "$inst"; fi
  if [ "$rc" -eq 0 ] && [ "$MERGE_ALREADY_LANDED" != 1 ]; then add_todos_done "$inst"; fi
  if [ "$rc" -eq 0 ]; then mark_safe_to_exit; fi
  return $rc
}

# mr-body-path <raw_id> -> deterministic scratch path for that Task's request description
# (the mr prompt's own step writes it there before `mr` runs): $COORD_GITDIR/mr-body/<sanitized id>.md — the
# id grammar admits '/', so a raw-id filename would name a directory that does not exist; the
# sanitizer is the one this protocol already has (sanitize_id), the same stem the branch name is
# built from, not a second mapping. Creates the directory (a no-op once it exists) so the agent's
# own write, right after this call, never fails on a missing parent. No other side effect.
mr_body_path() {
  local dir="$COORD_GITDIR/mr-body"
  mkdir -p "$dir" 2>/dev/null
  printf '%s/%s.md' "$dir" "$(sanitize_id "$1")"
}

# TASK-059e: append the deterministic Kaizero closing line to a request body kaizero.sh is about
# to hand to mr_create — done here, by kaizero.sh itself, rather than asked for in the mr prompt,
# so the line is never at the mercy of whether the session complies. Idempotent against a retry
# over the same bodyfile; a no-op under KAIZERO_NO_CO_AUTHORSHIP.
mr_body_add_closing_line() {
  local bodyfile="$1"
  [ -z "${KAIZERO_NO_CO_AUTHORSHIP:-}" ] || return 0
  grep -qF '🐆 Guided by [Kaizero](https://kaizero.sh)' "$bodyfile" 2>/dev/null && return 0
  printf '\n🐆 Guided by [Kaizero](https://kaizero.sh)\n' >> "$bodyfile"
}

# mr <raw_id> <twt>: SERIAL across instances on the box-landing half only (MERGE_LOCK) — same
# land gate shape as merge_two_repos' tests 0/1 (branch identity, no uncommitted tracked change),
# but no code merge onto $TARGET_BASE: this mode hands the Task off, it does not land it, so the ONLY merge here
# is the coordination claim branch onto $COORD_BASE — proven (below) to carry no commit past its
# fork point, so that merge is always "Already up to date", same as merge_two_repos' own box-side
# merge. The push and the two forge calls (mr_list/mr_create) run OUTSIDE the lock: pushing this
# Task's own exclusive branch, or listing/creating its request, is safe under concurrent callers —
# the forge/git itself serializes them — and holding MERGE_LOCK across a network round-trip would
# stall every other hand off in the fleet on forge latency. On success $twt itself is torn down
# (teardown_target, same call release_task/claim's own failure path use) but its branch is kept —
# the work is not merged yet, and a take-back's own acquire_task lookup reattaches to it, at
# origin's tip, on the next claim.
# exit 0 = pushed & request opened/reused & box ticked `[↑]`, coordination worktree + branch
# cleaned, target worktree torn down (branch kept); exit 2 = should not happen (see the mr prompt);
# exit 5 = the land gate or a forge call refused — nothing handed off; exit 6 = not the owning
# session — refused before anything is pushed, ticked or torn down.
mr_task() {
  local raw=$1 twt=$2 n branch wt acq inst o_pid o_start
  local mb s survivors ok cand owner untracked out existing title bodyfile
  local reason merge_out merge_rc state head already sym url
  local winner w_sha w_base w_state w_url retarget_note
  local acf ac_findings acline

  n=$(sanitize_id "$raw"); branch=$(task_branch "$n")
  wt=$(wt_for_branch "$branch")
  # acquire epoch + instance (lines 3,4 of .owner), read before landing removes the wt.
  acq=""; inst=""; o_pid=""; o_start=""; if [ -n "$wt" ] && [ -f "$wt/.owner" ]; then { read -r o_pid; read -r o_start; read -r acq; read -r inst; } < "$wt/.owner" 2>/dev/null || acq=""; fi
  # not your task — same rule and same code as merge_task's convergence point.
  if [ -n "$o_pid" ] && { [ "$o_pid" != "$OWNER_PID" ] || [ "$o_start" != "$OWN_START" ]; }; then
    echo "mr $raw: not your task — instance ${inst:-another session} holds it" >&2
    return 6
  fi

  # land gate: TASK-058f — identical check as merge_task's, at the identical point in its own flow,
  # before anything is pushed or ticked.
  if acf=$(task_gate_file "$raw"); then
    ac_findings=$(check_gate_evidence "$acf")
    if [ -n "$ac_findings" ]; then
      while IFS= read -r acline; do echo "mr $raw: land gate failed at local: $acline" >&2; done <<< "$ac_findings"
      return 5
    fi
  fi

  if [ ! -d "$twt" ]; then
    echo "mr $raw: land gate failed at local: $twt no longer exists" >&2
    return 5
  fi

  # coordination claim-branch guard: it is a claim, not a carrier — no commit beyond its fork point.
  mb=$(git -C "$COORD_ROOT" merge-base "$COORD_BASE" "$branch") || {
    echo "mr $raw: land gate failed at local: no merge base for $branch on $COORD_BASE" >&2; return 5
  }
  if [ "$(git -C "$COORD_ROOT" rev-parse "$branch")" != "$mb" ]; then
    echo "mr $raw: land gate failed at local: coordination claim branch $branch carries a commit beyond its fork point — it is a claim, not a carrier" >&2
    return 5
  fi

  # test 0: origin/<target base> exists, and $twt's symbolic-ref is one of target_branches_for_id's
  # survivors — same shape as merge_two_repos' test 0, against $TB (origin/$TARGET_BASE here).
  git -C "$twt" rev-parse -q --verify "$TB" >/dev/null 2>&1 || {
    echo "mr $raw: land gate failed at local: origin/$TARGET_BASE does not exist — the target base branch is gone" >&2; return 5
  }
  s=$(git -C "$twt" symbolic-ref --short -q HEAD 2>/dev/null || true)
  survivors=$(target_branches_for_id "$n")
  ok=0
  while IFS= read -r cand; do [ -n "$cand" ] && [ "$cand" = "$s" ] && ok=1; done <<< "$survivors"
  if [ "$ok" != 1 ]; then
    owner=$(branch_owner_id "$s") || owner=""
    if [ -n "$owner" ]; then
      echo "mr $raw: land gate failed at local: $twt is on branch $s, which is $owner's target branch, not $n's" >&2
    else
      echo "mr $raw: land gate failed at local: $twt is on branch ${s:-<detached>}, not one of $n's target branches" >&2
    fi
    return 5
  fi

  # test 1: no uncommitted change to a tracked file; untracked files warn, never refuse.
  if [ -n "$(git -C "$twt" status --porcelain --untracked-files=no)" ]; then
    echo "mr $raw: land gate failed at local: $twt carries an uncommitted change to a tracked file — commit it first" >&2
    return 5
  fi
  # not blocking — but named now, because they will not survive: the teardown below (step 7)
  # removes $twt itself once the push succeeds, taking any untracked file with it.
  untracked=$(git -C "$twt" ls-files --others --exclude-standard)
  [ -n "$untracked" ] && printf 'mr %s: untracked files in %s (removed with the worktree once the push succeeds):\n%s\n' "$raw" "$twt" "$untracked" >&2

  # every refusal purely local state can raise fires here, before step 5's irreversible forge
  # call — the coordination checkout being unusable, and the base carrying no checkbox line for
  # this id, both readable now, both with no URL to name since nothing has been created yet.
  reason=$(quiet_checkout "$COORD_ROOT" todo "$TODO_PATH")
  if [ -n "$reason" ]; then
    echo "mr $raw: land gate failed at local: $COORD_ROOT $reason" >&2
    return 5
  fi
  if ! box_symbol_on_base "$raw" >/dev/null; then
    echo "mr $raw: land gate failed at local: no checkbox line for $raw in $TODO_PATH on $COORD_BASE" >&2
    return 5
  fi

  # test 2/3: already an ancestor of origin/<target base> (step 2 — nothing to review, nothing a
  # forge would accept: skip the body/push/forge steps outright, land [x]) or must carry real,
  # distinct change against it.
  head=$(git -C "$twt" rev-parse HEAD)
  sym='↑'; already=0; url=""
  if git -C "$twt" merge-base --is-ancestor "$head" "$TB"; then
    already=1; sym=x
  elif git -C "$twt" diff --quiet "$TB...HEAD"; then
    echo "mr $raw: land gate failed at local: $twt carries no change against origin/$TARGET_BASE (diff origin/$TARGET_BASE...HEAD is empty) — commit your work first" >&2
    return 5
  fi

  if [ "$already" != 1 ]; then
    # step 3: body gate — precedes the push, unconditionally, even when an open request for this
    # head already exists; neither side derives the name, both ask mr_body_path for it.
    bodyfile=$(mr_body_path "$raw")
    [ -s "$bodyfile" ] || {
      echo "mr $raw: land gate failed at body: $bodyfile is empty — write the description there first" >&2
      return 5
    }
    mr_body_add_closing_line "$bodyfile"

    # step 4: push this Task's own exclusive branch — no force flag, no amend, never a
    # terminal credential prompt.
    if ! out=$(GIT_TERMINAL_PROMPT=0 git -C "$twt" push -u origin HEAD 2>&1); then
      echo "mr $raw: land gate failed at push: $out" >&2
      return 5
    fi

    # step 5: the only place this function creates anything on the remote. mr_list's rows decide
    # reuse by the rule sync_mrs shares (mr_pick): the newest open request wins outright, else
    # the highest number — never a row's position in the list.
    if ! existing=$(mr_list "$s" 2>&1); then
      echo "mr $raw: land gate failed at mr: $existing" >&2
      return 5
    fi
    w_sha=""; w_base=""; w_state=""; w_url=""
    if [ -n "$existing" ]; then
      winner=$(printf '%s\n' "$existing" | mr_pick)
      if [ -n "$winner" ]; then
        w_sha=$(cut -f2 <<< "$winner")
        w_base=$(cut -f3 <<< "$winner"); w_state=$(cut -f4 <<< "$winner")
        w_url=$(cut -f5 <<< "$winner")
      fi
    fi

    retarget_note=""
    if [ "$w_state" = open ]; then
      # no sha test on open — the push above already moved it to this tip. Reused unchanged even
      # retargeted, no rival opened; the hand-off names the base it now points at.
      url=$w_url
      [ "$w_base" = "$TARGET_BASE" ] || retarget_note=" (request now targets $w_base, not $TARGET_BASE)"
    elif [ "$w_state" = merged ] && [ -n "$w_sha" ] && [ "$w_sha" = "$head" ]; then
      url=$w_url
      if [ "$w_base" = "$TARGET_BASE" ]; then sym=x; else sym='?'; fi
    else
      # closed, none, or merged at a different sha (a reopened task's fresh fork under the same
      # branch name — not this work): treated as no live request.
      title="$(todo_title_for_id "$raw")"; title="$raw${title:+ $title}"
      if ! url=$(mr_create "$s" "$title" "$bodyfile" 2>&1); then
        echo "mr $raw: land gate failed at mr: $url" >&2
        return 5
      fi
    fi
  fi

  exec 10>"$MERGE_LOCK"; "$FLOCK_BIN" 10
  # step 6's own copies of the two purely-local refusals above — the race a peer or a human can
  # still spring while this session was pushing/opening the request.
  reason=$(quiet_checkout "$COORD_ROOT" todo "$TODO_PATH")
  if [ -n "$reason" ]; then exec 10>&-; echo "mr $raw: land gate failed at local: $COORD_ROOT $reason" >&2; return 5; fi
  mark_inflight "$COORD_ROOT"
  git -C "$COORD_ROOT" checkout "$COORD_BASE" >/dev/null 2>&1
  # always "Already up to date" — $branch is proven above to carry nothing beyond its fork point.
  merge_out=$(git -C "$COORD_ROOT" merge --no-ff -m "merge $branch" "$branch" 2>&1); merge_rc=$?
  if [ "$merge_rc" -ne 0 ]; then
    if [ -n "$(git -C "$COORD_ROOT" diff --name-only --diff-filter=U)" ]; then
      git -C "$COORD_ROOT" merge --abort 2>/dev/null || true
      clear_inflight; exec 10>&-
      echo "mr $raw: conflict merging $branch into $COORD_BASE in $COORD_ROOT" >&2
      return 2
    fi
    clear_inflight; exec 10>&-
    echo "mr $raw: land gate failed at local: git merge failed in $COORD_ROOT: $merge_out" >&2
    return 5
  fi
  clear_inflight

  rm -f "$TICK_FAIL_FILE"
  state=$(tick_box "$raw" "$sym")
  case "$state" in
    missing)
      exec 10>&-
      # by now the branch is pushed and a request may be open (a human deleted the task line
      # mid-flight) — the URL, when there is one, is the only record the human gets.
      if [ -n "$url" ]; then
        echo "mr $raw: land gate failed at local: no checkbox line for $raw in $TODO_PATH on $COORD_BASE — the request at $url is open and now belongs to nobody; close it, or restore the task line" >&2
      else
        echo "mr $raw: land gate failed at local: no checkbox line for $raw in $TODO_PATH on $COORD_BASE" >&2
      fi
      return 5 ;;
    failed)
      exec 10>&-
      echo "mr $raw: land gate failed at local: tick commit for $raw was rejected in $COORD_ROOT: $(cat "$TICK_FAIL_FILE" 2>/dev/null)" >&2
      return 5 ;;
  esac
  exec 10>&-

  remove_worktree "$COORD_ROOT" "$wt" "mr $raw" || true
  git -C "$COORD_ROOT" branch -d "$branch" >/dev/null 2>&1 || true
  teardown_target "$twt"   # Worktree gone, branch kept in the [↑]/[?] case
  # both [x] routes (step 2's ancestry shortcut, step 5's merged-at-this-tip verdict) leave no
  # branch behind — teardown_target's own ancestry rule already covers the first; a squash or
  # rebase merge means it never covers the second, so this deletes it directly, by the name
  # already resolved for step 5, never by re-reading the now-removed $twt.
  if [ "$sym" = x ]; then git -C "$TARGET_ROOT" branch -D "$s" >/dev/null 2>&1 || true; fi

  # a landing that exits 0 consumes the body file — a later re-entry for the same id refuses at
  # `body` until a fresh description is written, instead of describing the previous attempt.
  [ -n "${bodyfile:-}" ] && rm -f "$bodyfile"

  if [ -n "$acq" ]; then add_todos_time "$(( $(date +%s) - acq ))" "$inst"; fi
  add_todos_done "$inst"
  mark_safe_to_exit

  case "$sym" in
    x)
      if [ "$already" = 1 ]; then
        echo "mr $raw: already in $TARGET_BASE; box landed as [x] on $COORD_BASE; worktrees cleaned"
      else
        echo "mr $raw: $url already merged; box landed as [x] on $COORD_BASE; worktrees cleaned"
      fi ;;
    '?')
      echo "mr $raw: $url merged into $w_base, not $TARGET_BASE; box landed as [?] on $COORD_BASE; worktrees cleaned" ;;
    *)
      echo "mr $raw: $url opened from $s${retarget_note}; box landed as [$sym] on $COORD_BASE; worktrees cleaned" ;;
  esac
  return 0
}

# credit_inflight_time: credit orphaned in-flight worktrees whose owning session has exited (claude
# died/finished mid-Task, work neither merged nor stolen). For each such Task worktree, credit its
# partial work (acquire epoch to newest file mtime) and ADVANCE the anchor to that mtime — so a
# repeat pass adds ~0 and a later steal counts only work beyond this point (no double-count).
# Live-owned worktrees are left alone (self-credit on merge). Called from kaizero.sh's exit paths.
credit_inflight_time() {
  local wt br owner_pid owner_start owner_acq owner_inst owner_twt owner_fork m m2 n line
  credit_one() {
    [ -n "${wt:-}" ] || return 0
    case "${br:-}" in "$COORD_BASE-task-"*) n=${br#"$COORD_BASE"-task-} ;; *) return 0 ;; esac  # Task worktrees only
    [ -f "$wt/.owner" ] || return 0
    exec 7>"$COORD_GITDIR/reclaim-$BR_SLUG-task-$n.lock"          # same lock a steal takes, so no race
    "$FLOCK_BIN" -n 7 || { exec 7>&-; return 0; }                  # a peer is mid-steal on this Task; it credits
    { read -r owner_pid; read -r owner_start; read -r owner_acq; read -r owner_inst; read -r owner_twt || owner_twt=""; read -r owner_fork || owner_fork=""; } < "$wt/.owner" 2>/dev/null || { exec 7>&-; return 0; }
    if ! session_alive "$owner_pid" "$owner_start"; then    # dead owner = orphaned in-flight
      case "${owner_acq:-}" in ''|*[!0-9]*) : ;; *)
        # The dead owner's work may sit in $wt, in its target worktree (line5), or split
        # across both — take the newer of the two mtimes, never just $wt's.
        m=$(newest_mtime "$wt")
        if [ -n "$owner_twt" ] && [ "$owner_twt" != "$wt" ] && [ -d "$owner_twt" ]; then
          m2=$(newest_mtime "$owner_twt")
          [ -n "$m2" ] && { [ -z "$m" ] || [ "$m2" -gt "$m" ]; } && m=$m2
        fi
        # credit to the OWNER instance (line4), not whoever runs the sweep; keep line4 on the anchor
        # advance; line5 (the target worktree) and line6 (the fork point) are carried through untouched.
        [ -n "$m" ] && { add_todos_time "$((m - owner_acq))" "${owner_inst:-}"; printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$owner_pid" "$owner_start" "$m" "${owner_inst:-}" "${owner_twt:-}" "${owner_fork:-}" > "$wt/.owner"; } ;;
      esac
    fi
    exec 7>&-
  }
  wt=""; br=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)          wt=${line#worktree } ;;
      branch\ refs/heads/*) br=${line#branch refs/heads/} ;;
      "")                   credit_one; wt=""; br="" ;;       # blank line ends each porcelain record
    esac
  done < <(git -C "$COORD_ROOT" worktree list --porcelain)
  credit_one   # flush last record if git emitted no trailing blank
}

# escape a Task id into a git-ref-safe branch slug: keep only branch-safe chars, then remove git's
# forbidden ref patterns ('..', trailing '.' or '.lock'); never empty. Called on every N below so no
# unescaped id reaches a branch/worktree/lock name. Distinct ids differing only in escaped chars
# would collide — fine, given ids are unique tokens like SMTH-855 / 7.a. The id -> slug map is
# part of the claim protocol's shared naming, so it must not vary with the launching environment
#: `tr`'s bracket ranges are locale-dependent, and two peers on one coordination point are
# routinely launched under different locales, so the mapping runs under LC_ALL=C regardless.
sanitize_id() {
  local s; s=$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')
  while [ "$s" != "${s//../.}" ]; do s=${s//../.}; done   # collapse '..' runs (forbidden in refs)
  s=${s%.lock}; s=${s%.}                                  # no trailing '.lock' or '.'
  printf '%s' "${s:-x}"
}

# --- deterministic target branch name + id-prefix matching, from the Release Todo List blob alone.
# Foundation only — no worktree/`.owner` side effects. Claim consumes target_branches_for_id's
# survivor set for claim's fork/reattach/refuse decision, the land gate for its own branch
# validation; task_branch above (the single-repo COORD_BASE-task-<id> name) is what
# acquire_task/merge_task actually use until then.

# is <name> claimed by some OTHER, LONGER, sanitized id than <n> among the newline-separated
# <ids> (named exactly that id, or beginning "<id>-")? The one "longest-id-wins" predicate
# target_branch's collision check and target_branches_for_id's candidate-drop both read, so the
# rule lives in one place.
claimed_by_longer_id() {
  local name=$1 n=$2 ids=$3 m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    [ "$m" = "$n" ] && continue
    [ "${#m}" -gt "${#n}" ] || continue
    case "$name" in "$m"|"$m"-*) return 0 ;; esac
  done < <(printf '%s\n' "$ids")
  return 1
}

# target_branch <id> <title> -> `<sanitized id>-<slug>`, the name a fresh fork gets. slug:
# lowercase, every run of non-[a-z0-9] -> one '-', cut to 40 chars, THEN leading/trailing '-'
# trimmed (the cut precedes the trim so it can't leave one); no slug chars -> 'task'. Lowercased
# with `tr`, not bash-4's lowercase parameter expansion (bash 3.2 lacks it). The plain `<id>-<slug>`
# name can collide with a longer sibling id on the same blob (id SMTH-855 titled "API rate
# limiting" beside sibling SMTH-855-api: the naive name is claimed by SMTH-855-api under
# target_branches_for_id's own longest-id-wins rule, so id SMTH-855 would never get it back). Only
# a longer id of the form "<n>-…" can ever claim it (any id that does must share <n>'s first
# len(n) chars, and the boundary char right after must be the same "-" the name uses there —
# algebra any reader can re-derive from the candidate rule below). So on a collision the id/slug
# separator widens ("-", "--", "---", …) until no such sibling id's "<m>-" or "<m>" prefixes the
# result — deterministic over the same blob, so every peer widens it the same way.
target_branch() {
  local id=$1 title=$2 slug n sep full ids
  n=$(sanitize_id "$id")
  slug=$(printf '%s' "$title" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cs 'a-z0-9' '-' | cut -c1-40 | sed -e 's/^-*//' -e 's/-*$//')
  slug=${slug:-task}
  ids=$(todo_ids | sort -u)
  sep='-'
  while :; do
    full="$n$sep$slug"
    claimed_by_longer_id "$full" "$n" "$ids" || break
    sep="-$sep"
  done
  printf '%s' "$full"
}

# count unchecked tasks on the base branch's Release Todo List (fenced example boxes excluded, as
# everywhere) — exposed here so a test can assert against this scan by name, never a re-implementation.
unchecked_todos() {
  git -C "$COORD_ROOT" show "$COORD_BASE:$TODO_PATH" 2>/dev/null | awk '
    /^[ \t]*```/       { fence = !fence; next }
    fence              { next }
    /^[ \t]*- \[ \]/    { n++ }
    END { print n+0 }'
}

# the Release Todo List a zeroing session discovers candidates from — the same committed blob
# every other zero.sh decision reads, never the working tree, so an uncommitted Release Todo List
# edit can never be offered as a claimable Task. Prints checkbox lines VERBATIM (same fence-aware
# filter todo_lines/leg1_ids share), tail only: from two lines before the first unchecked `[ ]` box
# to the end — a Landed non-`x` symbol (`[↑]`, `[⛔]`, `[?]`, ...) never anchors the cut, only the
# same literal `- [ ]` unchecked_todos counts. Fewer than two lines precede it -> from the top. No
# `[ ]` box at all -> nothing. A failed blob read is never silent: stderr is left to reach the
# caller and the pipeline's non-zero status propagates through `set -o pipefail`.
# Every UNCHECKED (`- [ ]`) line whose id resolves to exactly one Task file (via
# resolve_task_ids — reused, never reimplemented) gets that file's $COORD_ROOT-absolute path
# appended. A checked or other-symbol line, or an unchecked id resolving to zero or multiple
# files, prints unchanged — this only ever adds information, never a verdict.
todo_list() {
  local raw
  raw=$(git -C "$COORD_ROOT" show "$COORD_BASE:$TODO_PATH" | awk '
    /^[ \t]*```/ { fence = !fence; next }
    fence        { next }
    /^[ \t]*- \[[^]]+\]/ {
      line[++n] = $0
      if (!cut && $0 ~ /^[ \t]*- \[ \]/) cut = n
    }
    END {
      if (!cut) exit 0
      start = cut - 2; if (start < 1) start = 1
      for (i = start; i <= n; i++) print line[i]
    }')
  [ -n "$raw" ] || return 0

  local ids=() id
  while IFS= read -r id; do ids+=("$id"); done < <(printf '%s\n' "$raw" | awk '
    function unwraplink(s) {
      if (s ~ /^\[[^]]+\]\([^)]+\)$/) { sub(/^\[/, "", s); sub(/\]\(.*$/, "", s) }
      return s
    }
    /^[ \t]*- \[ \]/ {
      line = $0; sub(/^[ \t]*- \[ \][ \t]*/, "", line)
      n = split(line, a, /[ \t]+/)
      print (n > 0 ? unwraplink(a[1]) : "")
    }')

  local ok_path=() j=0 cls p
  if [ "${#ids[@]}" -gt 0 ]; then
    while IFS=$'\t' read -r _ cls p; do
      [ "$cls" = ok ] && ok_path[j]="$p"
      j=$((j+1))
    done < <(printf '%s\n' "${ids[@]}" | resolve_task_ids)
  fi

  j=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-\ \[\ \] ]]; then
      if [ -n "${ok_path[j]:-}" ]; then
        printf '%s  %s\n' "$line" "${ok_path[j]}"
      else
        printf '%s\n' "$line"
      fi
      j=$((j+1))
    else
      printf '%s\n' "$line"
    fi
  done <<<"$raw"
}

# raw id \t title text, one per line, for every checkbox line on the coordination base's Release
# Todo List (fence-aware). todo_ids and todo_title_for_id both build on this one extraction.
todo_lines() {
  git -C "$COORD_ROOT" show "$COORD_BASE:$TODO_PATH" 2>/dev/null | awk '
    # a first token shaped exactly `[label](path)` (no space between `]` and `(`, no nested
    # brackets in label) resolves to its bracketed label as the id — the Quick-Entry markdown
    # link form. Anything else is used unchanged.
    function unwraplink(s) {
      if (s ~ /^\[[^]]+\]\([^)]+\)$/) { sub(/^\[/, "", s); sub(/\]\(.*$/, "", s) }
      return s
    }
    /^[ \t]*```/ { fence = !fence; next }
    fence        { next }
    /^[ \t]*- \[[^]]+\]/ {
      line = $0
      sub(/^[ \t]*- \[[^]]+\][ \t]*/, "", line)
      if (line == "") next
      n = split(line, a, /[ \t]/)
      rest = ""
      for (i = 2; i <= n; i++) rest = rest (i > 2 ? " " : "") a[i]
      printf "%s\t%s\n", unwraplink(a[1]), rest
    }'
}

# sanitized ids of every Task on the Release Todo List blob (checked and unchecked), one per line.
# A branch's id segment is always sanitize_id's output, so target_branches_for_id compares against
# THIS, never the raw first token — a Task id needing escaping (`I6/a`) must resolve the same as
# its already-sanitized form (`I6-a`), the form its own branch actually carries.
todo_ids() {
  todo_lines | while IFS=$'\t' read -r raw _; do printf '%s\n' "$(sanitize_id "$raw")"; done
}

# raw id's title text (the rest of its Task line, after the id) or empty if the id has no Task
# line — acquire_target uses it to name a fresh fork (target_branch's <title> argument).
todo_title_for_id() {
  local id=$1 n rawtok rest; n=$(sanitize_id "$id")
  while IFS=$'\t' read -r rawtok rest; do
    [ "$(sanitize_id "$rawtok")" = "$n" ] && { printf '%s' "$rest"; return 0; }
  done < <(todo_lines)
}

# target_branches_for_id <id> -> existing branches in $TARGET_ROOT that are this Task's, one per
# line (0, 1, or 2+ — fork/reattach/refuse is the caller's call). A branch is a
# candidate when it is named exactly the sanitized id or begins "<id>-"; what follows may itself
# contain '/', so candidates come from every local branch (git for-each-ref's own refname globbing
# stops a bare '*' at a '/', which would silently drop a candidate like `<id>-foo/bar` — README's
# adoption promise needs the match done in bash's `case`, whose '*' does not stop there), then
# longest-id-wins: drop a candidate that ALSO is, or begins "<m>-" for, some OTHER, LONGER,
# sanitized id `m` anywhere on the Release Todo List (checked and unchecked) — Task `7`'s prefix
# catches Task `7-1`'s branch too, and `7-1` is the longer, more specific owner.
target_branches_for_id() {
  local id=$1 n cand ids
  n=$(sanitize_id "$id")
  ids=$(todo_ids | sort -u)
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    case "$cand" in "$n"|"$n"-*) ;; *) continue ;; esac
    claimed_by_longer_id "$cand" "$n" "$ids" || printf '%s\n' "$cand"
  done < <(git -C "$TARGET_ROOT" for-each-ref --format='%(refname:short)' refs/heads/)
  return 0   # a scan that finds nothing has succeeded — errexit callers may assign it plainly
}

# origin_branches_for_id <id> -> this Task's branches that exist on origin, one per line (0, 1, or
# 2+ — acquire_task's call). Same candidate filter and longest-id-wins tie-break
# target_branches_for_id applies to refs/heads/, applied here to one `ls-remote --heads` listing
# instead — a single round trip works against a target cloned `--single-branch` or `--depth N`
# alike, since it asks the remote directly rather than reading any locally cached ref. This result
# never feeds target_branches_for_id's own local survivor scan, and that scan never widens to
# read origin's refs either — the two lookups stay separate. A network failure is the exit status
# alone (nonzero return here, never a parsed message): the only "origin unreachable" signal on this
# path, so a translated git's own wording never enters the decision.
origin_branches_for_id() {
  local id=$1 n cand ids out line
  n=$(sanitize_id "$id")
  out=$(git -C "$TARGET_ROOT" ls-remote --heads origin 2>/dev/null) || return 1
  ids=$(todo_ids | sort -u)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cand=${line#*refs/heads/}
    case "$cand" in "$n"|"$n"-*) ;; *) continue ;; esac
    claimed_by_longer_id "$cand" "$n" "$ids" || printf '%s\n' "$cand"
  done <<< "$out"
  return 0
}

# is the RAW Task id's box Landed (any single non-space character) on the BASE branch's Release
# Todo List? A
# checkbox line is `^[ \t]*- [ ]` (or any other box, which may hold a multi-byte symbol); the id is the first whitespace token
# after the box (same rule the agent uses), so no id-regex escaping. Anchoring to the line-start
# box ignores any [x]/[ ] inside Task text.
box_checked_on_base() {
  git -C "$COORD_ROOT" show "$COORD_BASE:$TODO_PATH" 2>/dev/null | awk -v id="$1" '
    function unwraplink(s) {
      if (s ~ /^\[[^]]+\]\([^)]+\)$/) { sub(/^\[/, "", s); sub(/\]\(.*$/, "", s) }
      return s
    }
    /^[ \t]*```/ { fence = !fence; next }   # ignore checkboxes inside fenced code blocks (examples)
    fence        { next }
    /^[ \t]*- \[[^]]+\]/ {
      line = $0
      sub(/^[ \t]*- \[/, "", line)                  # drop prefix up to and incl "["
      match(line, /^[^]]+\]/)
      box  = substr(line, 1, RLENGTH - 1)            # " " or the landed symbol
      line = substr(line, RLENGTH + 1); sub(/^[ \t]*/, "", line)   # drop "<box>] " → leaves id + rest
      split(line, a, /[ \t]/)
      if (unwraplink(a[1]) == id && box != " ") { found=1; exit }
    }
    END { exit found ? 0 : 1 }'
}

# which symbol the RAW Task id's box holds on the BASE branch's Release Todo List —
# box_checked_on_base answers Landed-or-not, this answers WHICH symbol (space included), which
# sync_mrs needs to tell merged from declined. Prints the symbol itself, or nothing if the id
# has no Task line. Same fenced, box-aware scan as its neighbour above, over the same widened
# grammar.
box_symbol_on_base() {
  git -C "$COORD_ROOT" show "$COORD_BASE:$TODO_PATH" 2>/dev/null | awk -v id="$1" '
    function unwraplink(s) {
      if (s ~ /^\[[^]]+\]\([^)]+\)$/) { sub(/^\[/, "", s); sub(/\]\(.*$/, "", s) }
      return s
    }
    /^[ \t]*```/ { fence = !fence; next }
    fence        { next }
    /^[ \t]*- \[[^]]+\]/ {
      line = $0
      sub(/^[ \t]*- \[/, "", line)
      match(line, /^[^]]+\]/)
      box  = substr(line, 1, RLENGTH - 1)
      line = substr(line, RLENGTH + 1); sub(/^[ \t]*/, "", line)
      split(line, a, /[ \t]/)
      if (unwraplink(a[1]) == id) { print box; f=1; exit }
    }
    END { exit f ? 0 : 1 }'
}

# is_done: deterministic "has this Task already LANDED on the base branch?" — exit 0 = Landed (safe
# to release/skip), exit 1 = Unlanded (own it, drive+merge it). Given the RAW Task id. Authoritative
# signal is the base box: zero.sh is the only writer of the box, so a base landed box can only come
# from THIS Task's branch actually merging. A worktree whose merge failed/aborted leaves base at
# [ ] = Unlanded. If a wt is passed and still exists, also assert its tip is an ancestor of base —
# catches a still-unmerged wt reached through the rescue path while the box was marked by hand.
is_done() {
  local raw=$1 wt=${2:-} head
  box_checked_on_base "$raw" || return 1
  [ -n "$wt" ] && head=$(git -C "$wt" rev-parse -q HEAD 2>/dev/null) || return 0  # no/gone wt: base [x] settles it
  git -C "$COORD_ROOT" merge-base --is-ancestor "$head" "$COORD_BASE"
}

# ids of Tasks live peers hold right now, one per line — same scan kaizero.sh's own
# held_todos() does (live .owner pid + start-time match, current session marker names this
# Task), but emitting the ids themselves rather than a bare count: a signature needs to notice
# Task X's holder dying even when the total held COUNT stays identical (a different peer claims
# something else in the same tick).
held_ids() {
  local path branch id pid st cur
  while IFS=$'\t' read -r path branch; do
    case "$branch" in "$COORD_BASE-task-"*) id=${branch#"$COORD_BASE"-task-} ;; *) continue ;; esac
    [ -f "$path/.owner" ] || continue
    { read -r pid; read -r st; } < "$path/.owner" 2>/dev/null || continue
    kill -0 "$pid" 2>/dev/null || continue
    [ "$(proc_start "$pid")" = "$st" ] || continue
    cur=""
    if [ -f "$SESSION_DIR/$pid" ]; then { read -r _; read -r cur; } < "$SESSION_DIR/$pid" 2>/dev/null || cur=""; fi
    [ "$cur" = "$id" ] && printf '%s\n' "$id"
  done < <(git -C "$COORD_ROOT" worktree list --porcelain | awk '
    /^worktree /            { p = substr($0, 10) }
    /^branch refs\/heads\// { printf "%s\t%s\n", p, substr($0, 19) }')
}

# deterministic signature for "what would have to change before a retry could possibly claim
# something": the Release Todo List blob's own SHA (changes the instant any box flips or any Task
# text changes) plus the sorted set of ids peers currently hold. Single source of truth, computed
# here rather than by the LLM, so kaizero.sh's wait can compare it without reimplementing
# the scan.
no_claim_signature() {
  printf '%s %s\n' \
    "$(git -C "$COORD_ROOT" rev-parse "$COORD_BASE:$TODO_PATH" 2>/dev/null)" \
    "$(held_ids | sort | tr '\n' ,)"
}

# no-claim-mark: record "nothing was claimable at this signature" for THIS instance (keyed by
# KAIZERO_INSTANCE, not the owner pid — the marker outlives this session's Stop-hook restart),
# so kaizero.sh can skip relaunching until the signature changes. Atomic publish (temp+rename,
# same idiom as add_counter): the shell may read this file without a lock.
no_claim_mark() {
  # mark_safe_to_exit chained with && — only a persisted no-claim marker actually
  # confirms nothing claimable; a failed write must not tell the Stop hook it is safe to end.
  no_claim_signature > "$COORD_GITDIR/no-claim-$INSTANCE_ID.tmp" && mv -f "$COORD_GITDIR/no-claim-$INSTANCE_ID.tmp" "$COORD_GITDIR/no-claim-$INSTANCE_ID" && mark_safe_to_exit
}

# --- Task id validation, deterministic, run by the shell instead of by the prompt --------------
TASK_ID_PATTERN_DEFAULT='^[A-Za-z0-9._/-]*[0-9][A-Za-z0-9._/-]*$'

# leg 1 — ids on the CURRENT base version. Tab-separated records to stdout:
#   missing-id\t<id-or-(none)>\t<path:line>\t<raw line>
#   PATFAIL\t<id>                                          (follows its own missing-id record)
#   duplicate-id\t<id>\t<path:line>\t<raw line>             (one record per offending line)
leg1_ids() {
  local pattern="${KAIZERO_TASK_ID_PATTERN:-$TASK_ID_PATTERN_DEFAULT}"
  git -C "$COORD_ROOT" show "$COORD_BASE:$TODO_PATH" 2>/dev/null | PAT="$pattern" awk -v path="$TODO_PATH" '
    # pattern reaches awk via ENVIRON (never -v — that decodes backslash escapes) so an operator
    # ERE with `\.` in it reaches the matcher byte-for-byte.
    BEGIN { pat = ENVIRON["PAT"] }
    function checkpat(id) { if (pat == ".") return 1; return (id ~ pat) }
    # a first token shaped exactly `[label](path)` (no space between `]` and `(`, no nested
    # brackets in label) resolves to its bracketed label as the id — the Quick-Entry markdown
    # link form. Anything else is used unchanged.
    function unwraplink(s) {
      if (s ~ /^\[[^]]+\]\([^)]+\)$/) { sub(/^\[/, "", s); sub(/\]\(.*$/, "", s) }
      return s
    }
    # same claim-identity fold sanitize_id (kaizero.sh) applies to a raw id before it ever
    # becomes a branch/worktree/lock name: non branch-safe chars -> "-", ".." runs collapsed,
    # a trailing ".lock"/"." dropped, empty -> "x" — then case-folded, since a fleet spans
    # filesystems that alias two refs differing only in case onto one file.
    function ident(s,   r) {
      r = s
      gsub(/[^A-Za-z0-9._-]/, "-", r)
      while (r ~ /\.\./) gsub(/\.\./, ".", r)
      sub(/\.lock$/, "", r)
      sub(/\.$/, "", r)
      if (r == "") r = "x"
      return tolower(r)
    }
    /^[ \t]*```/ { fence = !fence; next }
    fence { next }
    /^[ \t]*- \[[^]]+\]/ {
      raw = $0; line = raw
      sub(/^[ \t]*- \[[^]]+\][ \t]*/, "", line)
      if (line == "") { printf "missing-id\t(none)\t%s:%d\t%s\n", path, FNR, raw; next }
      n = split(line, a, /[ \t]+/); id = unwraplink(a[1])
      if (!checkpat(id)) {
        printf "missing-id\t%s\t%s:%d\t%s\n", id, path, FNR, raw
        printf "PATFAIL\t%s\n", id
        next
      }
      cid = ident(id)
      cnt[cid]++; k++; taskid[k] = id; taskline[k] = FNR; taskraw[k] = raw; taskcid[k] = cid
    }
    END {
      for (i = 1; i <= k; i++) {
        if (cnt[taskcid[i]] > 1) printf "duplicate-id\t%s\t%s:%s\t%s\n", taskid[i], path, taskline[i], taskraw[i]
      }
    }'
}

# leg 2 — ids across EVERY historical version of TODO_PATH on COORD_BASE (what leg 1 can never
# see). Feeds one big "@@V sha / blob / @@E" stream to a single awk pass that walks versions
# oldest-first, keeping only the immediately-previous version's id→text map. Tab-separated:
#   duplicate-id-history\t<id>\t<sha>
#   reused-id-gap\t<id>\t<sha-since>\t<sha-back>\t<was-text>\t<now-text>
#   reused-id-inplace\t<id>\t<sha>\t<was-text>\t<now-text>
leg2_ids() {
  local sha fname line shas=() fnames=() i
  # git answers only one of --follow and --reverse in one invocation, silently, so oldest-first
  # order is produced here rather than asked of git. --name-only alongside --follow: a rename
  # means the blob for an old version lives under its OLD path, not $TODO_PATH, so each version
  # is read back by the path git names for that same commit rather than by today's path.
  while IFS= read -r line; do
    case "$line" in
      '@@SHA '*) sha=${line#@@SHA } ;;
      '') : ;;
      *) fname=$line; shas+=("$sha"); fnames+=("$fname") ;;
    esac
  done < <(git -C "$COORD_ROOT" log --follow --name-only --format='@@SHA %H' "$COORD_BASE" -- "$TODO_PATH" 2>/dev/null)
  for (( i = ${#shas[@]} - 1; i >= 0; i-- )); do
    printf '@@V %s\n' "${shas[i]}"
    git -C "$COORD_ROOT" show "${shas[i]}:${fnames[i]}" 2>/dev/null
    printf '@@E\n'
  done | awk '
    function w(s,   t) { t = tolower(s); gsub(/[^a-z0-9]/, "", t); return t }
    # a first token shaped exactly `[label](path)` (no space between `]` and `(`, no nested
    # brackets in label) resolves to its bracketed label as the id — the Quick-Entry markdown
    # link form. Anything else is used unchanged.
    function unwraplink(s) {
      if (s ~ /^\[[^]]+\]\([^)]+\)$/) { sub(/^\[/, "", s); sub(/\]\(.*$/, "", s) }
      return s
    }
    # same claim-identity fold leg 1 uses, so a rename that only changes case or swaps `/` for
    # `-` is tracked as one id across versions, not two.
    function ident(s,   r) {
      r = s
      gsub(/[^A-Za-z0-9._-]/, "-", r)
      while (r ~ /\.\./) gsub(/\.\./, ".", r)
      sub(/\.lock$/, "", r)
      sub(/\.$/, "", r)
      if (r == "") r = "x"
      return tolower(r)
    }
    /^@@V / { sha = $2; fence = 0; delete cur; delete curcount; delete rawcur; next }
    /^@@E$/ {
      # buffered, not printed here: the newest version walked is the current file, whose own
      # collision is leg 1 duplicate-id to report — repeating it here would point the operator
      # at rewriting history instead of the one-line edit leg 1 already names. Emitted in END,
      # once it is known which ids are still duplicated in the LAST version walked.
      for (id in curcount) {
        if (curcount[id] > 1 && !dupdone[id]) {
          dupn++; dupid[dupn] = id; duprawid[dupn] = rawcur[id]; dupsha[dupn] = sha; dupdone[id] = 1
        }
      }
      delete finalcount
      for (id in curcount) finalcount[id] = curcount[id]
      for (id in prevmap) {
        if (!(id in cur) && !(id in absentsha)) { absentsha[id] = sha; absentwas[id] = prevmap[id] }
      }
      for (id in cur) {
        if (id in absentsha) {
          if (cur[id] != absentwas[id] && !gapdone[id]) {
            printf "reused-id-gap\t%s\t%s\t%s\t%s\t%s\n", rawcur[id], absentsha[id], sha, absentwas[id], cur[id]
            gapdone[id] = 1
          }
          delete absentsha[id]; delete absentwas[id]
        } else if (id in prevmap && cur[id] != prevmap[id]) {
          delete pw
          pn = split(prevmap[id], pa, /[ \t]+/)
          for (i = 1; i <= pn; i++) { sw = w(pa[i]); if (sw != "") pw[sw] = 1 }
          shared = 0
          cn = split(cur[id], ca, /[ \t]+/)
          for (i = 1; i <= cn; i++) { sw = w(ca[i]); if (sw != "" && (sw in pw)) shared = 1 }
          # ponytail: word-overlap heuristic, no real semantic diff — an in-place rewrite that
          # happens to keep one shared word (even a stopword) reads as an edit, not a reuse.
          # Upgrade to a text-similarity score if that false-negative rate ever matters.
          if (!shared && !inplacedone[id]) {
            printf "reused-id-inplace\t%s\t%s\t%s\t%s\n", rawcur[id], sha, prevmap[id], cur[id]
            inplacedone[id] = 1
          }
        }
      }
      delete prevmap
      for (id in cur) prevmap[id] = cur[id]
      next
    }
    /^[ \t]*```/ { fence = !fence; next }
    fence { next }
    /^[ \t]*- \[[^]]+\]/ {
      line = $0
      sub(/^[ \t]*- \[[^]]+\][ \t]*/, "", line)
      if (line == "") next
      n = split(line, a, /[ \t]+/); id = ident(unwraplink(a[1]))
      rest = ""
      for (i = 2; i <= n; i++) rest = rest (i > 2 ? " " : "") a[i]
      cur[id] = rest; curcount[id]++; rawcur[id] = unwraplink(a[1])
    }
    END {
      for (i = 1; i <= dupn; i++) {
        id = dupid[i]
        if (!(id in finalcount) || finalcount[id] <= 1) printf "duplicate-id-history\t%s\t%s\n", duprawid[i], dupsha[i]
      }
    }'
}

# render one leg1/leg2 tab-record into the operator-facing text (the UX section). Splits
# by hand (not `read`, whose extra fields all land on the LAST var) so a raw Task line or Task
# text that itself contains a literal tab is never truncated — it is always the last field taken.
fmt_finding() {
  local rec="$1" cls
  cls="${rec%%$'\t'*}"; rec="${rec#*$'\t'}"
  case "$cls" in
    missing-id|duplicate-id)
      local id loc raw
      id="${rec%%$'\t'*}"; rec="${rec#*$'\t'}"
      loc="${rec%%$'\t'*}"; raw="${rec#*$'\t'}"
      printf '%s %s: %s  %s\n' "$cls" "$id" "$loc" "$raw" ;;
    PATFAIL)
      printf '    first token `%s` does not match KAIZERO_TASK_ID_PATTERN\n' "$rec" ;;
    duplicate-id-history)
      printf 'duplicate-id-history %s: %s\n' "${rec%%$'\t'*}" "${rec#*$'\t'}" ;;
    reused-id-gap)
      local id since back was now
      id="${rec%%$'\t'*}"; rec="${rec#*$'\t'}"
      since="${rec%%$'\t'*}"; rec="${rec#*$'\t'}"
      back="${rec%%$'\t'*}"; rec="${rec#*$'\t'}"
      was="${rec%%$'\t'*}"; now="${rec#*$'\t'}"
      printf 'reused-id-gap %s: absent since %s, back at %s with different text\n' "$id" "$since" "$back"
      printf '    was: %s\n    now: %s\n' "$was" "$now" ;;
    reused-id-inplace)
      local id sha was now
      id="${rec%%$'\t'*}"; rec="${rec#*$'\t'}"
      sha="${rec%%$'\t'*}"; rec="${rec#*$'\t'}"
      was="${rec%%$'\t'*}"; now="${rec#*$'\t'}"
      printf 'reused-id-inplace %s: changed at %s sharing no word with previous text\n' "$id" "$sha"
      printf '    was: %s\n    now: %s\n' "$was" "$now" ;;
    orphaned-id)
      printf 'orphaned-id %s: held by a live session, no task line on the base carries it\n' "$rec" ;;
    history-incomplete)
      printf 'history-incomplete (none): shallow or grafted repository — unshallow it, or set\n'
      printf '    KAIZERO_ID_HISTORY=0 to check the current file only\n' ;;
  esac
}

# leg 3 — live state, not a version of the file: an id a live session currently holds
# (`held_ids`, already sanitized/case-preserved the way a branch name is) that no task line of
# the CURRENT base version maps to that same sanitize_id identity. No commit SHA pins this, so
# it is evaluated on every run, cache hit or not.
leg3_orphaned() {
  local current_ids held id found
  current_ids=$(git -C "$COORD_ROOT" show "$COORD_BASE:$TODO_PATH" 2>/dev/null | awk '
    # a first token shaped exactly `[label](path)` (no space between `]` and `(`, no nested
    # brackets in label) resolves to its bracketed label as the id — the Quick-Entry markdown
    # link form. Anything else is used unchanged.
    function unwraplink(s) {
      if (s ~ /^\[[^]]+\]\([^)]+\)$/) { sub(/^\[/, "", s); sub(/\]\(.*$/, "", s) }
      return s
    }
    /^[ \t]*```/ { fence = !fence; next }
    fence { next }
    /^[ \t]*- \[[^]]+\]/ {
      line = $0
      sub(/^[ \t]*- \[[^]]+\][ \t]*/, "", line)
      if (line == "") next
      n = split(line, a, /[ \t]+/)
      print unwraplink(a[1])
    }')
  while IFS= read -r held; do
    [ -n "$held" ] || continue
    found=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      [ "$(sanitize_id "$id")" = "$held" ] && { found=1; break; }
    done <<< "$current_ids"
    [ "$found" = 1 ] || printf 'orphaned-id\t%s\n' "$held"
  done < <(held_ids)
}

# leg 2's completeness precondition: a shallow or grafted history cannot be walked in full, so
# every leg-2 class would silently under-report rather than answer honestly.
history_incomplete() {
  local grafts
  [ "$(git -C "$COORD_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ] && return 0
  grafts=$(git -C "$COORD_ROOT" rev-parse --git-path info/grafts 2>/dev/null || true)
  [ -n "$grafts" ] && [ -s "$grafts" ] && return 0
  return 1
}

# validate-ids: exit 0 = clean, nothing printed; exit 1 = at least one finding, on stderr, one
# class per line via fmt_finding. Cached on the Release Todo List blob's newest SHA (temp+rename, same
# atomic-publish idiom as no_claim_mark) so a clean repeat run at the same SHA costs one
# `git rev-list` and walks nothing. A failing run writes no cache — re-checked every cycle.
validate_ids() {
  local pattern cachekey cachefile newsha found=0 line
  pattern="${KAIZERO_TASK_ID_PATTERN:-$TASK_ID_PATTERN_DEFAULT}"
  # cache identity is every input the file-reading legs' answer depends on: two todo files on
  # one base, or one file under two patterns, must never share a clean verdict.
  cachekey=$(printf '%s\x1e%s\x1e%s\n' "$COORD_BASE" "$TODO_PATH" "$pattern" | cksum | awk '{print $1}')
  cachefile="$COORD_GITDIR/todo-ids-ok-$cachekey"
  newsha=$(git -C "$COORD_ROOT" rev-list -1 "$COORD_BASE" -- "$TODO_PATH" 2>/dev/null || true)
  if [ -n "$newsha" ] && [ -f "$cachefile" ] && [ "$(cat "$cachefile" 2>/dev/null || true)" = "$newsha" ]; then
    :   # cache hit: skip the file-reading legs, but leg 3 (live state) still runs below
  else
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      fmt_finding "$line" >&2
      found=1
    done < <(leg1_ids)
    if [ "${KAIZERO_ID_HISTORY:-1}" != 0 ]; then
      if history_incomplete; then
        fmt_finding "history-incomplete" >&2
        found=1
      else
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          fmt_finding "$line" >&2
          found=1
        done < <(leg2_ids)
      fi
    fi
    # cache only a run that actually walked BOTH legs clean — an ID_HISTORY=0 run, or one over
    # an incomplete history, proves nothing about history, so it must never mark a SHA clean for
    # a later default-history run to trust. The temp name carries $$: a fleet launches its
    # instances at once and every one of them lands here in the same second, so a shared name
    # means one wins the rename and the losers' `mv` finds nothing — which `set -euo pipefail`
    # above turns into a failed validate-ids and a refused launch. `|| true` on top: the cache is
    # an optimization, never a reason to fail a run.
    if [ "$found" = 0 ] && [ "${KAIZERO_ID_HISTORY:-1}" != 0 ]; then
      { printf '%s\n' "$newsha" > "$cachefile.tmp.$$" && mv -f "$cachefile.tmp.$$" "$cachefile"; } || rm -f "$cachefile.tmp.$$" || true
    fi
  fi
  # leg 3 — live state, no commit SHA pins it, so no cache hit ever skips it.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fmt_finding "$line" >&2
    found=1
  done < <(leg3_orphaned)
  [ "$found" = 0 ]
}

# canon: lowercase, collapse every run of non-alphanumeric characters to a single '-', trim
# leading/trailing '-'. Same idiom target_branch()'s slug uses (tr, not bash-4 parameter-expansion
# lowercasing — bash 3.2 lacks it), minus its cut -c1-40 truncation (wrong here: two long ids
# could collide if truncated to a shared prefix).
canon() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -e 's/^-*//' -e 's/-*$//'
}

# every unchecked id in todo-list's own tail, in its own walk order — validate_tasks resolves
# exactly this set, never the checked/other-symbol lines the tail also carries for context.
unchecked_tail_ids() {
  todo_list | awk '
    # a first token shaped exactly `[label](path)` (no space between `]` and `(`, no nested
    # brackets in label) resolves to its bracketed label as the id — the Quick-Entry markdown
    # link form. Anything else is used unchanged.
    function unwraplink(s) {
      if (s ~ /^\[[^]]+\]\([^)]+\)$/) { sub(/^\[/, "", s); sub(/\]\(.*$/, "", s) }
      return s
    }
    /^[ \t]*- \[ \]/ {
      line = $0; sub(/^[ \t]*- \[ \][ \t]*/, "", line)
      if (line == "") next
      n = split(line, a, /[ \t]+/); print unwraplink(a[1])
    }'
}

# resolve_task_ids: reads raw ids on stdin, one per line; for each, in the SAME order, prints
# one TSV line: <id>\t<ok|missing|ambiguous>\t<path1>[\x1f<path2>...]. One shared `find` per 200
# ids (ARG_MAX headroom, never a hard limit) over $COORD_ROOT alone — a Task file living only
# under $TARGET_ROOT is unresolvable by design (two-repo mode), and a batch's result set is
# unioned before any id's own canon() check runs, so batching stays exactly equivalent to
# resolving one id at a time.
resolve_task_ids() {
  local ids=() id
  while IFS= read -r id; do [ -n "$id" ] && ids+=("$id"); done
  local n=${#ids[@]}
  [ "$n" -gt 0 ] || return 0

  local all_paths=() seen=$'\n' batch=200 start=0 end i g first clauses p
  while [ "$start" -lt "$n" ]; do
    end=$(( start + batch )); [ "$end" -gt "$n" ] && end=$n
    clauses=(); first=1
    for (( i = start; i < end; i++ )); do
      # find's own coarse prefilter: lowercase, each run of non-alphanumeric chars -> '*', no
      # leading '*' so a basename must literally start with the id. Never the authority — every
      # candidate still goes through the exact canon() check below.
      g=$(printf '%s' "${ids[i]}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '*')
      if [ "$first" = 1 ]; then clauses+=(-iname "$g*.md"); first=0
      else clauses+=(-o -iname "$g*.md"); fi
    done
    # a path can satisfy a clause in more than one batch (e.g. id 2's loose glob and id 201's own
    # both matching the same task file) — deduped on insert (same seen-set idiom claimable_ids uses for
    # ids) so one real file is never counted as two matches for the same id.
    while IFS= read -r -d '' p; do
      case "$seen" in *$'\n'"$p"$'\n'*) continue ;; esac
      all_paths+=("$p"); seen="${seen}${p}"$'\n'
    done < <(
      find "$COORD_ROOT" -type f -not -path '*/.git/*' \( "${clauses[@]}" \) -print0 2>/dev/null
    )
    start=$end
  done

  local all_cbase=() base
  for p in "${all_paths[@]+"${all_paths[@]}"}"; do
    base="${p##*/}"; base="${base%.[Mm][Dd]}"
    all_cbase+=("$(canon "$base")")
  done

  local cid cbase match matches joined
  for id in "${ids[@]}"; do
    cid=$(canon "$id")
    matches=()
    for (( i = 0; i < ${#all_paths[@]}; i++ )); do
      cbase="${all_cbase[i]}"
      match=0
      if [ "$cbase" = "$cid" ]; then match=1
      else case "$cbase" in "$cid-"*) match=1 ;; esac; fi
      [ "$match" = 1 ] && matches+=("${all_paths[i]}")
    done
    case "${#matches[@]}" in
      0) printf '%s\tmissing\t\n' "$id" ;;
      1) printf '%s\tok\t%s\n' "$id" "${matches[0]}" ;;
      *)
        joined="${matches[0]}"
        for (( i = 1; i < ${#matches[@]}; i++ )); do joined="$joined"$'\x1f'"${matches[i]}"; done
        printf '%s\tambiguous\t%s\n' "$id" "$joined" ;;
    esac
  done
}

# check_ac_file: exit 0 when $1 has a recognized Acceptance Criteria heading — ATX (any level
# 1-6, optional trailing #s), Setext (text line + = or - underline), or a bold-only pseudo-heading
# (**...**/__...__) — each tolerating an optional trailing ':', followed by at least one
# `- [ ]`/`- [x]` line before the next heading of any of those three forms or EOF. Fenced code
# blocks are skipped entirely, so an example heading inside a code sample never false-positives.
# Italic-only emphasis and raw HTML headings are deliberately out of the supported grammar. Bold
# is recognized only as the exact "Acceptance criteria" pseudo-heading, never generically, so an
# unrelated bold-wrapped body line (e.g. "**Rule: ...**") can't be mistaken for the next heading
# and falsely close the section.
check_ac_file() {
  local bounds s e
  bounds=$(ac_section_bounds "$1")
  [ -n "$bounds" ] || return 1
  read -r s e <<< "$bounds"
  awk -v s="$s" -v e="$e" '
    { lines[NR] = $0 }
    END {
      fence = 0; has_cb = 0
      for (i = 1; i <= e; i++) {
        line = lines[i]
        if (line ~ /^[ \t]*```/) { fence = !fence; continue }
        if (fence) continue
        if (i >= s && line ~ /^[ \t]*- \[[ xX]\]/) has_cb = 1
      }
      exit has_cb ? 0 : 1
    }
  ' "$1"
}

# relative to $COORD_ROOT when under it (the UX's own display form); unchanged otherwise.
relpath() {
  case "$1" in
    "$COORD_ROOT"/*) printf '%s' "${1#"$COORD_ROOT"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# render one resolve_task_ids/check_ac_file finding into the operator-facing text (the UX
# section) — same house style as fmt_finding.
fmt_task_finding() {
  local rec="$1" cls id rest p out parts i
  cls="${rec%%$'\t'*}"; rec="${rec#*$'\t'}"
  case "$cls" in
    missing-task-file)
      printf 'missing-task-file %s: no file under the coordination tree resolves to this id — add one with a\n  checkboxed ### Acceptance criteria section\n' "$rec" ;;
    empty-acceptance-criteria)
      id="${rec%%$'\t'*}"; p="${rec#*$'\t'}"
      printf 'empty-acceptance-criteria %s: %s has no checkboxed Acceptance Criteria\n' "$id" "$(relpath "$p")" ;;
    ambiguous-task-file)
      id="${rec%%$'\t'*}"; rest="${rec#*$'\t'}"
      parts=(); IFS=$'\x1f' read -ra parts <<< "$rest"
      out=""
      for (( i = 0; i < ${#parts[@]}; i++ )); do
        out="${out:+$out, }$(relpath "${parts[i]}")"
      done
      printf 'ambiguous-task-file %s: %s — rename or remove all but one\n' "$id" "$out" ;;
  esac
}

# validate-tasks: exit 0 = clean, nothing printed; exit 1 = at least one unresolved unchecked id,
# on stderr, one line per finding via fmt_task_finding, capped at the first 5 in walk order plus
# a trailing "… and N more" past that. Separate from validate_ids on purpose: each
# keeps its own exit code and finding vocabulary. No cache — find reads the real filesystem so a
# gitignored Task directory stays resolvable, and an uncommitted edit must be caught every run.
validate_tasks() {
  local id id2 cls paths findings=() total cap=5 shown i ids=()
  while IFS= read -r id; do [ -n "$id" ] && ids+=("$id"); done < <(unchecked_tail_ids)
  if [ "${#ids[@]}" -gt 0 ]; then
    while IFS=$'\t' read -r id2 cls paths; do
      case "$cls" in
        missing)   findings+=("missing-task-file"$'\t'"$id2") ;;
        ambiguous) findings+=("ambiguous-task-file"$'\t'"$id2"$'\t'"$paths") ;;
        ok)        check_ac_file "$paths" || findings+=("empty-acceptance-criteria"$'\t'"$id2"$'\t'"$paths") ;;
      esac
    done < <(printf '%s\n' "${ids[@]}" | resolve_task_ids)
  fi
  total=${#findings[@]}
  shown=$total; [ "$shown" -gt "$cap" ] && shown=$cap
  for (( i = 0; i < shown; i++ )); do fmt_task_finding "${findings[i]}" >&2; done
  [ "$total" -le "$cap" ] || printf '… and %s more\n' "$(( total - cap ))" >&2
  [ "$total" = 0 ]
}

case "${1:-}" in
  claim)   ensure_owner; claim_task "$2" ;;
  release) ensure_owner; release_task "$(sanitize_id "$2")" "${3:-}" ;;
  merge)   ensure_owner
           [ "$MR_MODE" = 1 ] && { echo "merge $2: this fleet runs MR mode; land with 'zero.sh mr' instead" >&2; exit 5; }
           merge_task "$2" "$3" "${4:-}" && set_current none || exit $? ;;  # clear only on success
  mr)      ensure_owner
           [ "$MR_MODE" = 0 ] && { echo "mr $2: this fleet does not run MR mode; land with 'zero.sh merge' instead" >&2; exit 5; }
           mr_task "$2" "$3" && set_current none || exit $? ;;              # clear only on success
  mr-body-path)           mr_body_path "$2" ;;
  done)    is_done "$2" "${3:-}" ;;
  credit_inflight_time)   credit_inflight_time ;;
  commit_ac_checkoff)     commit_ac_checkoff "$2" ;;
  no-claim-mark)          no_claim_mark ;;
  no-claim-signature)     no_claim_signature ;;
  validate-ids)           validate_ids ;;
  validate-tasks)         validate_tasks ;;
  todo-list)              todo_list ;;
  unchecked-todos)        unchecked_todos ;;
  target-branch)          target_branch "$2" "$3" ;;
  target-branches-for-id) target_branches_for_id "$2" ;;
  box-symbol-on-base)     box_symbol_on_base "$2" ;;
  sync-mrs)               sync_mrs ;;
  *) echo "usage: zero.sh {claim N | release N [WT] | merge N WT [symbol] | mr N WT | mr-body-path N | done N [WT] | credit_inflight_time | commit_ac_checkoff N | no-claim-mark | no-claim-signature | validate-ids | validate-tasks | todo-list | unchecked-todos | target-branch ID TITLE | target-branches-for-id ID | box-symbol-on-base ID | sync-mrs}" >&2; exit 64 ;;
esac
ZERO_EOF
    } > "$gitdir/zero.sh"
    chmod +x "$gitdir/zero.sh"
    printf '%sWrote %s/zero.sh (base %s)\n' "$(icon)" "$gitdir" "$COORD_BASE" >&2
}

# inject_marker VAR MARKER VALUE — replaces every literal occurrence of MARKER in the named
# variable VAR with VALUE, byte for byte. `${var//pat/repl}` is NOT this: bash's own pattern-
# substitution reinterprets `&` (whole-match backreference, unescaped) and collapses `\\` in the
# replacement text, and the two behave differently again between bash 3.2 (stock macOS) and 5.2+ —
# an operator's `&`-bearing repository path or a `-t` prompt with a backslash would splice or drop
# text depending on which bash ran it. Plain concatenation (`%%`/`#*` slicing, `+=`) never
# re-interprets its operands, so it reproduces MARKER's value literally on every bash from the
# floor up.
inject_marker() {
    local __var=$1 __marker=$2 __value=$3
    local __content __result __chunk
    __content="${!__var}"
    __result=""
    while [[ "$__content" == *"$__marker"* ]]; do
        __chunk="${__content%%"$__marker"*}"
        __result="$__result$__chunk$__value"
        __content="${__content#*"$__marker"}"
    done
    __result="$__result$__content"
    printf -v "$__var" '%s' "$__result"
}

build_zero_prompt() {
    local todo="$1" taskprompt="$2"
    local gitdir; gitdir="$(cd "$(git rev-parse --git-dir)" && pwd)"
    write_zero_sh "$todo"

    # single-quoted heredoc keeps $wt/backticks literal; markers below are injected via
    # inject_marker, not bash's own pattern-replace (see its comment for why).
    # `read -d ''` not `$(cat <<EOF)`: bash 3.2 (stock macOS) cannot parse a heredoc inside a
    # command substitution. It exits 1 at EOF, hence `|| :`.
    local prompt
    IFS= read -r -d '' prompt <<'PROMPT_EOF' || :
You are ONE of many independent Claude instances zeroing Tasks from @@TODO_ABS@@ in PARALLEL.
This session zeroes at most ONE Task and then ends; the shell starts the next session.
Keep these facts in mind:

  • Coordination is via git alone: a branch = a claim, an flock = the rescue mutex.
  • Peers may hold other Tasks at the same time — that is expected. Never assume you are alone.
  • Every Bash call starts fresh at cwd — the target's main checkout — which resets after each
    call. Call zero.sh by its absolute path, @@ZERO_SH@@, and do all worktree work as
    `cd "$wt" && …` in a SINGLE command.

=== ALGORITHM (one Task, then end your turn) ===
1. FIND candidate Tasks: run `@@ZERO_SH@@ todo-list`. It prints the tail of the Release Todo List,
   from the two lines before the first Unlanded Task to the end. Tasks are GitHub-style Markdown
   checkboxes, one per line, each carrying an id as the FIRST whitespace-delimited token after the
   checkbox:
       - [ ] SMTH-855 some Task Unlanded /repo/tasks/SMTH-855.md  ← UNCHECKED = still to do
       - [x] 7.a some Task already Landed         ← CHECKED   = Landed, skip it
       - [?] 9 some Task Landed, needs review     ← any other symbol = Landed, not yours to claim
   That first token is the task_id (e.g. SMTH-855, 7, 7.a, [BUG-5348](tasks/...)). An UNCHECKED line ending in a path
   names that id's already-resolved Task file — Read it explicitly, with Read, before judging or
   claiming that candidate; it is that Task's full body, not the one-line summary before it. An
   UNCHECKED line with no appended path has no resolved Task file: there is nothing to judge or
   implement for it — skip it, do not judge its independence or attempt to claim it; try the next
   one.
       non-zero exit → STOP IMMEDIATELY: print `@@ZERO_SH@@ todo-list`'s stderr verbatim as the
                        reason and end your turn without claiming anything.
2. For each candidate task_id, in order:
   a. INDEPENDENCE — decide by EVIDENCE from the Task body, never from its title,
      id, or position in the list:
      i.   READ THE FULL LINE/BODY of this Task (not the one-line summary). If the line ends in
           a path, that path IS the full body — Read it explicitly as this step's first action.
           If it is truncated in your view, expand it before judging.
      ii.  A blocking dependency exists ONLY IF this Task CONSUMES an artifact that
           some *unchecked* Task PRODUCES — a named file, function, fixture, finding
           class, prompt, gate, tag, or exit code. Direction is inbound only:
           "this Task needs X's output". Being depended-ON by others does NOT block.
      iii. For EACH unchecked Task, you must be able to quote the span in THIS Task's
           body that names that Task's output. No quotable reference → no edge →
           treat as independent for that pair. Title similarity, adjacency, or "same
           area" is NOT evidence.
      iv.  A prerequisite whose box is anything but `[ ]` never blocks — its code is merged, its
           output exists (a `[?]` is Landed code awaiting review, not missing code).
      - Any inbound edge to an unchecked Task → skip to the next task_id.
      - No such edge (every claimed edge is either to a checked Task or unquotable)
        → continue to step b.
   b. CLAIM: wt=$(@@ZERO_SH@@ claim task_id)
      - exit 2 or 7 → STOP IMMEDIATELY: print stderr verbatim as the reason and end your turn
        without claiming anything. Exit 2 is a bad id — it threatens the whole tail's
        branch-naming scheme, a human edits @@TODO_ABS@@ to fix it. Exit 7 is `ensure_owner`'s
        own FATAL — this process cannot establish ownership of anything right now, so retrying
        with a different task_id will not help.
      - any other nonzero (not 2 or 7) → not yours (a peer owns it, it is being rescued, a peer
        already Landed it, or this task_id's own Task file failed validation) → skip to the next
        task_id. The reason is printed on stderr.
      - exit 0   → you OWN task_id; its git worktree is at $wt. Continue to step c.
   c. IMPLEMENT task_id. Your cwd is the target's main checkout — read it, never edit or build
      there; every build, test and commit runs as `cd "$wt" && …`. The Release Todo List is
      @@TODO_ABS@@, read-only — never edit it, in `$wt` or anywhere; zero.sh ticks its box itself,
      in step d; paths a Task line names (a Task file) resolve against its directory. Stay on the
      branch `$wt` was handed to you on — never `checkout`, `switch` or `checkout -b` there.
      task_id's Task file is the one exception to "never edit or build there": tick and note it
      where it resolves, even when that is the checkout your cwd is in, and commit only through
      `commit_ac_checkoff`, below — every other edit still belongs in `$wt`.
      task_id's Task file's Acceptance Criteria define Landed for this Task — they may span
      files the Task title never mentions: satisfy each and tick it there (`[ ]`→`[x]`) as you
      land it, never ahead of verifying it.
      Scope every edit to task_id only; never touch another Task.
      Implement task_id directly in the current session, or delegate to a fork
      subagent (Agent tool, subagent_type "fork") — working through its
      Acceptance Criteria one at a time. For each remaining criterion, decide
      what it touches, then: implement it directly; delegate one fork subagent
      scoped to only that criterion; or, when two or more remaining criteria
      touch disjoint files — no shared interface, name, or invariant either one
      depends on the other settling first — delegate them in parallel instead of
      one at a time: before creating new sub-worktrees, check for any
      `<task_id>-sub-*` worktree left behind by an earlier, killed attempt at
      this step — continue that criterion's work inside it directly rather than
      starting fresh or discarding it, merging it back into $wt's branch only
      once that work is done. Otherwise, give each criterion its own git
      worktree branched off $wt's current branch (`git -C "$wt" worktree add -b
      <task_id>-sub-<label> <path> <branch>`), scoped to exactly the files that
      criterion needs, and forbidden from touching the Task file or running
      `commit_ac_checkoff` — only you do that, after consolidation. Once every
      parallel fork in that batch reports done, merge each sub-branch back into
      $wt's branch one at a time (`git -C "$wt" merge --no-ff <sub-branch>`),
      resolving any conflict before the next merge, then delete the
      sub-worktrees and sub-branches. Tick and commit each criterion's checkoff
      yourself as you go, never batching several criteria into one checkoff. Do
      not parallelize criteria that only look independent: if settling one
      changes what the other should do, they're one unit of work for one agent,
      not two racing to guess each other's choice.
      Implement task_id per your setup's own implementation-method rule
      (CLAUDE.md, project docs, skill instructions). If that rule requires proof
      before code (e.g. failing test first), produce that proof first, confirm
      it fails for right reason, THEN implement. Respect the possible
      alterations below. After each tick, below the ticked
      criterion, add one evidence line explaining why the criterion is satisfied:
      > YYYY-MM-DD HH:MM±HHMM <short evidence>
      and commit that checkoff: `@@ZERO_SH@@ commit_ac_checkoff task_id`.
      ACCEPTANCE CRITERIA GATE — hand your diff to a subagent that answers two questions separately:
      (1) is every Acceptance Criterion ticked? (2) is every ticked criterion has evidence line and
      really passing (don't run tests, static code analysis only)?
      A criterion that cannot be checked off automatically — it names a human action, an account,
      a token, a manual install — does not have to be ticked: it fails the gate as failed-manual.
      Any other negative answer besides failed-manual: go back to implementing, then run this gate
      again. Only after the subagent's answers are in hand, write the note as instructed below.
      AGENTIC SELF-REVIEW GATE — review your own diff through the review/verify gate your setup defines;
      if your setup defines none, run your own default /code-review skill procedure at minimal effort.
      Fix what it reports, then review the fixed diff again, repeating until a pass reports no new findings.
      Only after that clean pass's output is in hand, write the note as instructed below.
      Each note is your own gate's record, never a human's review of your work. Both live in one quote
      block at the end of the Task file's Acceptance criteria section, one line per gate, each rewritten
      in place when you re-run that gate, passed|failed|failed-manual depending on that gate's own
      outcome:
      > Acceptance criteria gate: passed|failed|failed-manual YYYY-MM-DD HH:MM±HHMM
      > Agentic self-review gate: passed|failed YYYY-MM-DD HH:MM±HHMM
      Do not leave this step before both gates passed. After gates passed commit the notes with:
      `@@ZERO_SH@@ commit_ac_checkoff task_id`.@@TASKPROMPT@@
   d. MERGE: `@@ZERO_SH@@ merge task_id "$wt" [symbol]` — pass a symbol only when this session's
      instructions define one for how the Task ended (e.g. `?` = Landed, needs human review);
      otherwise pass nothing and the box becomes `[x]`. The symbol is one character, never a space.
      - exit 0 → Landed; zero.sh's last stdout line says where → your one Task is zeroed: report
        that line and END YOUR TURN. Do not claim a second Task.
      - exit 5 → do what stderr says, retry once, then stop.
      - exit 2 → a CODE CONFLICT: stderr names the repository and worktree to resolve it in —
        merge that repository's base into the worktree stderr names, resolve, commit, retry
        `@@ZERO_SH@@ merge task_id "$wt" [symbol]` ONCE; if stderr names no worktree you hold,
        STOP IMMEDIATELY and report instead of guessing; if it fails again, MERGE FAILED: STOP
        IMMEDIATELY — report task_id, its worktree $wt and its branch
        (`git -C "$wt" symbolic-ref --short HEAD`), and ask the human to "resolve the conflict on
        that branch, then merge by hand".
3. End your turn — after zeroing one Task, or after walking the whole Release Todo List without
   claiming one (say which happened). If you walked the whole list and claimed nothing, run
   `@@ZERO_SH@@ no-claim-mark` first — it lets the shell wait for that block to clear instead of
   spending a fresh session on the same judgment. If `@@ZERO_SH@@ todo-list` now prints nothing —
   every Task has a Landed box (checked or any other symbol) — announce "ALL TASKS LANDED" first. What runs next is the shell's call: it starts a fresh session for the
   next Task, waits while peers hold everything or the remainder is dependency-blocked, or prints
   the closing report.
PROMPT_EOF
    prompt=${prompt%$'\n'}          # read keeps the final newline; $(cat) stripped it
    inject_marker prompt '@@TODO_ABS@@' "$COORD_ROOT/$todo"
    inject_marker prompt '@@ZERO_SH@@' "$gitdir/zero.sh"
    local tp_chunk=""
    [ -n "$taskprompt" ] && tp_chunk=$'\n      '"$taskprompt"
    inject_marker prompt '@@TASKPROMPT@@' "$tp_chunk"
    printf '%s\n' "$prompt"
}

# MR mode's own prompt: a sibling of build_zero_prompt, not a patched copy of it. Repeats steps 1,
# 2.a, 2.b, 2.c and 3 unchanged; differs only in step 1's legend, step 2.a.iv's inversion, a new
# forge-specific step d, and step e (`zero.sh mr`, no symbol, exit-2 read as a stop). $FORGE is
# resolved by main() before this runs, so the session reads only its own forge's wording —
# never a sentence about the forge it is not on.
build_mr_prompt() {
    local todo="$1" taskprompt="$2"
    local gitdir; gitdir="$(cd "$(git rev-parse --git-dir)" && pwd)"
    write_zero_sh "$todo"

    local step_d req
    if [ "$FORGE" = glab ]; then
        req='merge request'
        IFS= read -r -d '' step_d <<'STEPD_EOF' || :
   d. DESCRIBE: write the merge request description for task_id to the file
      `@@ZERO_SH@@ mr-body-path task_id` prints — run it, use that exact path, do not build one yourself.
      First look for a merge request template **in your task worktree $wt** — not in the target's main
      checkout, which is the operator's and may sit on any branch — and FOLLOW ITS STRUCTURE — keep its
      headings, its checklists and the order they come in, fill every section it asks for, and delete
      none of them. Look, in this order, for:
        .gitlab/merge_request_templates/*.md  ← a directory of templates: Default.md if it is there,
                                                else the one that fits this Task
        .gitlab/merge_request_template.md
      (names are case-insensitive; the first file found wins). No template in the repository → write the
      description yourself: what the Task was, what changed, how you verified it, quoting the Task line.
STEPD_EOF
    else
        req='pull request'
        IFS= read -r -d '' step_d <<'STEPD_EOF' || :
   d. DESCRIBE: write the pull request description for task_id to the file
      `@@ZERO_SH@@ mr-body-path task_id` prints — run it, use that exact path, do not build one yourself.
      First look for a pull request template **in your task worktree $wt** — not in the target's main
      checkout, which is the operator's and may sit on any branch — and FOLLOW ITS STRUCTURE — keep its
      headings, its checklists and the order they come in, fill every section it asks for, and delete
      none of them. Look, in this order, for:
        .github/PULL_REQUEST_TEMPLATE.md, .github/pull_request_template.md,
        PULL_REQUEST_TEMPLATE.md, docs/PULL_REQUEST_TEMPLATE.md,
        .github/PULL_REQUEST_TEMPLATE/*.md  ← a directory of templates: pick the one that fits this Task
      (names are case-insensitive; the first file found wins). No template in the repository → write the
      description yourself: what the Task was, what changed, how you verified it, quoting the Task line.
STEPD_EOF
    fi
    step_d=${step_d%$'\n'}

    local prompt
    IFS= read -r -d '' prompt <<'PROMPT_EOF' || :
You are ONE of many independent Claude instances zeroing Tasks from @@TODO_ABS@@ in PARALLEL.
This session zeroes at most ONE Task and then ends; the shell starts the next session.
Keep these facts in mind:

  • Coordination is via git alone: a branch = a claim, an flock = the rescue mutex.
  • Peers may hold other Tasks at the same time — that is expected. Never assume you are alone.
  • Every Bash call starts fresh at cwd — the target's main checkout — which resets after each
    call. Call zero.sh by its absolute path, @@ZERO_SH@@, and do all worktree work as
    `cd "$wt" && …` in a SINGLE command.

=== ALGORITHM (one Task, then end your turn) ===
1. FIND candidate Tasks: run `@@ZERO_SH@@ todo-list`. It prints the tail of the Release Todo List,
   from the two lines before the first Unlanded Task to the end. Tasks are GitHub-style Markdown
   checkboxes, one per line, each carrying an id as the FIRST whitespace-delimited token after the
   checkbox:
       - [ ] SMTH-855 some Task Unlanded /repo/tasks/SMTH-855.md  ← UNCHECKED = still to do
       - [x] 7.a some Task already Landed         ← CHECKED   = Landed, skip it
       - [↑] 3 some Task under review              ← already spoken for, not yours to claim
       - [⛔] 5 some Task declined                  ← already spoken for, not yours to claim
       - [?] 9 some Task, needs review              ← any other symbol = already spoken for, not yours to claim
   That first token is the task_id (e.g. SMTH-855, 7, 7.a, [BUG-5348](tasks/...)). An UNCHECKED line ending in a path
   names that id's already-resolved Task file — Read it explicitly, with Read, before judging or
   claiming that candidate; it is that Task's full body, not the one-line summary before it. An
   UNCHECKED line with no appended path has no resolved Task file: there is nothing to judge or
   implement for it — skip it, do not judge its independence or attempt to claim it; try the next
   one.
       non-zero exit → STOP IMMEDIATELY: print `@@ZERO_SH@@ todo-list`'s stderr verbatim as the
                        reason and end your turn without claiming anything.
2. For each candidate task_id, in order:
   a. INDEPENDENCE — decide by EVIDENCE from the Task body, never from its title,
      id, or position in the list:
      i.   READ THE FULL LINE/BODY of this Task (not the one-line summary). If the line ends in
           a path, that path IS the full body — Read it explicitly as this step's first action.
           If it is truncated in your view, expand it before judging.
      ii.  A blocking dependency exists ONLY IF this Task CONSUMES an artifact that
           some Task whose box is not `[x]` PRODUCES — a named file, function, fixture, finding
           class, prompt, gate, tag, or exit code. Direction is inbound only:
           "this Task needs X's output". Being depended-ON by others does NOT block.
      iii. For EACH Task whose box is not `[x]`, you must be able to quote the span in THIS
           Task's body that names that Task's output. No quotable reference → no edge →
           treat as independent for that pair. Title similarity, adjacency, or "same
           area" is NOT evidence.
      iv.  Only `[x]` unblocks: that Task's code is in the base your worktree was forked from.
           `[ ]` (not started), `[↑]` (in review, not merged yet), `[⛔]` (declined) and `[?]`
           (needs a human) — and any other symbol — are all NOT in the base yet: an inbound edge
           to any of them blocks this Task. Skip it and try the next id.
      - Any inbound edge to a Task whose box is not `[x]` → skip to the next task_id.
      - No such edge (every claimed edge is either to an `[x]` Task or unquotable)
        → continue to step b.
   b. CLAIM: wt=$(@@ZERO_SH@@ claim task_id)
      - exit 2 or 7 → STOP IMMEDIATELY: print stderr verbatim as the reason and end your turn
        without claiming anything. Exit 2 is a bad id — it threatens the whole tail's
        branch-naming scheme, a human edits @@TODO_ABS@@ to fix it. Exit 7 is `ensure_owner`'s
        own FATAL — this process cannot establish ownership of anything right now, so retrying
        with a different task_id will not help.
      - any other nonzero (not 2 or 7) → not yours (a peer owns it, it is being rescued, a peer
        already Landed it, or this task_id's own Task file failed validation) → skip to the next
        task_id. The reason is printed on stderr.
      - exit 0   → you OWN task_id; its git worktree is at $wt. Continue to step c.
   c. IMPLEMENT task_id. Your cwd is the target's main checkout — read it, never edit or build
      there; every build, test and commit runs as `cd "$wt" && …`. The Release Todo List is
      @@TODO_ABS@@, read-only — never edit it, in `$wt` or anywhere; zero.sh ticks its box itself,
      in step e; paths a Task line names (a Task file) resolve against its directory. Stay on the
      branch `$wt` was handed to you on — never `checkout`, `switch` or `checkout -b` there.
      task_id's Task file is the one exception to "never edit or build there": tick and note it
      where it resolves, even when that is the checkout your cwd is in, and commit only through
      `commit_ac_checkoff`, below — every other edit still belongs in `$wt`.
      task_id's Task file's Acceptance Criteria define Landed for this Task — they may span
      files the Task title never mentions: satisfy each and tick it there (`[ ]`→`[x]`) as you
      land it, never ahead of verifying it.
      Scope every edit to task_id only; never touch another Task.
      Implement task_id directly in the current session, or delegate to a fork
      subagent (Agent tool, subagent_type "fork") — working through its
      Acceptance Criteria one at a time. For each remaining criterion, decide
      what it touches, then: implement it directly; delegate one fork subagent
      scoped to only that criterion; or, when two or more remaining criteria
      touch disjoint files — no shared interface, name, or invariant either one
      depends on the other settling first — delegate them in parallel instead of
      one at a time: before creating new sub-worktrees, check for any
      `<task_id>-sub-*` worktree left behind by an earlier, killed attempt at
      this step — continue that criterion's work inside it directly rather than
      starting fresh or discarding it, merging it back into $wt's branch only
      once that work is done. Otherwise, give each criterion its own git
      worktree branched off $wt's current branch (`git -C "$wt" worktree add -b
      <task_id>-sub-<label> <path> <branch>`), scoped to exactly the files that
      criterion needs, and forbidden from touching the Task file or running
      `commit_ac_checkoff` — only you do that, after consolidation. Once every
      parallel fork in that batch reports done, merge each sub-branch back into
      $wt's branch one at a time (`git -C "$wt" merge --no-ff <sub-branch>`),
      resolving any conflict before the next merge, then delete the
      sub-worktrees and sub-branches. Tick and commit each criterion's checkoff
      yourself as you go, never batching several criteria into one checkoff. Do
      not parallelize criteria that only look independent: if settling one
      changes what the other should do, they're one unit of work for one agent,
      not two racing to guess each other's choice.
      Implement task_id per your setup's own implementation-method rule
      (CLAUDE.md, project docs, skill instructions). If that rule requires proof
      before code (e.g. failing test first), produce that proof first, confirm
      it fails for right reason, THEN implement. Respect the possible
      alterations below. After each tick, below the ticked
      criterion, add one evidence line explaining why the criterion is satisfied:
      > YYYY-MM-DD HH:MM±HHMM <short evidence>
      and commit that checkoff: `@@ZERO_SH@@ commit_ac_checkoff task_id`.
      ACCEPTANCE CRITERIA GATE — hand your diff to a subagent that answers two questions separately:
      (1) is every Acceptance Criterion ticked? (2) is every ticked criterion has evidence line and
      really passing (don't run tests, static code analysis only)?
      A criterion that cannot be checked off automatically — it names a human action, an account,
      a token, a manual install — does not have to be ticked: it fails the gate as failed-manual.
      Any other negative answer besides failed-manual: go back to implementing, then run this gate
      again. Only after the subagent's answers are in hand, write the note as instructed below.
      AGENTIC SELF-REVIEW GATE — review your own diff through the review/verify gate your setup defines;
      if your setup defines none, run your own default /code-review skill procedure at minimal effort.
      Fix what it reports, then review the fixed diff again, repeating until a pass reports no new findings.
      Only after that clean pass's output is in hand, write the note as instructed below.
      Each note is your own gate's record, never a human's review of your work. Both live in one quote
      block at the end of the Task file's Acceptance criteria section, one line per gate, each rewritten
      in place when you re-run that gate, passed|failed|failed-manual depending on that gate's own
      outcome:
      > Acceptance criteria gate: passed|failed|failed-manual YYYY-MM-DD HH:MM±HHMM
      > Agentic self-review gate: passed|failed YYYY-MM-DD HH:MM±HHMM
      Do not leave this step before both gates passed. After gates passed commit the notes with:
      `@@ZERO_SH@@ commit_ac_checkoff task_id`.@@TASKPROMPT@@
@@MR_STEP_D@@
   e. HAND OFF: `@@ZERO_SH@@ mr task_id "$wt"` — no symbol to choose: this mode merges no code onto
      the target base, it opens or reuses one @@REQ@@ for the branch instead.
      - exit 0 → opened/updated; zero.sh's last stdout line names the @@REQ@@ → your one Task is
        zeroed: report that line and END YOUR TURN. Do not claim a second Task.
      - exit 5 → do what stderr says, retry once, then stop.
      - exit 2 → should not happen: the coordination claim branch is proven to carry no commit past
        its fork point before this merge runs, so landing the box onto the coordination base is
        always "Already up to date". If it appears anyway, STOP IMMEDIATELY and report it — do not
        go looking for a worktree to resolve it in, you hold only the target checkout ($wt).
3. End your turn — after zeroing one Task, or after walking the whole Release Todo List without
   claiming one (say which happened). If you walked the whole list and claimed nothing, run
   `@@ZERO_SH@@ no-claim-mark` first — it lets the shell wait for that block to clear instead of
   spending a fresh session on the same judgment. If `@@ZERO_SH@@ todo-list` now prints nothing —
   every Task has a Landed box (checked or any other symbol) — announce "ALL TASKS HANDED OFF" first. What runs next is the shell's call: it starts a fresh session for the
   next Task, waits while peers hold everything or the remainder is dependency-blocked, or prints
   the closing report.
PROMPT_EOF
    prompt=${prompt%$'\n'}          # read keeps the final newline; $(cat) stripped it
    inject_marker prompt '@@MR_STEP_D@@' "$step_d"
    inject_marker prompt '@@TODO_ABS@@' "$COORD_ROOT/$todo"
    inject_marker prompt '@@ZERO_SH@@' "$gitdir/zero.sh"
    local tp_chunk=""
    [ -n "$taskprompt" ] && tp_chunk=$'\n      '"$taskprompt"
    inject_marker prompt '@@TASKPROMPT@@' "$tp_chunk"
    inject_marker prompt '@@REQ@@' "$req"
    printf '%s\n' "$prompt"
}

main "$@"
