# TEST.md — end-to-end tests for `kaizero.sh`

The suite is `tests/*.sh` — one self-contained script per scenario. Each script creates its own
`$TESTROOT`, sources `tests/test-setup.sh`, runs its own cases, and tears down; there is no
assembly step and no shared prose to copy into a prompt. `tests/test-runner.sh` is the job
runner that drives them.

## Run modes

Two modes, one difference between them: who cleans up after a failure. `KAIZERO_TEST_MODE`
(`report`, the default, or `implementor`) is an environment variable set before
`tests/test-runner.sh` (or a single `tests/<KEY>.sh`) runs.

- **Report mode (default).** Every scenario runs its full teardown — process reap, then tree
  delete — pass or fail, so a run leaves nothing behind on a CI machine or a laptop.
- **Implementor mode.** A scenario whose run had at least one FAIL or ERROR still reaps its
  processes but skips the tree delete: its `$TESTROOT` is left standing whole — the throwaway
  repos, the task worktrees, the stub logs, every input and output the failing case produced —
  and its path is printed (`TESTROOT retained for implementor mode: <path>`). A scenario that
  passed cleans up as in report mode, so only the interesting roots survive. **Teardown of a
  retained root is then the implementor's**: source its `env.sh` to get `REPO`, `SCRIPT` and the
  helpers back, then run both teardown scripts against it once the failure has been read and the
  fix is known.
  `kaizero.sh` is not edited while a run is in flight — every scenario reads `$SCRIPT` live
  from the repo, so a mid-run edit changes the code under test underneath the scripts still
  running. In the implementor loop the suite runs till all finished, then the fix lands, then the
  suite runs again. A run reports only the roots it retained itself and touches no root it did
  not create.

## Prerequisites

`flock`, `uuidgen`, `timeout`, `git`, `date`, `find`, `stat`, `mv`, `shellcheck`, `jq`, `python3` and a
bash 3.x binary (`/bin/bash` on macOS, Homebrew's `bash-3.2` elsewhere) on PATH — `tests/test-setup.sh`
refuses the whole run when any of them is missing, naming it, and refuses to run as root. A-001 and
C-001 need real `claude` on PATH, and additionally each need their own fixed directory under
`$HOME/.kaizero-test-root` (`.../A-001-parallel-zeroing`, `.../C-001-merge-conflict-path`)
pre-trusted **once**, out of band: `claude`'s interactive first-run "trust this folder?" dialog
can't be answered headlessly, and trust state lives in `~/.claude.json`, outside anything a test
run can set up for itself without mutating the operator's live global config. Trust for a git
repository is keyed on that repository's own root, not inherited from a trusted ancestor
directory — confirmed empirically: trusting a plain non-repo parent does not cover a `git init`'d
child, but trusting a repo's main worktree does cover its own linked worktrees (siblings sharing
one `.git`), which is the exact shape `kaizero.sh` launches `claude` in (`$T/repo` plus its
`$T/ts-*` task worktrees). So A-001 and C-001's `$T` is a fixed path — not minted fresh under
`$TESTROOT` like every other scenario — reset at the start of each run and trusted exactly once,
permanently; every task worktree created under it inherits that trust automatically. `$TESTROOT`
itself is unaffected and still minted normally by each script's own `tests/test-setup.sh` call.
Since `$T`/`$TC` sit outside `$TESTROOT`, the guard (`$SCRIPT`'s wrapper, and the wrapped `git()`)
allows one second, exact, purpose-built root — `$HOME/.kaizero-test-root` (named `$ANCHOR`) —
alongside `$TESTROOT`, never a broader wildcard; every other scenario's cwd is still refused the
instant it strays from `$TESTROOT`, the guard's original invariant. A-001 and C-001's own Setup
sections refuse with a named reason if their fixed `$T` isn't trusted, rather than silently hanging
every real-`claude` session on the dialog for its full budget; their teardown resets `$T`'s contents
directly (it lives outside `$TESTROOT`, so the shared teardown scripts never touch it) without
removing `$T` itself, since removing it would lose the trust entry's target. B-001, B-002, E-001,
F-001 and G-001/G-002 do **not** invoke claude but still need it present on PATH: `run_doctor` tests
`command -v claude` before any startup guard runs, so a missing `claude` fails them at the wrong
step (E/F/G additionally supply a stub `claude` so kaizero writes `zero.sh` and loops out at
once; B needs none beyond the PATH check since every case there refuses before a launch). U needs
no real `gh` or `glab` — its own stubs stand in for both, on a scenario-scoped `PATH` built from
real binaries for everything else, `jq` included, since it is a real prerequisite the scenarios
invoke directly, not a forge call U stubs.

Because A-001 and C-001 sit in the isolated bucket, a full-suite run only reaches their trust
check after every concurrent scenario has already returned — so a missing pre-trust surfaces as
two ERROR rows at the very end of a long run instead of failing fast. Before running the full
suite (or any subset containing A-001 or C-001), check both are pre-trusted first:
`jq -e '.projects["'"$HOME/.kaizero-test-root/A-001-parallel-zeroing/repo"'"].hasTrustDialogAccepted == true' ~/.claude.json`
and the same for `C-001-merge-conflict-path`, before spawning anything.

## Isolation contract

Nothing is written inside the project repo. All test repos, their `../ts-*` worktrees, and all
state live under `$TESTROOT` (outside the repo) — except A-001 and C-001's fixed, pre-trusted
coordination repos, which live under `$ANCHOR` (`$HOME/.kaizero-test-root`) instead, a second
exact root the guard allows for those two scenarios only (see Prerequisites). The only things read
from the repo are `kaizero.sh` itself (`$SCRIPT`) and `tests/test-setup.sh` /
`tests/test-teardown-*.sh`.

`REPO` (`tests/test-setup.sh`) is resolved via `git worktree list`, never `$(pwd)` — deterministic
regardless of which worktree a run happens to start in, so a cwd drift can no longer point
`$SCRIPT` at a real task worktree of the project instead of the main checkout (that worktree
shares the project's actual `.git`; running kaizero.sh there is a real run — real claude, real
Stop hook — against real repo state, not a test). The wrapped `git()` function `tests/test-setup.sh`
defines is the matching runtime guard: every `git` call any scenario makes refuses the moment its
cwd strays from `$TESTROOT`/`$ANCHOR`, regardless of why — a lost variable, a typo, a mistake
nobody's written yet — so a wrong-but-set path can no longer mutate the real checkout the way it
did in BUG 043a. A `.sh` scenario has no block boundary for state to be lost across: `$TESTROOT`
and every scenario-local variable live in one bash process from its first line to its last.

Run every step from anywhere inside the repo (any worktree).

## Dispatch instruction

Running one scenario is `bash tests/<KEY>.sh` — no assembly, no prompt, no separate sourcing
step. It creates its own `$TESTROOT`, sources `tests/test-setup.sh`, runs every case, prints every
case's verdict line via `check()`, and tears down per the run mode above. Its own exit status is
non-zero whenever it had a FAIL or an ERROR, zero otherwise.

Running the full suite (or a named subset) is `tests/test-runner.sh [KEY...]`. It performs, in
order:

1. **Baseline residue pass** (before spawning anything).
2. **Enumerate** `tests/*.sh` — or, when run names subset, only named scripts:
   - Split into two buckets by each scenario's own `# KAIZERO_TEST_ISOLATED=1` marker line.
     Two independent reasons put a scenario in this bucket, either one is sufficient:
     - **Own internal race.** 10 scenarios were confirmed empirically (across repeated
       full-suite runs) to race own background helper subprocess against own main
       `kaizero.sh` process — timing relationship internal to scenario, not shared-file
       collision (every scenario's `$TU` already unique directory; see Isolation contract
       above) — and concurrent CPU contention from other scenarios skews which side of that
       internal race lands first, flipping genuinely correct run to false FAIL/ERROR. Scenario
       found to have same problem later should add own `# KAIZERO_TEST_ISOLATED=1` marker
       line rather than being special-cased here.
     - **Uses real `claude`.** these tests also carry `# KAIZERO_NEEDS_REAL_CLAUDE=1`:
       a real `claude` call is slow and CPU-heavy against the 7 other concurrent processes, 
       and only one real-`claude` scenario is ever meant to run at a time. A scenario added
       later that needs real `claude` should carry both markers, 
       `# KAIZERO_TEST_ISOLATED=1` and `# KAIZERO_NEEDS_REAL_CLAUDE=1`.
   - No marker → **concurrent** bucket, spawned per concurrency cap: 8 total.
   - Cap is rolling window, not batch — moment any script returns, runner spawns next
     not-yet-started one to refill freed slot immediately, without waiting for others to finish.
   - Isolated-bucket scenario runs **after** every concurrent one has returned, **one at a
     time**, nothing else competing for CPU.
   - Run naming no subset is full suite; run naming one is partial run, and report states subset
     it ran so it can't be mistaken for full one.
   - Each script — concurrent or isolated — run as `timeout "$BUDGET" bash tests/<KEY>.sh`,
     `$BUDGET` read from that script's own leading `# KAIZERO_WALLCLOCK_BUDGET=` line.
   - Runner prints running tally as concurrent scripts complete (`K/N done (KEY: PASS|FAIL)`, `N` =
     concurrent bucket's count), then second tally as isolated scripts complete (`K/N isolated done
     (KEY: PASS|FAIL)`, `N` = isolated bucket's count) — together account for named subset, or full
     `tests/*.sh` glob.
3. **Residue pass** (after everything returns, concurrent and isolated alike), diffed against the
   baseline.
4. Merge every script's stdout and the residue diff into one file. Steps 1-3 are
   `tests/test-runner.sh`'s own work, no agent involved — every script's own pass/fail is
   deterministic (`check()`'s own comparison), so grading it is a job for a plain job runner.

An LLM reads that merged output once, after everything returns, to write the human-facing report
per the Report format below — triage, root-causing a FAIL, and prose summary are reasoning work;
grading is not.

`tests/test-setup.sh`, `tests/test-teardown-reap.sh`, `tests/test-teardown-delete.sh` and
`tests/test-runner.sh` are the four scripts every scenario and every run of the suite depends on.

## Report format

For each scenario:

- **A verdict line per case:** `<scenario key> <case id> PASS|FAIL`, using the case ids the
  scenario already prints via `check()`. The scenario-key prefix is added **when the report is
  written** — never by editing a case's own `check()` call — so ids stay unique once every
  scenario's lines are merged into one table.
- **ERROR** for a scenario whose Setup could not run at all, and for any case whose command a
  guard refused to run: reported as ERROR with the reason — the refusal quoted as it was given —
  never as FAIL, because neither a broken fixture nor an unrun command is a failure of the code
  under test. PASS, FAIL and ERROR are the only three verdicts; every case carries one and there
  is no fourth outcome that lets a check stand down.
- **How a verdict is reached:** `check()`'s own comparison. A command's exit status alone is not
  the verdict — most scenario bodies walk past a non-zero command on purpose.
- **The evidence** each `check()` call printed, whatever the verdict — this is what a reviewer
  skims, and what makes a PASS auditable rather than asserted.
- **For every FAIL, additionally:** the exact command that failed, expected vs. observed as
  `check()` printed them, the last 20 lines of the relevant log, and the `kaizero.sh` function
  or `file:line` the case exercises where the scenario's own comments already name one. In
  implementor mode, also the retained `$TESTROOT` path.

A verdict line is never dropped to fit a length limit. A report that must shorten drops evidence
from *passing* cases first, then everything else, before it drops a single verdict line or any
part of a FAIL's detail.

For A-001, add a table `T1..T5 | agent | PASS/FAIL` from marker contents, plus the timing verdict.

### The report's summary, composed in this order

1. **The suite verdict**, one line, first: any FAIL or ERROR anywhere makes the run **FAIL**. With
   it, the run mode it was produced under, the subset of scripts it ran (or "full suite"), and the
   total wall-clock time from `tests/test-runner.sh`'s first spawn to its last script's return.
2. **The `PASS/FAIL` count.**
3. **The per-scenario roll-up** — scenario, cases, passed, failed. One row per `tests/*.sh` file
   the run spawned; a script that dies, returns nothing, or returns something this format can't
   be read out of is an **ERROR row**, never an omitted one, because an absent row reads as a
   green run. The roll-up is not every case line from every scenario: the largest scenarios carry
   a hundred cases each, and a table nobody can read is not a pull-request artifact.
4. **The full FAIL detail** for each failing case, as listed above.
5. **The retained-roots section** — implementor mode only. The teardown obligation and the exact
   command, stated once, above the list of every surviving `$TESTROOT` with the scenario it
   belongs to and which folder under it the failing case worked in, sourced from what
   `tests/test-runner.sh` already printed (`TESTROOT retained for implementor mode: ...`), not
   re-derived from anything else.
6. **The residue-check output** — from `tests/test-runner.sh`'s own baseline/residue passes.

A run with no FAIL anywhere produces a report with no FAIL-detail section and no retained-roots
section — nothing is fabricated when the merged input has nothing to put there.
