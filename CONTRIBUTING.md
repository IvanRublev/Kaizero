# Contributing

Thanks for helping to improve Kaizero. Even snow leopards sharpen their claws. Rawr.

1. **Fork** the repository and create a feature branch.

2. **Make your change.** Keep the diff surgical — match the existing style in
   `kaizero.sh`.

**2.1 Update the README if behavior changes.**

**2.2 Change the test suite.** The same steps cover altering a scenario and adding one:

   - **Write the scenario as its own self-contained script under `tests/`** — a new file, or the
     existing one you are changing. One scenario per file, named `LETTERS-NNN-behaviour-name.sh`:
     the letters group every scenario cut out of the same original one (`A`, `B`, … `Z`, then
     `AA`, `AAA` once the alphabet runs out), `NNN` is the part number inside that group,
     zero-padded to three digits so the directory sorts in suite order, and the rest says what the
     scenario checks. A group that was never cut still carries `-001`, so a later cut appends
     `-002` instead of renaming what is there. That name is the scenario's **key** — also the
     folder the scenario builds under `$TESTROOT`.

     Every scenario script opens the same way and ends the same way:

     ```bash
     #!/usr/bin/env bash
     # KAIZERO_WALLCLOCK_BUDGET=90s
     set -uo pipefail
     SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
     . "$SCENARIO_DIR/test-setup.sh"

     # ... Setup, then one comment + code block per case, each ending in one or more
     # check "<label>" "<actual>" "<want>" calls ...

     . "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
     if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
       echo "TESTROOT retained for implementor mode: $TESTROOT"
     else
       . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
     fi
     [ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1
     ```

     A case whose command is refused by a guard calls
     `check "<label>" "ERROR:<refusal text, quoted verbatim>" ""` instead of comparing a value it
     never got to produce — a guard refusal is ERROR, never FAIL. No case may call `exit` on its
     own; a FAIL or ERROR must still reach the trailing teardown lines. If a real `claude` (`gh`/
     `glab` do not count) is on the scenario's own critical path, add
     `# KAIZERO_NEEDS_REAL_CLAUDE=1` as a second leading marker line — `tests/test-runner.sh`'s
     concurrency cap reads it.
   - Nothing else names scenarios: `tests/test-runner.sh` globs `tests/*.sh` directly, so a new
     file is picked up automatically, no list to keep in sync.
   - **Put new shared setup in `tests/test-setup.sh`.** Shared means every scenario gets it
     whether it asks or not: a prerequisite check that refuses the whole run, a resolved path or
     binary the suite agrees on (`REPO`, `SCRIPT`, `SHELLCHECK`, `B3`), the `TESTROOT` mint, and
     helpers more than one scenario calls (`check`, `git`, `ago`, `write_gate`, `own_session`,
     `zap`).
   - **Everything a single scenario needs stays in that scenario's own script** — its fixture
     repositories and their commits, its todo files, its stub `claude`/`gh`/`glab` and the `PATH`
     built around them, its `$T*` root under `$TESTROOT`, and its own local helpers (`mkrepo`,
     `mktodo`, `mkpath`, `mkorigin`, `emit` and the like, each redefined per file on purpose, so a
     scenario reads and runs standalone).
   - **Put the matching teardown in `tests/test-teardown-reap.sh`** when new shared setup leaves
     something a file delete does not undo — a process, a lock, state outside `$TESTROOT`.
     Files need none: `tests/test-teardown-delete.sh` zaps the whole `$TESTROOT` already.

**2.3 Lint the script.** `kaizero.sh` must parse under bash 3.2 — macOS ships it as `/bin/bash`,
   and a parse error there kills the script before line one runs. Avoid:

   ```sh
   prompt="$(cat <<'EOF'    # here-doc inside $( … ) — bash 3.2 cannot parse it
   ...
   EOF
   )"

   IFS= read -r -d '' prompt <<'EOF' || :    # use this instead
   ...
   EOF
   ```

   Scenario S (`tests/S-001-static-checks.sh`) guards it: S3a scans for the construct on any host,
   S3b parses with a real bash 3.x. Locally: `/bin/bash -n kaizero.sh`.

3. **Keep the CI scripts in sync with `kaizero.sh`.** Two scripts under
   `.github/` mirror details of `kaizero.sh` and drift silently if you don't
   update them:

   - **`.github/smoke.sh`** — runs each OS tool `kaizero.sh` calls, in the exact
     argument form it uses, to catch BSD-vs-GNU (macOS) divergence. If your change
     adds a new external-tool dependency (e.g. a new `flock`/`ps`/`sed`/`git`
     invocation with a non-portable flag), add a numbered case for it, following
     the existing ones. Update the `kaizero.sh:<line>` reference in the case's
     comment if you moved the call.

   - **`.github/check-embedded.sh`** — shellchecks the scripts `kaizero.sh`
     writes into the git dir at runtime (their bodies live inside single-quoted
     heredocs, invisible to a plain shellcheck of `kaizero.sh`). If you add,
     rename, or remove one of those emitted scripts, update the `SCRIPTS=(...)`
     array at the top of the file to match. The check runs `kaizero.sh` for real
     via the `KAIZERO_TEST_EMIT` flag — if you rename that flag, update its guard
     in `kaizero.sh` (near `run_loop`) and this script together.

   - **`run_doctor`'s in-script flag check (`assert_forge_flags`), plus
     `MIN_GH_VERSION`/`MIN_GLAB_VERSION`** — a third mirror of the same forge
     contract, run locally at `--doctor`/launch time rather than only in CI. If a
     `gh`/`glab` call's flags change, update `assert_forge_flags`'s flag lists
     alongside `mr_list`/`mr_create` and `.github/smoke.sh` check 18; if the flag
     change raises the oldest CLI release that still carries it, raise the matching
     `MIN_*_VERSION` constant too.

   Run both locally before pushing (`shellcheck` needed for the second):

   ```sh
   bash .github/smoke.sh
   bash .github/check-embedded.sh
   ```

4. **Run the tests.** The end-to-end suite is [TEST.md](TEST.md) plus one self-contained script
   per scenario under [`tests/`](tests). Run the whole suite, or a named subset, with the plain
   shell job runner — no LLM involved in grading:

   ```sh
   tests/test-runner.sh
   tests/test-runner.sh A-001-parallel-zeroing M-001-one-task-per-session   # named subset
   ```

   That is **report mode**: every scenario cleans up after itself, pass or fail, and the run
   leaves nothing behind. When you are fixing a failure, ask for **implementor mode** instead:

   ```sh
   KAIZERO_TEST_MODE=implementor tests/test-runner.sh
   ```

   It keeps the `$TESTROOT` of every scenario that had a FAIL or ERROR — the throwaway repos, the
   task worktrees and the logs the failing case produced — and prints each retained path. Those
   roots are **yours to remove**: once you have read the failure and know the fix, source the
   retained root's `env.sh` and run both `tests/test-teardown-*.sh` scripts against it. A scenario
   that passed cleans up as usual either way.

   A run can also name a subset of scenario keys, which is what the fix, re-run, check loop
   wants — re-running the real-`claude` scenarios to verify one fix is waste. A single scenario
   also runs standalone: `bash tests/<key>.sh`.

5. **Open a PR** to this repository once all tests pass, with a short note on
   what changed and the test report.

Found a security issue? Don't open a PR or public issue — see
[SECURITY.md](SECURITY.md).
