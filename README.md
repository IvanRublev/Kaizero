<p align="center">
  <a href="character/kaizero-legend.md"><img src="character/kaizero-portrait.png" alt="Kaizero - Todo-list sensei for Claude Code" width="256"></a>
</p>

<h2 align="center">Todo-list sensei for Claude Code. Zeros your list.</h2>
<h4 align="center">
Loops Claude until every Task is implemented, committed, and checked off.<br>
Restarts the coding session on a fresh context before rot.<br>
You can spawn multiple instances to parallelize.<br><br>
It's for practical <a href="#loop-engineering">Loop engineering</a>.<br>
</h4>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT" /></a>
</p>

Runs [`claude`](https://claude.com/product/claude-code) on a predefined prompt in a loop on the given Todo List — the file of Task lines selected to ship together as one Release. Makes it hand off each Task for review by default, or land it directly with `--local-merge`: implement, commit, and open a merge/pull request or merge to the base branch — then check the box off once the work reaches the base branch. The session stays interactive, so you can add prompts and make choices as it runs. Launches `claude` in auto permission mode by default, and restarts it on a fresh context before rot sets in.

## Contents

- [What it does](#what-it-does)
- [Quickstart](#quickstart)
- [Install](#install-for-the-claude-coding-agent)
- [Todo List format](#todo-list-format)
- [Context Rot](#context-rot)
- [Loop engineering](#loop-engineering)
- [Usage](#usage)
- [Cleanup](#cleanup)
- [Tests](#tests)
- [Security](#security)
- [Contributing](#contributing)
- [Commercial Support](#commercial-support)

## What it does

- **Guides Claude to zero a Todo List unattended** — one Task at a time until all are implemented, committed, and checked off.
- **Beats context rot** — session Stop hook SIGTERMs `claude` once its context total crosses a threshold (see [Context rot](#context-rot)) and restarts clean. Fresh context, no quality decay.
- **One Task per session** — `claude` exits once it has zeroed a single Task and the script restarts it, so every Task runs on a context isolated from the Task before it, which cuts token spend (~20% on a working instance). An instance that has nothing to claim waits in the shell without launching `claude` at all, spending nothing.
- **Parallel by default** — run many instances at once; they coordinate via git worktrees, each claiming Tasks the others haven't taken.
- **Safe landings** — each Task is handed off as a merge/pull request for a reviewer by default, or landed directly as a local merge to the base branch. Either way the merge-back and the box tick are serialized across instances through `flock`; no races, no corrupted base.
- **Crash resilient** — if `claude` crashes or is killed mid-Task, its unfinished work isn't lost. The next instance to come by — a peer switching to its next Task, or the same loop restarted — reclaims the branch, finishes it, and merges it back. Work only counts as Landed once it lands on the base branch and its box is checked there.
- **Named sessions** — every `claude` session is named `(<instance id>) <nick> · <activity>`, shown in the prompt box and the terminal title.
- **Ctrl+C window** — 5s pause between runs to stop cleanly.

## Quickstart

```
sudo curl -fsSL https://raw.githubusercontent.com/IvanRublev/kaizero/refs/heads/master/kaizero.sh -o /usr/local/bin/kaizero
sudo chmod +x /usr/local/bin/kaizero
```

Make sure that your Todo List file is committed in the git repository which is separate from you codebase one.
Make sure the working tree of both repositories are in a clean state (commit or stash any changes).

Then run `kaizero` pointing to your Todo List, picking the mode by how the work gets reviewed:

```sh
kaizero todo.md                 # team merge (pull) requests review
kaizero --local-merge todo.md   # commit review
```

You can run either command in multiple parallel terminals to work through the Tasks faster.

> ⚠️ Kaizero runs `claude` **unattended with permissions auto-approved** and **commits on its own** to the branch you launch it on. Only ever point it at a Todo List you wrote or reviewed, on a branch with a clean, committed tree — git is your only undo.

### Sample output

Representative run of a default launch: two repositories, `origin` on `github`, each Task landing
as a pull request (LLM agent output between the markers elided). Standing in `~/repos/acme-api`, the
Todo List in `~/repos/acme-planning/todo.md`:

```console
$ kaizero ../acme-planning/todo.md

❄ Kaizero 0.0.18
  todo ~/repos/acme-planning@main · target ~/repos/acme-api@main · fork → implement → commit → pull request (gh)

… claude works a Task: forks a worktree off origin/main, implements, commits, pushes …

mr SMTH-855: https://github.com/acme/acme-api/pull/12 [↑] on main

❄ claude exited with code 0 after 1 runs · restarting in 5s · press Ctrl+C to stop

… fresh context, next Task …

❄ execution stats (instance a1b2c3d4 · moss)
  Tasks:               12m30s  ·  5 Handed off
  Kaizero run loop: 48m15s

  Tokens: 5.8M Total
  in 2.1k · out 84.3k · cache write 312.0k · cache read 5.4M

-----------------------------------------------
❄ TOTAL (3 instances)
  Tasks:               41m12s  ·  14 Handed off

  Tokens: 17.4M Total
  in 6.3k · out 251.9k · cache write 903.0k · cache read 16.2M

❄ Kaizero surveys the frozen field, and is proud.
```

A `[↑]` box says the work is pushed and a reviewer now owns it; the box turns `[x]` once the
request merges — see
[Landing as a merge/pull request](#landing-as-a-mergepull-request-the-default). A single-repository
launch, or any `--local-merge` run, prints a `merge …` line instead of the `mr …` line — see
[Merging locally](#merging-locally---local-merge).


## Install (for the Claude coding agent)

Supported on **macOS and Linux** (the script is bash-3.2-safe, so stock macOS `bash` works).

### Get the script

#### Linux / macOS (curl)
  ```sh
  sudo curl -fsSL https://raw.githubusercontent.com/IvanRublev/kaizero/refs/heads/master/kaizero.sh -o /usr/local/bin/kaizero
  sudo chmod +x /usr/local/bin/kaizero
  ```

#### macOS (Homebrew)
  ```sh
  brew install IvanRublev/tap/kaizero
  ```

### Prerequisites

`bash`, `git`, `claude` CLI, plus:

1. **flock** — merge/worktree locking. Must be runnable, not just present.
   ```sh
   brew install flock          # macOS; Linux ships it in util-linux
   ```
2. **`gh` or `glab`, plus `jq`** — needed whenever Tasks land as requests, which is whenever
   `--local-merge` is absent and the target's `origin` qualifies (see
   [Landing as a merge/pull request](#landing-as-a-mergepull-request-the-default)); whichever CLI
   matches that `origin` host. A `--local-merge` run never touches them. `gh >= 2.18.0` /
   `glab >= 1.53.0` — the lowest release of each CLI known to still carry every flag and JSON
   field Kaizero depends on; an older install is refused by name, at `--doctor` time.
   ```sh
   brew install gh jq          # github.com / GitHub Enterprise
   brew install glab jq        # gitlab.com / self-hosted GitLab
   ```

These prerequisites are guard-checked at startup (the forge's only when the run lands requests); the script exits with a clear message if it is missing — including a renamed or dropped `gh`/`glab` flag, caught before a launch, not only in CI.

**Transcript-schema contract.** Kaizero couples to one thing in Claude Code internals: the session transcript's `message.usage` schema. Kaizero's own Stop hook records each session's `transcript_path` (a field of the hook payload), and reads it twice, for two different readers. The **context-rot guard** (below) reads the newest usage record on every turn to decide whether to restart. The **token report**, after `claude` exits, reads the whole transcript and sums the `message.usage` fields of every assistant line: `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` — the four categories Anthropic bills separately. One API request is written as several transcript lines, one per content block, each repeating the same `usage` object verbatim, so the token report **dedupes by the line's `requestId`** — a rule that belongs to the token report alone, since the context-rot guard keeps only the latest record regardless of request. Both readers take only the first (parent) match of each field name on a line: `usage.iterations[]` repeats all four names one level down, and `usage.cache_creation` carries the `ephemeral_5m`/`ephemeral_1h` leaves that already sum into the parent.

Transcripts are only ever read, and no schema change can fail a run — any parse miss on the token report prints `Tokens: n/a`, and any parse miss on the context-rot guard leaves the session running; either way the run continues.

Two limits: **subagent tokens are invisible** — a session that used the Agent tool writes no `isSidechain` usage lines, so anything the Task prompt spawns is missing from the totals, and the size of the under-count is not measurable from inside; and the figures are **per instance run, for this repo only**, unlike whole-machine tools such as `ccusage`, whose denominator is every Claude Code session on the box.

## Todo List format

GitHub-style Markdown checkboxes, one Task per line. Each line carries a **unique id** as the first whitespace-delimited token right after the checkbox — it names the Task's branch and worktree. That first token may also be a markdown link `[ID](path)` (no space between `]` and `(`, no nested brackets) — the bracketed label is the id, the path is ignored:

`````markdown
- [ ] SMTH-855 Add retry logic to the sync endpoint
- [ ] 7 Extract validation into its own module
- [ ] 7.a Cover validation with unit tests
- [x] SMTH-140 Set up CI pipeline

```
- [ ] EXAMPLE-1 An illustrative example, not a Task
```
`````

`[ ]` = Unlanded, the only box a session claims. `[x]` = Landed. Any other single character is skipped: a filled box is never claimed. For more possible symbols see for example [Landing as a merge/pull request](#landing-as-a-mergepull-request-the-default). User can also ask to put a custom symbol in the box on Task completion with `--taskprompt`.

A Task or Bugfix's own `### Acceptance criteria` section is best kept under `tasks/` — a recommendation for humans skimming the repo, not a requirement: a Task file's path is resolved automatically by id, anywhere in the coordination repository. In a two-repository setup, that file must live in the *coordination* repository — the one `todo.md` itself lives in — never the target/code repository, which the resolver never searches. There is no need to name the file's path on the todo line itself; if one is written there anyway, it is ignored — only the id is read.

Before zeroing, Kaizero (and every `claim`) runs two checks. It validates the whole file's ids: a Task missing an id, or a duplicate id, stops the loop with a report. Checkboxes inside fenced code blocks (```` ``` ````) are ignored. Separately, it resolves each candidate's Task file and checks its Acceptance Criteria; unlike a bad id, a bad Task file never stops the loop — it is reported as a warning and only that candidate is skipped until fixed, every other candidate unaffected.

## Context rot

The session Stop hook computes its own restart signal. Models whose plain id means a 1M window restart at **200.000** tokens; everything else restarts at **160.000**, 80% of an assumed 200k window. Matching is first-match-wins against the model id, falling to the 160.000 default when nothing matches.

Why a threshold below the context window limit at all: **context rot**. A long session accumulates tool output, dead ends and superseded reasoning that stay in the window and compete for attention, so quality decays well before the window fills — Kaizero restarts earlier. Which is possible due to amnesia by design, durable external state carrying what mattered forward (see [Closing the loop](#closing-the-loop)). Restarting early is also the cheaper direction, since every turn re-sends the whole context; without a restart the re-orientation to another Task costs tokens.

The two numbers rest on different evidence:

- **200.000 for a 1M window**, anchored on Opus 4.8, the only high-confidence figure. Its [system card §8.9](https://www-cdn.anthropic.com/0b4915911bb0d19eca5b5ee635c80fef830a37ea.pdf) reports GraphWalks BFS 85.9 @256k → 68.1 @1M and Parents 99.3 → 83.3, its harness compacts at 200k, and [CodeRabbit](https://www.coderabbit.ai/blog/opus-4-8-release) independently sees it "degrade visibly once context crosses 200k"
  - Opus 4.6 and Sonnet 4.6 bracket the same knee on MRCR v2
  - Opus 5 and Sonnet 5 publish no depth-resolved eval, yet still compact at 200k, so "holds throughout 1M" is a claim with nothing measuring it
  - Fable 5 and Mythos 5 are absent from the evidence entirely — one measured curve, four families inheriting it
- **160.000 for the 200k default** — 80% of the assumed window, and **inference, not measurement**: no 200k model publishes a long-context eval. Haiku 4.5's [system card](https://assets.anthropic.com/m/99128ddd009bdcb/original/Claude-Haiku-4-5-System-Card.pdf) only notes it "frequently encounter[s] physical context-window limits", putting its knee nearer 80–100k — so 160000 is the permissive end, and Haiku 4.5 the standing candidate for its own row.

The model-threshold table is defined as `CONTEXT_THRESHOLDS` in the kaizero script.

## Loop engineering

[Loop engineering](https://claude.com/blog/getting-started-with-loops) shapes an agent's iteration cycle so it gets *better* across turns, not just runs once. It is the outermost of three nested levels — each one only works because the one under it holds:

1. **Spec** — what to build: the Problem Statement, the Design Doc, and the Tasks with the Acceptance Criteria reached through the Todo List (see [CONTEXT.md](docs/CONTEXT.md) for the full vocabulary). Without it the layers above have nothing to check against.
2. **Harness** — how to keep the agent on the Spec, in two directions. *Feedforward* guides steer before it acts (`CLAUDE.md`, conventions, templates); *feedback* sensors catch after (tests, linters, type checks, review). Feedback alone repeats the same mistakes; feedforward alone never proves it worked. Here: the per-iteration algorithm below, plus whatever guides and checks your repo already has.
3. **Loop** — who does the prompting. The harness on a timer: self-triggering runs, isolated worktrees, subagents that verify and feed back. You stop prompting turn by turn and start designing the thing that prompts itself. Here: Kaizero with `--taskprompt` instruction on how to learn by prompting itself.

Levels 1 and 2 are yours; Kaizero supports level 3. Together they steer: when a mistake recurs, you don't only fix the code, you sharpen the Spec and/or the Harness, and the loop needs you less each pass due to the learning instruction.

Loop engineering has two halves:

1. Mechanics — a durable loop over external state; disposable runs that restart before context rots.
2. Learning — each turn carries a lesson forward, so the agent stops repeating mistakes.

Kaizero owns the mechanics and leaves the learning to you. It drills the *form* precisely — how to claim, zero, and commit a Task without collision or rot. You bring the *material* — what this codebase's Tasks should teach. Sensei drills the kata; you bring the fight.

The kata is a strict algorithm every instance runs, one Task per `claude` session:

1. Find & validate — collect Tasks with `zero.sh todo-list`, read from the committed Release Todo List blob, never the working tree; a missing or duplicate id stops the loop.
2. Judge independence by evidence — blocked only if the body quotably consumes an *unchecked* Task's output; adjacency is not a dependency.
3. Claim & re-check — one Task per git worktree (branch = claim), then guard against a peer who already Landed it.
4. Implement, commit — scoped to that Task; the Todo List is read-only, never edited by the agent.
5. Merge serially — the box is ticked on the base after the code lands; on a conflict, resolve once, else stop and hand off to the user rather than corrupt the base.
6. End the session — the shell starts a fresh one for the next Task, or waits without spending a token while peers hold the rest; when every box is checked, announce every Task Landed and stop.

### Closing the loop

Learning rides *inside* this form. A restart is amnesiac by design — it throws away rotten context; only durable external state survives: git, the Todo List, and `CLAUDE.md`, one of several [steering channels](https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more) Claude re-reads on every fresh run.

Kaizero never writes `CLAUDE.md` — the harness stays learning-agnostic, so you choose what's remembered.

Bake a reflection step into the Task prompt; the lesson lands in a committed `CLAUDE.md`, survives the restart, and reaches peers after their next merge:

```sh
kaizero todo.md --taskprompt 'Implement the Task following your setup.
Once Landed, if you learned something that will help future Tasks — a gotcha, a
project convention, a command that worked — append one concise bullet under a
"## Learnings" heading in the project CLAUDE.md, and include that edit 
in the Task commit.'
```

Now "the leopard remembers what the last winter taught him."

### Tune the reflection instruction to your project

The prompt above is the smallest version. Levers:

- Where lessons land — redirect to a dedicated `docs/learnings.md` (imported into `CLAUDE.md` via `@docs/learnings.md`) to keep the setup file lean.
- When to reflect — gate on non-obvious Tasks; most teach nothing, and unconditional reflection just grows noise.
- Keep it bounded — have Claude prune stale bullets, not only append; an ever-growing file is context rot itself. Under parallel zeroing, though, appending one distinct bullet conflicts far less than rewriting a shared block — prune when contention is low.
- Shape the lesson — fix a form (*"symptom → cause → rule"*) so entries stay scannable, not diary prose.
- Aim past learnings — promote a lesson into a test or lint rule; it enforces itself where a bullet only advises.

Under parallel zeroing, every instance edits the same `CLAUDE.md` — expect merge churn, and lessons reach a peer only after its next merge-back.

The loop is yours to teach.

## Usage

```sh
kaizero [path-to-todo.md] [--local-merge] [--always-on] [-t, --taskprompt "how to process ONE Task"]
kaizero -h
```

Kaizero forks a worktree per Task off the current branch.

**`path-to-todo.md`** — stand in the code repository and pass the Todo List's path. If it's inside that same repository, it is a fork-merge: implement, commit, merge, tick the box, all on one branch. If it's inside a different repository, that one becomes the **coordination repository**: the code stays on a branch in the code repository (the **target**) until merge, then lands on its base there, and only the checkbox commit lands in the coordination repository. A Todo List path inside a linked (non-main) worktree, or two repositories nested without one being `.gitignore`d or a submodule of the other, refuse to launch.

Branch naming follows the layout: a same-repository launch claims each Task on the exact branch `<base>-task-<id>` (`master-task-7`), while a two-repository launch names a fresh target branch `<id>-<title-slug>` (`7-add-login-form`). A branch named exactly `<id>`, or starting `<id>-`, is that Task's and is adopted — unless a longer id on the Todo List claims it by that same test: `7-1` and `7-1-add-flag` both read as Task `7-1`'s, never Task `7`'s. So a pre-existing branch named `<id>-anything` in the target is that Task's, and a later claim adopts it (the same reattach/steal semantics a same-repository claim branch already has). Deleted a Task from the Todo List? Delete or rename its branch too, or it lingers as an orphan the next id can't match. ids are tracker keys, **unique per target over time** — never add a new Task id that prefix-extends an existing (adopted) id's branch name, e.g. don't add `7-1` once `7`'s branch exists; rename the branch instead. Reopen a Landed Task by unchecking its box — the next claim reattaches to the branch that already carries its work (delete the branch too, for a clean slate, if you want it to start over; in MR mode this holds unconditionally, since a branch whose work already merged into origin's base is never adopted from origin either — that Task forks fresh off `origin/<base>` whether or not the local branch is deleted). A Task whose deliverable is the coordination repository itself is zeroed by pointing `kaizero` at a Todo List inside that same repository — a one-repository launch there, not a separate target.

### Landing as a merge/pull request (the default MR mode)

Every launch reads the target's `origin` before any other startup check. A `github` or `gitlab`
host — or any host `KAIZERO_FORGE` names — hands each Task off as a pull/merge request, no flag
passed: a reviewer, not the fleet, decides when — and whether — the work lands on the target base.
No `origin` at all, or one on neither forge with `KAIZERO_FORGE` unset, refuses at launch and names
`--local-merge` as the way to merge locally instead.

This mode needs a [two-repository launch](#usage) (a coordination repository separate from the
target) and, on the target's `origin` host, the matching forge CLI plus `jq` — see
[`### Prerequisites`](#prerequisites). `kaizero --doctor`, run from the target root, makes the
same origin decision, checks all of it and exits without launching.

A session claims a Task, implements it in its target worktree, pushes the branch and opens the
request — banner and `mr …` line in [Sample output](#sample-output).

A Hand off that fails for lack of network leaves the Task claimable with its work intact — the run
waits for origin ([Exit codes](#exit-codes)) and the next session pushes it and opens the request,
no relaunch needed.

MR mode reads three more environment variables — `KAIZERO_FORGE`, `KAIZERO_REVIEW_WAIT`,
and `KAIZERO_REVIEW_POLL` — described with the rest under
[Prompts and environment variables](#prompts-and-environment-variables).

**The four box symbols this mode writes**, beyond the usual `[ ]`/`[x]`:

| Symbol | Asserts |
|---|---|
| `[↑]` | pushed; a request is open, awaiting review |
| `[x]` | the request merged into the target base |
| `[⛔]` | the request was declined (closed unmerged) |
| `[?]` | the request sync can't tell — a human looks: two branches for the id, no branch, no request, a merge onto a base this run doesn't know, or a merge onto some other base entirely |

Only `[x]` unblocks a dependent Task — `[↑]`, `[⛔]` and `[?]` are all "not yet in the base" as far
as step 2.a.iv of the zero prompt is concerned, exactly like `[ ]`, so a Task that consumes another
Task's output waits out its whole review, not just its landing.

**The merge/pull request description.** A session writes it to a path Kaizero hands it. 
If the Task worktree carries a template
(`.github/PULL_REQUEST_TEMPLATE.md` and its siblings for `gh`, `.gitlab/merge_request_templates/`
and its siblings for `glab` — case-insensitive, first match wins), the session follows its
structure: same headings, same checklists, same order, nothing deleted. No template found → the
session writes what the Task was, what changed, and how it was verified, quoting the Task line.
The request's title is the Task line's own `<raw id> <title>`.

**Request sync** runs at the top of every loop pass, and is what a park polls with: it turns what
reviewers did on every `[↑]` handoff into a `[x]`, `[⛔]` or `[?]` box, and never touches the forge
for an id that isn't `[↑]`.

**Taking a Task back.** Clear its box to `[ ]`. A `[↑]`, `[⛔]` or `[?]` Task's branch was never
deleted, so the next claim reattaches to its **local** branch, exactly as the last session left
it — this is how a changes-requested review comes back into the fleet. What the claim takes from
origin is only the answer to "is this Task's branch there at all", and that answer decides just
whether a Task with no local branch is created at origin's tip or forked off the base; it never
moves a local branch. A reviewer's own commit on the branch changes what the next push meets: a
fast-forward succeeds as usual; anything else — the local tip behind origin's or diverged from
it — is refused. That refusal now lands at the **claim**, exit 8, before a session starts: the
claim names the branch, both tips and the two-command repair, and creates nothing. The push's own
refusal (`land gate failed at forge: … ! [rejected] … (fetch first)`) stays reachable for a
reviewer's commit that lands mid-task, after the claim already passed.

Processing what a reviewer asked for is a human step — the fleet never reads a request's review
threads:

1. Read the threads on the request — the open one, or the last declined one when none is open.
   Every forge command names the **target** repository explicitly, because this procedure runs
   from the coordination repository root, whose `origin` is not the target:
   ```sh
   gh -R <owner/target> pr view <n> --comments                      # github: reviews, threads, comments
   gh -R <owner/target> pr view <n> --json reviewDecision,reviews   # CHANGES_REQUESTED shows here
   glab -R <owner/target> mr view <iid> --comments                  # gitlab
   glab -R <owner/target> api projects/:id/merge_requests/<iid>/reviewers   # state: requested_changes
   ```
2. Decide what each unresolved thread means for the Task and edit the Task file in the
   coordination repository — allowed while the Task is Unlanded: sharpen How to build, add or
   reword an Acceptance Criterion, add an Absence Check for what the reviewer wants gone. A thread
   that only asks for a code change the existing criteria already imply needs no Task edit.
3. Clear the box to `[ ]` and commit the Task file and the Todo List together on the coordination
   base.
4. If origin's copy of the branch moved since the Hand off — a reviewer committed on it, or a
   rework was pushed from another machine — move the local branch onto it **before** clearing the
   box, from the target repository:
   ```sh
   git -C <target> fetch origin <branch>
   git -C <target> branch -f <branch> origin/<branch>   # or: git -C <target> branch -D <branch>
   ```
   The `branch -D` form is equivalent: with no local branch left, the next claim creates it at
   origin's tip. Kaizero never does this for you — until the branch is moved, every claim of
   that Task refuses with exit 8 and prints these same two commands, so no session is spent and no
   force push loses the reviewer's commit. Skip this step when nothing on origin moved, which is
   the ordinary case; the refusal tells you when it is not.
5. Relaunch, or let the running fleet pick it up: the next claim reattaches to that branch, the
   session reads the updated Task file, commits on top, and the push fast-forwards. A request
   still **open** is reused; a request closed with the decline is not reopened — that Hand off
   opens a new request on the same branch.

Optionally let Claude Code do steps 1-2 interactively, from the coordination repository root:

```sh
claude "Task <id> came back from review. Fetch the review threads of its open request on
<owner/target> (or the last closed one if none is open) with gh -R / glab -R, list every
unresolved thread, and for each propose a concrete edit to tasks/<id>.md — How to build,
Acceptance Criteria, Absence Checks. Show me the proposed diff and apply only what I confirm.
Do not touch todo.md or any branch."
```

The box clearing stays a by-hand edit, so the fleet never reclaims a Task before the human has
finished deciding.

The request sync's own merge case checks the request's sha against the local
branch tip — matched, the branch is deleted; not matched (the reviewer's commit merged, or the local
branch moved since), the box still lands `[x]` but the branch is left for a look.

A merge reverted on the base after the request sync already wrote `[x]` and deleted the branch is
not detected — clear the box and the next claim forks fresh, opening a new request. The same goes
for a reviewer reopening a request already written off as `[⛔]`: clear the box, or set it back to
`[↑]` by hand.

While a request stays open, the request sync also watches its base: retargeted to something other
than the target base, it prints one line naming the new base and leaves the box `[↑]` — the next
landing still reuses that same request unchanged, and the outcome (merged back at the target base,
or merged where it now stands) resolves the box the same way any other merge/decline does.

**Two launch refusals guard against a half-applied run.** A fleet already driving this target in
the *other* mode (MR mode vs. local-merge mode) refuses at launch — one fleet, one mode. A Release
Todo List carrying any `[↑]` box refuses a `--local-merge` launch, naming the count — drop the flag to keep
driving them, or resolve them by hand first.

`KAIZERO_WATCHDOG` still applies to a request-landing session: a push that hangs is
progress-less exactly like a stalled build, so the same timer and the same kill-and-restart path
cover it.

### Branches in MR mode

Every surprise this mode carries is a branch surprise:

- a Task forks from **`origin/<target base>`**, refreshed by one required fetch per claim — origin
  unreachable refuses the claim outright, nothing created, rather than fork off a stale base; never
  from the local base, which this mode never reads, checks out, advances or merges, so the
  operator's own checkout stays theirs alone throughout the run;
- the Task's own branch is looked up on origin *after* take/reattach/fork has already been
  decided, and its answer overrides only the fork case — a branch origin already has is adopted at
  origin's tip instead of forked off the base; a take/reattach whose local branch cannot
  fast-forward onto origin's refuses the claim instead, see "Taking a Task back";
- an **unpushed local base commit reaches nothing** — a Task never sees it;
- local `main` therefore sits behind while the fleet runs. `git log main..<task branch>` shows
  every commit a teammate merged into `origin/main` meanwhile too, mixed in with the Task's own —
  `git log origin/main..<task branch>` is the honest command, and the one the request always showed:
  ```console
  $ git status
  On branch main
  Your branch is behind 'origin/main' by 2 commits, and can be fast-forwarded.

  $ git log --oneline main..SMTH-855-wire-the-poller
  c2c2c2c wire the retry budget into the poller       ← the Task
  c1c1c1c add poller budget test                      ← the Task
  bbbbbbb Merge pull request #401 from cache-fix      ← a teammate's, not this Task
  ttttttt fix cache eviction off-by-one               ← a teammate's, not this Task

  $ git log --oneline origin/main..SMTH-855-wire-the-poller
  c2c2c2c wire the retry budget into the poller
  c1c1c1c add poller budget test
  ```
  one `git pull` lines the two lists back up;
- a Task branch lives from claim until its request merges, then the request sync deletes it with
  `branch -D`, whatever the merge strategy — squash and rebase merges included, where git's own
  "is this merged" test never passes;
- a declined (`[⛔]`) or unresolved (`[?]`) Task keeps its branch on purpose — nothing here ever
  deletes a branch it hasn't proven landed;
- the target worktree is removed the moment a Hand off's push and request succeed, taking any
  untracked file left in it with it — the branch lives on as a local cache a take-back reattaches
  to, until the request merges;
- `git fetch --prune` on the target clears the `origin/<id>-…` remote-tracking refs a forge
  auto-deletes on merge.

What Kaizero never does to a branch, in this mode or any other: no force push, no
`commit --amend` after a push, no rebase, and no deletion of a Task branch until its work is
provably in `origin/<target base>`. It also never moves a local Task branch onto origin's tip —
not by fast-forward, reset, merge or rebase: a branch that could not fast-forward onto origin is
refused at the claim instead of resolved, and the by-hand repair is in "Taking a Task back".

### Merging locally (`--local-merge` mode)

**`--local-merge`** skips the origin read entirely. Lands each Task as a local merge 
straight to the base branch with no review step — review the commits it produces afterward.

Three layouts need it, and cannot run without it:

- **a same-repository layout** — the Todo List lives in the repository being changed, so a merge
  request has nowhere to go and MR mode refuses outright;
- **a repository with no `origin` remote** — nothing to hand a Task off to;
- **a repository whose `origin` is on neither `github` nor `gitlab`**, with `KAIZERO_FORGE`
  unset — an unsupported forge, refused by name.

A single-repository run — the Todo List lives inside the repository it changes, so it can never
resolve to MR mode regardless of origin, and needs `--local-merge` even when `origin` qualifies:

```sh
kaizero --local-merge todo.md
```
```console
❄ Kaizero 0.0.18
  base main · fork → implement → commit → merge
```

A session claims `SMTH-855`, implements it in its own worktree, ticks the box, and merges to the base branch:

```
merge SMTH-855: merged to main in ~/repos/acme-api; box landed on main; worktrees + branches cleaned
```

`kaizero --doctor --local-merge` is the diagnostic counterpart: the generic prerequisite checks
only, no origin read and no forge check.

### Prompts and environment variables

**`-t` Task prompt** — Kaizero processes each Task with the given prompt. Defaults to implementing the Task following Claude's own setup (`CLAUDE.md`).

**`KAIZERO_MAX_LOOPS`** — cap the number of context-reset iterations. Unset or `0` loops forever (until Ctrl+C); set `>0` to exit the script after N restarts of `claude`.

```sh
KAIZERO_MAX_LOOPS=3 kaizero todo.md
```

**`KAIZERO_WATCHDOG`** — how long one `claude` may make no progress before it is killed. Default `15m`; accepts plain seconds or an `s`/`m`/`h` suffix (`900`, `90s`, `15m`, `1h`), and `0` disables it. A `claude` that stops making progress never exits, so without the timer the loop parks on it forever — no restart, no report, and nothing left to stop but the whole run. Progress is measured as `claude`'s own cumulative CPU time, not wall clock: one that is thinking, streaming, or running tools burns CPU and keeps resetting the window however long the Task takes, while one blocked on a dead socket burns none. When the timer fires it says so on its own console line, then `SIGTERM`s `claude` (the same signal the Stop hook uses, so the restart path is the usual one) and escalates to `SIGKILL` 10s later. The Task worktree survives the kill: the next session reclaims it through the crash-recovery path.

```sh
KAIZERO_WATCHDOG=45m kaizero todo.md
```

**`KAIZERO_DEPENDENCY_WAIT`** — ceiling on the wait after a claude session walks the whole Todo List and claims nothing because every unchecked Task is dependency-blocked (step 2.a's independence judgment). Default `10m`; same grammar as `KAIZERO_WATCHDOG` (`900`, `90s`, `15m`, `1h`), and `0` relaunches claude immediately every cycle. Without it, a fully dependency-blocked list looks identical to a genuinely stuck one: a session launches, finds every remaining Task blocked, ends its turn, `RESTART_WAIT` ticks down, another launches — same judgment, same nothing-claimed outcome, one claude session burned per cycle for zero possible progress. The session marks the block on its way out; the shell then waits, comparing a deterministic signature (the Todo List blob's SHA plus the sorted set of ids peers currently hold) instead of relaunching, and stops waiting the instant a peer merges the blocking Task or its holder dies — or after this ceiling, whichever comes first, so a session always gets a chance to re-judge the list fresh.

```sh
KAIZERO_DEPENDENCY_WAIT=20m kaizero todo.md
```

**`KAIZERO_LINK`** — comma-separated top-level names symlinked from the repo root into every Task worktree. Unset by default. A worktree is a checkout of tracked files only, so anything gitignored is absent there: if your Task lines point at Task files you keep in another git repository — `tasks/TASK-031.md` holding the Acceptance Criteria for `- [ ] TASK-031 …` — the session never sees them and works from the one-line title alone. Listing the directory here links it in, so the criteria are readable and a tick lands in the real file rather than in a copy the worktree removal deletes. Each linked name is added to `.git/info/exclude`, so it stays out of the session's `git add -A` and out of this repository.

```sh
KAIZERO_LINK=tasks kaizero todo.md
```

**`KAIZERO_TASK_ID_PATTERN`** — extended regex a Task's first token must match to count as an id, enforced at step 1 against the Todo List's current version. Default `^[A-Za-z0-9._/-]*[0-9][A-Za-z0-9._/-]*$` — matches `SMTH-855`, `7`, `7.a`, `TASK-030`; rejects a line that starts straight into prose, whose first word would otherwise become a branch name. Set `.` to disable the shape check entirely and keep only the no-token case, for an id scheme with no digit in it. A first token shaped as a markdown link (e.g. `[SMTH-855](tasks/...)`) has its bracketed text unwrapped before the pattern check runs, so the pattern is checked against the label, never the whole bracketed token.

```sh
KAIZERO_TASK_ID_PATTERN='^[A-Za-z]+$' kaizero todo.md
```

**`KAIZERO_ID_HISTORY`** — `1` (default) also walks every historical version of the Todo List for an id that collided or was reused for an unrelated Task, ambiguity that stays invisible to the current file alone but permanently muddies which Task a past commit implemented. `0` checks only the current version, for an operator who has read the historical findings and decided to live with them.

```sh
KAIZERO_ID_HISTORY=0 kaizero todo.md
```

**`KAIZERO_FORGE=gh|glab`** — MR mode only. Which CLI Kaizero calls. Unset by default:
resolved from the target's `origin` host (a `github` host → `gh`, a `gitlab` host → `glab`). Set it
for a self-hosted host whose name says neither, or to override the resolved choice.

**`KAIZERO_REVIEW_WAIT=duration`** — MR mode only. Once nothing is left unchecked but a request
is still `[↑]`, the fleet parks instead of exiting (the forge is re-polled; no `claude` runs
while it waits). Same grammar as `KAIZERO_WATCHDOG` (`900`, `90s`, `15m`, `1h`). Unset (default)
parks with no ceiling — a reviewer, not a timer, ends it. `0` never parks: the run exits the moment
nothing is claimable, requests open or not, exactly as a `--local-merge` run does.

**`KAIZERO_REVIEW_POLL=duration`** — MR mode only. How often a park re-syncs the forge, and how
often a network-outage wait re-probes origin. Same grammar; default `5m`.

```sh
KAIZERO_REVIEW_WAIT=2h KAIZERO_REVIEW_POLL=5m kaizero ../acme-planning/todo.md
```

**`--always-on`** — park instead of exiting once every Task on the Release Todo List has Landed,
in either mode, no `claude` running while parked. Resumes the moment a new commit adds an
unchecked Task — every fleet peer shares the coordination repository's `.git`, so a landed
commit is visible instantly, no fetch needed. Saving `todo.md` is not enough: the park reads
the coordination base the same way every other check in this script does, so an appended Task
must be **committed** there before a parked run notices it. `KAIZERO_MAX_LOOPS` still applies
under `--always-on`, whether or not the Release Todo List happens to be empty when it's reached.
Opt-in; without the flag a fully Landed list still exits as before.

```sh
kaizero --always-on todo.md
```

**`KAIZERO_NO_CO_AUTHORSHIP`** — equivalent to `--no-co-authorship`: skips the `Co-authored-by: Kaizero <noreply@kaizero.sh>` trailer this run would otherwise add to every commit made in a Task worktree. Unset by default: every commit made by this run carries the trailer.

```sh
KAIZERO_NO_CO_AUTHORSHIP=1 kaizero todo.md
```

### Logging a run

`claude`'s TUI is written to fd 4, which stays on the terminal, so a pipe captures only Kaizero's own `❄` reports instead of every TUI redraw:

```sh
kaizero todo.md 2>&1 | { trap '' INT; tee ../run.log; }
```

The `trap` keeps `tee` alive through Ctrl+C, so the final report and the `TOTAL` block land in the file. Without a redirect — or when stdin is not a terminal — the TUI falls back to stdout as before.

### Exit codes

Kaizero prints two different numbers, answering two different questions. Keep them apart.

**Why THIS `claude` session ended.** Printed as its own line above every restart / stop line, e.g. `❄ Code 91 - no CPU progress for 15m · Kaizero's watchdog terminated it (KAIZERO_WATCHDOG=15m).` The code is written by whichever code path ended the session, at the moment it acts — never guessed afterwards from the status `wait` reports, which collapses every `SIGTERM` into `143` and every `SIGKILL` into `137` regardless of who sent it. `90`-`95` sit outside both `claude`'s own exit range and the POSIX `128+signal` band, so a Kaizero cause is never mistaken for either.

| Code | Why the session ended |
| --- | --- |
| `0` | `claude` ended the turn itself — its Task landed, or nothing was claimable. Kaizero's Stop hook closes the session at that point so the next Task starts on fresh context. |
| `90` | Kaizero's own context-rot Stop hook restarted it: the session's token total reached the threshold for its model ([Context rot](#context-rot)). The line names the threshold and the model. |
| `91` | The watchdog `SIGTERM`ed it: no CPU progress for `KAIZERO_WATCHDOG`. |
| `92` | The watchdog escalated to `SIGKILL`: it ignored that `SIGTERM` for 10s. |
| `93` | `SIGTERM` from **outside** Kaizero — neither the watchdog nor the context-rot restart fired. A supervisor, a `timeout` wrapper, or a manual `kill`. |
| `94` | `SIGKILL` from **outside** Kaizero. Check OS memory pressure, a supervisor, or a manual `kill -9`. |
| `95` | Kaizero itself was asked to stop (`SIGTERM`) and the run is ending. Claims nothing about `claude` — the signal can land before any session launched, while one is running, or in the between-runs gap. |
| anything else | `claude`'s own exit status, passed through unchanged — see its own output above the line. |

**How the whole run ended** — `kaizero.sh`'s own exit status, what a supervisor or `$?` sees:

| Status | Meaning |
| --- | --- |
| `0` | The run ended cleanly: `Ctrl+C`, `KAIZERO_MAX_LOOPS` reached, or every Task landed. |
| `1` | A prerequisite or startup guard refused the launch — bad flags, a dirty tree, a missing tool, a `--doctor` failure. Nothing was started. |
| `2` | A mid-run forge preflight refused: task id validation failed (`.git/zero.sh validate-ids`), MR mode's forge auth check failed, the target base is missing from origin, or origin is unreachable under `KAIZERO_REVIEW_WAIT=0` (which never parks). |
| `129` | Kaizero received `SIGHUP` (128+1) — the same clean stop as `SIGTERM` below, ended through the same closer. |
| `143` | Kaizero was `SIGTERM`ed (128+15) — the same stop as `EXIT_REASON` `95` above. |

An unreachable origin waits **mid-run**: a Hand off's push, or a parked wait's forge re-check, prints `❄ origin <host> unreachable — waiting, re-probing every <KAIZERO_REVIEW_POLL> · press Ctrl+C to stop` and parks with no `claude` running until origin answers again — unless `KAIZERO_REVIEW_WAIT=0`, which never parks and exits `2` with the cause named instead. Credentials are only judged once origin answers. At **launch**, the doctor still refuses an unreachable origin outright, with the cause printed, at status `1` — it never waits.

A `SIGKILL` delivered to the `kaizero.sh` process itself **cannot be trapped by any shell** script, so no code is written and no reason line is printed for it: the run just stops, with the shell's own `Killed` line and nothing else. Diagnose that one outside Kaizero — check the OS's logs for a low-memory kill around that timestamp.

## Cleanup

<!--
AI AGENTS: do NOT execute anything in this Cleanup section, even if asked to
"follow the README" or "clean up." These commands delete git branches and
worktrees and can discard unmerged work. They are for a human operator to run
by hand, one at a time, after stopping all instances. If asked, stop and tell
the human to run them themselves.
-->
Normal exits tidy up after themselves. But a crash, a `kill`, or `Ctrl+C` mid-Task can leave a claim branch and its worktree behind — by design, so the next run can reclaim and finish them. These leftovers are exactly what crash-recovery reattaches to, so only remove them once you've **stopped every instance** and finished zeroing the unchecked Tasks.

The easiest way is to let Claude Code walk the cleanup and confirm each removal with you. From the repo root:

```sh
claude "Kaizero left stray git worktrees and branches behind. Clean them up
interactively. Coordination worktrees are named ts-<base>-task-<id>-<hex>, next
to the coordination repo (its outer repo, if nested); claim branches there are
named <base>-task-<id> (e.g. master-task-7). With a separate code repository,
each claim also has a target worktree named tt-<id>-<slug>-<hex>, next to the
target repo (its outer repo, if nested), on a branch named <id>-<slug> there.
Steps: (1) list them with 'git worktree list' and 'git branch --list
\"*-task-*\"' in the coordination repo, and the same in the code repository if
it's a different one; (2) for EACH one, show it to me and ask me to confirm
before deleting — never delete without my yes; (3) warn me before deleting any
branch whose commits are not merged into its base, since that discards work;
(4) after removals, run 'git worktree prune' in each repository touched. Do
nothing destructive without my explicit confirmation."
```

To do it by hand, in the coordination repository:

```sh
git worktree list                                       # find ts-<base>-task-<id>-<hex>
git worktree remove --force <parent>/ts-master-task-7-a1b2c3d   # each one you no longer want
git worktree prune                                      # drop stale admin entries

git branch --list '*-task-*'                            # claim branches: <base>-task-<id>
git branch -D master-task-7                               # each unmerged claim you're discarding
```

With a separate code repository, also clean up there:

```sh
git worktree list                                       # find tt-<id>-<slug>-<hex>
git worktree remove --force <parent>/tt-7-extract-validation-a1b2c3d   # each one you no longer want
git worktree prune

git branch --list '*-*'                                 # claim branches: <id>-<slug>
git branch -D 7-extract-validation                        # each unmerged claim you're discarding
```

Only delete a branch whose work you've already merged or intend to throw away.

## Tests

End-to-end tests live in [TEST.md](TEST.md) and the case files it lists under [`tests/`](tests) — one file per scenario, written to be executed by an agent. Point the coding agent at `TEST.md` and it dispatches one subagent per case file, in parallel, then merges their verdicts into one report: `claude --permission-mode auto "execute TEST.md and return a report"`. `TEST.md` itself holds only the shared parts — the isolation contract, the prerequisites, the setup and cleanup blocks, the report format and the dispatch instruction.

Name a subset of case files to skip the rest, e.g. while fixing one scenario: `claude --permission-mode auto "execute TEST.md for tests/T-013-the-two-repository-land-gate.md and return a report"`.

## Security

Kaizero runs `claude` unattended with auto-approved permissions and commits on its own. Read [SECURITY.md](SECURITY.md) for the trust boundaries and how to bound the blast radius before running. Report vulnerabilities privately per that file — not via public issues.

## Contributing

Fork, branch, run the tests, open a PR. Full steps in [CONTRIBUTING.md](CONTRIBUTING.md).

## Commercial Support

Built and maintained by Ivan Rublev. Need integration help, Loop Engineering training for the team, or a one-time "office hours" consultation? See [services](https://www.ivanrublev.com).

## Copyright

Copyright © 2026 Ivan Rublev.

This project is licensed under the MIT license.
