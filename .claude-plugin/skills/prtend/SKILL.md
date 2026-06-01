---
name: prtend
description: |
  When the user pushes commits to a branch with an open PR, or asks to submit/open a PR or MR, watches the resulting PR for CI events and review comments. Subscribes to CI status, fixes fixable failures up to 3 attempts per signature then escalates, evaluates review comments using a Reject/Accept/Ignore/Ask decision frame, and posts resolution notes via the prtend CLI. Use whenever the user runs `git push`, asks to "submit a PR", "open a PR", "create an MR", "commit and push", or asks about CI/review status on a recent PR. Does not merge PRs, resolve review threads, or compose PR titles unprompted. Works with both GitHub (`gh`) and GitLab (`glab`); the underlying prtend CLI abstracts the forge.
---

# prtend — PR/MR tending

prtend handles the post-push lifecycle of a Pull Request: subscribing to CI and review events, fixing what can be fixed, evaluating review comments, and posting resolution notes. Deterministic forge work is done by the `prtend` CLI; this skill carries the judgment.

## When this triggers

- User runs `git push` (or asks you to commit and push)
- User says "submit a PR", "open a PR", "create an MR", "commit and push", or similar
- User asks about PR status, CI state, or review feedback on recent work
- User asks you to address review feedback mid-PR

Do **not** trigger this skill for: merging, closing PRs, editing PR title/body after creation, or general `gh`/`glab` invocations unrelated to a PR's lifecycle.

## Core principle

All forge work goes through the `prtend` CLI. **You never invoke `gh` or `glab` directly** in this skill. The CLI emits JSON; you switch on the shape and decide what to do next.

The most-used commands (full reference in `docs/cli-contract.md`):

- `prtend detect` — forge, branch, current PR state
- `prtend pr-open --title T [--body B] [--draft] [--optional-reviewer X]` — push + create + reviewer flow
- `prtend watch --pr N --block [--timeout S]` — block for one event (CI / review batch / pr_closed), return JSON
- `prtend note-post --pr N --comment C --kind K <kind-flags>` — post resolution note
- `prtend defer-write --pr N --comment C --reason R` — write defer doc, return path

## First invocation in a repo

If `prtend detect` succeeds but `prtend config show` indicates no config exists, run the first-run init flow before proceeding with the original task. Options live in `ask-options.md` under `first-run-init`.

## Entry decision

After `prtend detect`, route by output:

| `pr` | `pr_state` | User intent | Action |
|---|---|---|---|
| null | — | push only | done (no watch) |
| null | — | submit PR | run PR submission flow |
| set | `open` / `draft` | any | enter watch loop |
| set | `closed` / `merged` | submit PR | ask user (reopen / new PR / abort) |
| set | `closed` / `merged` | push only | done (no watch on closed PR) |
| — | — | `is_default_branch: true` | skip entirely |

## PR submission flow

1. Compose title and body following project conventions (look at recent merged PRs, CHANGELOG, or commit messages). If the user supplied them, use theirs verbatim.
2. If optional reviewers are configured, present them via `ask_user_input` (`optional-reviewers-prompt` in `ask-options.md`) — multi-select, no defaults.
3. Call `prtend pr-open --title T --body B [--draft] [--optional-reviewer ...]`. System reviewers are added automatically from config.
4. On success, enter the watch loop.

## Watch loop

```
loop:
  event = prtend watch --pr N --block --timeout 300
  if event is empty (timeout) → continue
  switch event.type:
    case "ci":           handle_ci(event)
    case "review_batch": handle_review_batch(event)
    case "pr_closed":    break
```

The 5-minute timeout lets the user interject. Don't increase it without reason.

### CI handling

For each failure in `event.failures`:

1. Read `ci-fixable-rubric.md` to decide if it's fixable. (Read once per session; rely on memory after that.)
2. If fixable AND retry count for this signature `< 3`: apply fix, commit, push. The push triggers a new CI run; the next watch event will report on it.
3. If unfixable OR retry count `>= 3`: escalate via `ask_user_input` (`ci-failure-escalation` in `ask-options.md`).

Retry counts are per-signature and tracked by prtend in state. You don't manage the counter; you just respect it. Check it via `prtend doctor` or the state file; usually you'll see "3 attempts on `<sig>`" in stderr from `prtend watch`.

### Review batch handling

For each comment in `event.comments`:

- Skip if `comment.already_handled` is true.
- If `comment.anchor_stale` is true: use `ask_user_input` (`stale-comment-handling` in `ask-options.md`) — default to Ask, not auto-Ignore.
- Otherwise: read `comment-decision-rubric.md` (once per session), evaluate, pick **Reject** / **Accept** / **Ignore** / **Ask**.

Apply the decision:

| Decision | Action |
|---|---|
| Reject | `prtend note-post --kind reject --reason R` |
| Accept | Apply fix, commit (hash H), push. Then `prtend note-post --kind accept --commit H` |
| Ignore | (no action — Ignore posts no note) |
| Ask | `ask_user_input` with `review-comment-ask` options; act on user's choice |

#### Ask resolution

After Ask returns one of Reject / Accept / Ignore / Halt / Defer:

- **Reject / Accept / Ignore**: as above.
- **Halt**: `prtend note-post --kind halt --reason R`. Per-comment scope — keep processing other comments in the batch.
- **Defer**:
  1. `prtend defer-write --pr N --comment C --reason R` → path P
  2. `prtend note-post --kind defer --doc P`

### Commit grouping for Accept

- Conceptually related fixes (same function, same concern): one commit, multiple notes reference the same hash.
- Unrelated fixes touching different areas: separate commits, each note links its own hash.

Choose for reviewable history clarity. Don't artificially split or batch.

## Critical anti-patterns

NEVER:

- Resolve a review thread. The CLI exposes no function for this on purpose.
- Merge the PR.
- Auto-close the PR.
- Post a note without going through `prtend note-post` — the idempotency marker matters.
- Use `gh` or `glab` directly. Everything goes through `prtend`.
- Increase retry caps or timeouts without the user explicitly asking.
- Push commits to a PR branch without entering the watch loop afterward.

## Reference files (read on demand)

- `ci-fixable-rubric.md` — when to fix CI vs ask
- `comment-decision-rubric.md` — Reject/Accept/Ignore/Ask heuristics
- `ask-options.md` — exact AskUserQuestion option sets for every decision point
- `note-templates.md` — note body shapes (rarely needed; `prtend note-post` handles composition)
- `examples/*.md` — full example transcripts
- `../../../docs/overview.md` — workflow spec
- `../../../docs/cli-contract.md` — CLI reference
- `../../../docs/forge-mapping.md` — forge translations
