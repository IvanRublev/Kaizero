#!/usr/bin/env bash
# Teardown, half 2 of 2 — delete the scenario's tree. Run last by every tests/*.sh scenario in
# report mode; implementor mode skips it for a scenario that had a FAIL or ERROR, so the tree
# survives for diagnosis. Usage: . tests/test-teardown-delete.sh "$TESTROOT"
# Sourced, not run as a subprocess, so the scenario's own trailing exit-status line still runs
# after this returns — every `exit` below is `return … || exit …` for that reason.
ROOT_ARG="${1:?usage: test-teardown-delete.sh TESTROOT}"
if [ ! -f "$ROOT_ARG/env.sh" ]; then
  echo "FATAL: $ROOT_ARG/env.sh not found — not a TESTROOT this suite created" >&2
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi
# resolved BEFORE sourcing: env.sh's own contents could in principle carry a stray same-named
# local, so anything this script still needs after the `.` below is captured first, under a name
# env.sh has no reason to collide with.
CANON_ARG="$(cd -P -- "$ROOT_ARG" 2>/dev/null && pwd -P)"
# zap is the suite's only recursive delete, defined once by test-setup.sh and carried in env.sh:
# it refuses any target that is not $TESTROOT or under it, and makes the tree writable first.
# shellcheck source=/dev/null
. "$ROOT_ARG/env.sh"
# the physical path of what we were HANDED must be the TESTROOT env.sh itself recorded — a
# passed-in path that resolves elsewhere (a stale caller, a typo, a symlink) must never delete
# whatever TESTROOT this env.sh happens to name instead of the one the caller meant.
if [ "$CANON_ARG" != "$TESTROOT" ]; then
  echo "FATAL: $ROOT_ARG (resolves to $CANON_ARG) does not match TESTROOT=$TESTROOT recorded in $ROOT_ARG/env.sh — refusing" >&2
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi
zap "$TESTROOT"
