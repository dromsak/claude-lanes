---
name: lanes
description: Run the lanes orchestrator. This session keeps three worker subagents busy on ready GitHub issues, each in its own git worktree, reviews every PR, and lands approved ones through a merge train until told to stop. Use when the user says /lanes, "fill the lanes", "run the lanes" or "work the backlog". `/lanes init` sets a repository up.
---

# /lanes: the orchestrator loop

From now until the user says **stop**, this session is the **orchestrator**. It writes no product code. It keeps the lanes busy, reviews every diff, lands approved work through the train, and keeps a ledger.

**Why this shape.** The session's model is the expensive one, so it only plans, reviews and decides. Implementation runs on `lanes:lane-worker` (Sonnet) and wide reading on `lanes:lane-reader` (Haiku, read-only). Each worker owns a git worktree, so three issues move at once without touching each other's files. The worker's reading stays in its own context; only its report comes back here.

**The tool.** `lanes` is on the Bash PATH while this plugin is enabled. If it is not, use `${CLAUDE_PLUGIN_ROOT}/bin/lanes`, and put that absolute path in worker briefs.

| Command | What it does |
|---|---|
| `lanes init` | create the lane worktrees (`<repo>-lanes/lane-N`, beside the repo) |
| `lanes status` | each lane, free or leased, and the configured gate |
| `lanes acquire <branch>` | lease a free lane on `<branch>` (resumes from `origin/<branch>` if it exists); prints the lane path |
| `lanes release <n>` | reset lane `n` to main and free it; refuses while it holds unpushed work |
| `lanes gate` | run the merge gate in the current directory |
| `lanes train <branch>...` | for each branch in its own worktree: rebase onto main, run the gate, merge, delete the branch |

Settings are git config keys: `lanes.gate` (required), `lanes.count` (3), `lanes.main` (origin's HEAD), `lanes.merge` (`squash`, `rebase` or `merge` through `gh`; `push` for a plain fast-forward), `lanes.base`.

## `/lanes init`: one-time setup per repository

Run this when the argument is `init`, or when start-up finds no lanes or no gate. Then stop.

1. Check: inside a git repository whose `origin` is on GitHub, `gh auth status` logged in, `git --version` 2.31 or later.
2. **The merge gate** is the one command that must pass before anything lands: tests plus lint or type checks, whatever this project treats as "green". Look in `CLAUDE.md`, the README, `package.json` scripts, `Makefile`, `justfile`, `pyproject.toml` and CI workflows. Propose it to the user with `AskUserQuestion`, then `git config lanes.gate '<command>'`. If main is protected against direct pushes, keep `lanes.merge` on `squash`; otherwise ask whether they prefer squash or `push`.
3. `lanes init`; `lanes status` must list every lane.
4. Labels, created if missing (`gh label create <name> --description <text> || true`): `ready-for-agent` (the queue), `needs-triage` (waits on a human decision), `dont-touch` (never worked by agents).
5. Tell the user: setup done. Agent definitions load at session start, so if the plugin was installed in this session, restart Claude Code before `/lanes`.

## 0. Start-up (each invocation)

1. **Ledger.** Read or create `ledger.md` in the lanes base directory (the first line of `lanes status`). It records in-flight lanes (issue, branch, time), the train queue, what landed, the issue queue and process notes. Update it on every event. It is what survives a context compaction.
2. `lanes status`. A lane leased by someone else stays theirs.
3. **Queue.** `gh issue list --state open --label ready-for-agent --search '-label:dont-touch' --json number,title,labels --limit 100`. Never touch a `dont-touch` issue. `needs-triage` belongs to the user. Order: broken behaviour and failing CI first, then data or security correctness, then features, then chores.
4. Tell the user in three lines what is starting.

## 1. Dispatch

For each free lane:

1. **Pick an issue that does not overlap an in-flight lane** (same files, module, table or page). Overlapping issues run one after the other; note the dependency in the ledger.
2. **Scope before dispatch.** Before an issue reaches a lane, its leads are verified, and every file, function, test file and module it touches is listed with `path:line` in a `## Scoped` comment on the issue (`gh issue comment`). Over about five modules, split the issue first.
   - **Small scope** (a failing test with a name, a one-module change): run the handful of greps yourself and post the comment. A reader round trip costs more than it saves.
   - **Wide scope** (a trace across modules, an epic audit, a long log): send `lanes:lane-reader` the issue text and the question, then post its answer.

   Either way, read enough yourself to write the brief. Workers never call the reader, because their own reading is where the judgement happens.
3. `lanes acquire <type>/<N>-<slug>` (for example `fix/42-empty-cart`), which prints the lane path.
4. `Agent` with `subagent_type: "lanes:lane-worker"`, `run_in_background: true`, and **no `model`** (the agent sets Sonnet). The brief carries:
   - The lane path and branch, already leased.
   - The issue number, and "address every acceptance item".
   - **Leads** you verified, as `path:line`, marked "verify, don't trust". Existing helpers to reuse.
   - The constraints that decide the issue: a design record, compatibility, performance, security.
   - **The checks to run**: the project's focused test commands for what it touches, then `lanes gate`.
   - **If the cause is a hypothesis, the fork, not a fix:** "find out which it is; if X, fix the code; if Y, fix the test; report which, with evidence". A prescribed fix built on a wrong guess either fails or gets built anyway.
   - Known overlap with other lanes.
   - The commit trailer and PR footer, if the user uses attribution lines.
5. Record the dispatch in the ledger and tell the user in one line.

**Escalate** (`model: "opus"` on the Agent call) only when a lane has failed the same issue twice, or the work needs design-level judgement.

### Keeping the lanes full

Most of a lane's wall time goes on the worker reading code and making edits. Builds and tests are usually a few minutes of it; check your own project's numbers once. So extra lanes help only with **file-disjoint** work. Splitting one tightly coupled change three ways makes each worker read the same context, adds rebase conflicts, and still ends in the same serial review and train.

- **One big issue (an epic):** slice it by the files each part owns, not by feature. Dispatch the disjoint slices together and queue the dependent ones in the ledger. Each slice's PR says `Part of #N`, and you tick the slice off in the issue body when it lands.
- **Decisions ahead of the lanes:** while the current slices run, ask the user for the calls the *next* slices need (§4), so a lane that frees up never waits for an answer.
- **Overlap you can't avoid:** name it in both briefs. When one lands, `SendMessage` the other worker a rebase heads-up that names the files that moved.
- **Several small fixes in one area** (two failing tests from one CI run): one branch, one lane. A lane per trivial item pays its reading and review twice.
- **The queue about to empty:** prepare the release, such as the notes and changelog, while the last fix runs, then ask about the release in the same question batch as any open decisions.

## 2. Review (on each worker report)

A worker stops at a pushed PR. Review before anything lands:

1. `git -C <lane> fetch -q && git -C <lane> diff origin/<main>...HEAD --stat`, then read the diff of the logic. Skim fixtures and generated files.
2. Check:
   - The fix sits at the root, in the shared place, not at each call site.
   - Every acceptance item is done or explicitly left open with a reason.
   - New tests were fault-injected (the report names which assertion failed for which break).
   - `lanes gate` ran green on the final commit, shown by real output, not a claim.
   - No new trust holes: input escaping, authorisation, injection, secrets.
   - Nothing outside the scope, and no stray files.
3. **Send it back** (`SendMessage` to the worker) only for a real defect. Say exactly what is wrong and what shape you want.
4. **Approve:**
   - `lanes release <n>` and dispatch the next issue into that lane straight away.
   - Add the branch to the train queue in the ledger.
   - File follow-ups the worker surfaced: `ready-for-agent` when fully specified, `needs-triage` when a human must decide.
   - Tell the user in one or two plain lines what the PR fixes.

## 3. Merge train

- When the queue is non-empty and no train is running: `lanes train <branch>...` with `run_in_background: true`. It lands branches one at a time in its own worktree, so the user's checkout is never switched. It prints one `TRAIN <branch>: LANDED|FAILED (<why>)|SKIPPED` line per branch.
- Read only the `TRAIN` lines. On `FAILED`, read the output just above that line.
- **LANDED:** check the issue closed (`Fixes #N` closes it on merge). If not, `gh issue close <N> --comment "<sha>: <one line of evidence>"`. A partial fix gets a comment naming what landed and what stays open.
- **FAILED:** `lanes acquire <same branch>` (it resumes from `origin/<branch>`) and dispatch a worker with the failure text.
- Never merge by hand while a train runs.

## 4. Talking to the user

- Short status lines on each event: what landed, what is running, what needs them. Plain language, result first, with a running tally.
- Decisions that are theirs (product behaviour, scope, anything hard to undo) become a `needs-triage` issue. Keep working, and list the open ones in status updates.
- **Ask with `AskUserQuestion`, never in prose.** Never end with "tell me which", and never list "waiting on you" items without asking them in the same turn. Ask only when work can't move on a sensible default.
  - Batch up to four questions. Put the Recommended option first. Give a design choice an ASCII `preview` for each option.
  - Record each answer on its issue.
- **When the user is away** (outside the hours they gave you, or simply not answering), don't let a question stall the lanes. Take the reversible Recommended default, post it on the issue as an assumption, and confirm it in the next batch.
- Never tag a release, force-push shared history, or touch secrets without asking.

## 5. Learning

- A worker slip that repeats goes into the project's `CLAUDE.md` (a "Working in a lane" section), so every later worker reads it. Plugin files are overwritten on update; do not edit them.
- Keep the ledger honest. Never claim a lane is running or a check passed without the notification or output to show it.

## 6. Stop

On "stop":

- Dispatch nothing new.
- Let in-flight workers finish to a PR, review them, and run a final train.
- Release every lane you leased.
- Report: issues closed, follow-ups filed, decisions waiting on the user, and any slips worth remembering.
