# lanes

Work a GitHub issue backlog three at a time with Claude Code, without paying top-model prices for every token.

- **One orchestrator.** Your main session picks issues, writes briefs, reviews diffs and decides what lands. It never writes product code.
- **Three lanes.** Each lane is a permanent git worktree, so three workers edit, build and test at once without touching each other's files.
- **Cheap models where they suffice.** Workers run on Sonnet; a read-only Haiku reader scopes each issue before dispatch. The expensive model reads briefs and diffs, not the codebase.
- **A merge train.** Approved branches land one at a time: rebased onto main, run through your test gate, then merged. A red branch lands nothing and goes back to a lane.

It works with any language. The only project-specific input is your **gate**: the one command that must pass before anything lands (`npm test`, `pytest && ruff check`, `cargo test`, `go test ./...`, `make check`).

## Why it saves tokens

| Work | Who does it | Model |
|---|---|---|
| Scoping an issue: finding every file, caller and test it touches | `lane-reader` | Haiku, read-only tools |
| Implementing, testing, opening the PR | `lane-worker` | Sonnet |
| Choosing work, writing briefs, reviewing diffs, landing | your session | whatever you run (Opus recommended) |

Each worker's file reading, test output and retries stay in its own context. The orchestrator only sees the brief it wrote and the report that comes back, so its context stays small enough to run a whole backlog in one session.

## When three lanes help

Most of a lane's time goes on the worker reading and editing, not on builds. Three lanes beat one only when they work on **different files**. When the backlog is one big issue, the orchestrator slices it by the files each part owns and runs the disjoint slices at once. It asks you for the next slices' decisions while those slices run, and it bundles small fixes in the same area into one lane. Splitting one tightly coupled change three ways is slower: every worker reads the same context, and the pieces collide when they land.

## The loop

```
ready-for-agent issue
  → lane-reader scopes it (posted on the issue as "## Scoped")
  → lanes acquire  → lane-worker implements in its lane → pushed PR
  → orchestrator reviews (sends back, or approves and releases the lane)
  → lanes train: rebase → gate → merge → branch deleted → issue closed
```

While one lane is in review, the next issue is already dispatched into the lane just released.

## Install

```
/plugin marketplace add dromsak/claude-lanes
/plugin install lanes@lanes
```

Restart Claude Code (agent definitions load at start-up). Then, inside a repository:

```
/lanes init     # once per repo: picks your gate, creates the lanes and labels
/lanes          # start the orchestrator
```

Say **stop** to wind it down: in-flight work finishes, gets reviewed and lands, and every lane is released.

**Needs:** git 2.31+, bash, the GitHub CLI (`gh`) logged in, and a GitHub `origin`. Label issues `ready-for-agent` to queue them, `needs-triage` for ones waiting on your decision, `dont-touch` for ones agents must leave alone.

## The `lanes` tool

The plugin puts `lanes` on Claude's PATH. You can run it yourself too (`~/.claude/plugins/cache/.../bin/lanes`, or symlink it).

```
lanes init                    create the lane worktrees beside the repo (<repo>-lanes/lane-N)
lanes status                  each lane, free or leased
lanes acquire <branch>        lease a free lane on <branch>; prints its path
lanes release <n> [--force]   reset lane n to main and free it (refuses while it holds unpushed work)
lanes gate                    run the gate in the current directory
lanes train <branch>...       land each branch in turn: rebase, gate, merge, delete
```

Settings live in the repo's git config:

| Key | Default | Meaning |
|---|---|---|
| `lanes.gate` | (required) | the command that must pass before anything lands |
| `lanes.count` | `3` | number of lanes |
| `lanes.main` | origin's HEAD | the branch work lands on |
| `lanes.merge` | `squash` | `squash`, `rebase` or `merge` through `gh pr merge`; `push` fast-forwards main directly |
| `lanes.base` | `<repo>-lanes` beside the repo | where lanes live |

Lanes are reset with `git clean -fd`, never `-x`, so ignored build output and dependency folders survive between tasks: a lane stays warm. The train runs in its own worktree and never switches your checkout. If main moves while the gate is running, the train re-tests rather than land an untested combination.

## Adding your project's rules

Workers read your project's `CLAUDE.md`. Put project-specific rules there (how to run one test, what never to touch, house conventions). When the orchestrator sees a worker slip twice, it adds a line to a "Working in a lane" section so later workers don't repeat it.

## Tests

```
test/lanes-test.sh
```

It runs `bin/lanes` against a throwaway repo with a local bare origin: leases, refusals, the train landing a green branch and refusing a red one, conflicts, a branch behind main, and main moving mid-gate.

## License

MIT. See [LICENSE](LICENSE).
