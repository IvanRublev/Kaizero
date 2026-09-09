#!/usr/bin/env bash
# Teardown, half 1 of 2 — reap the processes a scenario left behind. Run last by every
# tests/*.sh scenario, in both run modes (implementor mode skips the tree delete, never this).
# Usage: . tests/test-teardown-reap.sh "$TESTROOT"
# Sourced, not run as a subprocess, so the scenario's own trailing `[ "$FAILED" = 0 ] && ...`
# exit-status line still runs after this returns — every `exit` below is therefore
# `return … || exit …`, which returns to the sourcing scenario but still hard-exits if this
# script is ever invoked standalone (`bash test-teardown-reap.sh ...`).
TESTROOT="${1:?usage: test-teardown-reap.sh TESTROOT}"
GRACE="${REAP_GRACE:-3}"   # seconds to wait after SIGTERM before escalating to SIGKILL

# scoped to THIS run only: a nested real claude's --settings value is a JSON blob whose
# `command` field is $STOP_HOOK, always under $TESTROOT for every scenario — so this pattern
# never matches a claude/kaizero.sh process outside this run. Deliberately NOT a bare
# `kaizero.sh`/`claude .*--settings` pattern: that matches every such process on the
# machine, including this project's own real dogfood loop (if one happens to be running) and
# possibly the real agent itself, if its launch command line ever carries --settings too. Bare
# kaizero.sh loops need no separate catch here — every Run block already wraps its own
# invocation in `timeout`, which self-terminates them on schedule regardless of teardown.
# $TESTROOT is in this script's own argv (and every ancestor's), so a bare `pkill -f
# "$TESTROOT"` matches itself, kills the shell mid-teardown and leaves the tree behind. So:
# collect the matches, drop this process and its ancestor chain, then kill what is left.
skip=" $$ "; p=$$
while p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); [ -n "$p" ] && [ "$p" -gt 1 ]; do skip="$skip$p "; done

# a matched process's own child may have been backgrounded early enough that $TESTROOT never
# made it into ITS argv (it only ever lived in the parent's) — so a plain `pgrep -f` re-run
# would never see it. Walk the process tree from every argv match instead: descendants of a
# match are part of this run regardless of what their own argv says.
collect(){
  local seen=" " queue next pid kids
  queue="$(pgrep -f "$TESTROOT" 2>/dev/null || true)"
  while [ -n "$queue" ]; do
    next=""
    for pid in $queue; do
      case "$skip" in *" $pid "*) continue ;; esac
      case "$seen" in *" $pid "*) continue ;; esac
      seen="$seen$pid "
      kids="$(pgrep -P "$pid" 2>/dev/null || true)"
      next="$next $kids"
    done
    queue="$next"
  done
  printf '%s' "$seen"
}

pids="$(collect)"
for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done

i=0
while [ "$i" -lt "$GRACE" ]; do
  alive=""
  for pid in $pids; do kill -0 "$pid" 2>/dev/null && alive=1; done
  [ -z "$alive" ] && break
  sleep 1; i=$((i + 1))
done

# re-collect: a stub that ignores SIGTERM (`trap "" TERM; sleep …`) is still here, and so is any
# descendant that appeared since the first pass — escalate everything still alive to SIGKILL.
pids="$(collect)"
for pid in $pids; do kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null; done
sleep 0.2

survivors="$(collect)"
if [ -n "${survivors## }" ]; then
  echo "FATAL: reap left processes alive: $survivors" >&2
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi
# shellcheck disable=SC2317
return 0 2>/dev/null || exit 0
