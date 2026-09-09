#!/usr/bin/env bash
# check-embedded.sh — shellcheck the scripts kaizero.sh emits at runtime
# (compact-exit-hook.sh, zero.sh, terminator.sh). They live in single-quoted
# heredocs, so shellcheck of kaizero.sh can't see inside — the blind spot that
# shipped an unbalanced quote in zero.sh. KAIZERO_TEST_EMIT runs init for real
# in a throwaway repo (writes the scripts, exits before claude); we lint the actual
# files — no re-extraction to drift from how they're emitted.
#
# BUG 058k: shellcheck alone never catches a construct that only fails to PARSE under bash
# 3.2 (stock macOS ships it as /bin/bash; the rest of this codebase already holds to that
# floor) — a Linux-only CI leg has no bash 3.2 to catch it with either. Below, once the
# scripts are on disk, each one is also parsed with whatever bash 3.x binary is available
# (macOS's own /bin/bash when it reports a 3.x version; a BASH3 override otherwise) — the
# same real-bash-3.x-parse coverage tests/S-001-static-checks.sh's S3b already has, just not
# previously wired into this CI-invoked script.
set -euo pipefail

# scripts kaizero.sh emits into its git dir; keep in sync when a new one is added.
SCRIPTS=(compact-exit-hook.sh zero.sh terminator.sh)

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/.." && pwd)/kaizero.sh"
sc="${SHELLCHECK:-shellcheck}"
# absolutize now — we cd into a temp repo below (bare name or relative path both break after).
case "$sc" in
  */*) sc="$(cd "$(dirname "$sc")" && pwd)/$(basename "$sc")" ;;
  *)   sc="$(command -v "$sc")" ;;
esac

# pwd -P: macOS mktemp returns /var/... but git toplevel resolves /private/var/...;
# kaizero.sh refuses launch when $PWD != git toplevel, so match the physical path.
tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; mkdir "$repo"; cd "$repo"
git init -q; git config user.email ci@ci; git config user.name ci
mkdir tasks; printf '# todo\n\n- [ ] task one\n' > tasks/todo.md
git add -A; git commit -q -m init

echo "== env =="
echo "uname:    $(uname -a)"
echo "bash:     $BASH_VERSION"
echo "git:      $(git --version)"
echo "shellcheck: $sc ($("$sc" --version | awk '/version:/{print $2}'))"
echo "PWD:      $PWD"
echo "toplevel: $(git rev-parse --show-toplevel)"

echo "== emit (KAIZERO_TEST_EMIT=1) =="
# don't swallow output: on failure set -e aborts, so show what init printed before dying.
if ! KAIZERO_TEST_EMIT=1 bash "$src" --local-merge tasks/todo.md; then
  echo "FAIL: emit exited non-zero (see output above)" >&2
  exit 1
fi
gitdir="$(git rev-parse --git-dir)"
echo "gitdir:   $gitdir"
echo "emitted:  $(cd "$gitdir" && printf '%s ' *)"

# -e SC2016: single quotes not expanding is intentional here (bash -c blob, awk
# programs). Real breakage is an SC1xxx parse error — this exclusion doesn't touch it.
fail=0
for f in "${SCRIPTS[@]}"; do
  p="$gitdir/$f"
  [ -f "$p" ] || { echo "FAIL: $f was not emitted by init" >&2; fail=1; continue; }
  echo "== shellcheck $f =="
  "$sc" -e SC2016 "$p" || fail=1
done

# real bash 3.x parse (shellcheck alone doesn't catch bash-3.2-only parse failures — see the
# header comment). macOS's own /bin/bash is 3.2; elsewhere BASH3 names one, or this step is
# skipped with a note rather than failing a host that genuinely has none.
b3=""
if [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.'; then
  b3=/bin/bash
elif [ -n "${BASH3:-}" ] && command -v "$BASH3" >/dev/null 2>&1; then
  b3="$BASH3"
fi
if [ -n "$b3" ]; then
  echo "== bash 3.x parse ($b3) =="
  "$b3" -n "$src" || fail=1
  for f in "${SCRIPTS[@]}"; do
    p="$gitdir/$f"
    [ -f "$p" ] || continue
    "$b3" -n "$p" || fail=1
  done
else
  echo "no bash 3.x found (set BASH3)"
  fail=2
fi

[ "$fail" -eq 0 ] && echo "embedded scripts OK"
exit "$fail"
