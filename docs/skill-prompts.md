# `prtend` — Skill prompts

> Reference doc. Read `overview.md` for workflow, `cli-contract.md` for CLI shape, `forge-mapping.md` for `gh`/`glab` translations.

This doc is the source of truth for what the prtend Claude Code skill says and does. It contains:

1. The full **SKILL.md** body that ships in `.claude-plugin/skills/prtend/SKILL.md`.
2. The contents of the **reference files** that sit alongside SKILL.md and progressively disclose detail.
3. The **AskUserQuestion option sets** the skill uses at each decision point.
4. **Example transcripts** showing the skill in action.
5. An **anti-patterns checklist** of things the skill must never do.

Per the progressive-disclosure pattern: SKILL.md is read every time the skill triggers, so it's compact and points at reference files for detail. Reference files are read on demand when Claude needs to dig in (e.g. when actually evaluating a comment, it reads `comment-decision-rubric.md`).

---

## Skill directory layout

```
.claude-plugin/skills/prtend/
├── SKILL.md                       # entry point, always read on trigger
├── ci-fixable-rubric.md           # read when evaluating a CI failure
├── comment-decision-rubric.md     # read when evaluating a review comment
├── ask-options.md                 # read when about to use ask_user_input
├── note-templates.md              # rare; mostly for recognizing existing notes
└── examples/
    ├── first-run-init.md
    ├── ci-fix-loop.md
    ├── comment-mixed-outcomes.md
    └── defer-flow.md
```

---

## SKILL.md (ships as-is)

```markdown
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
```

---

## `ci-fixable-rubric.md` (ships as-is)

```markdown
# CI failure: fixable or ask?

When `prtend watch` returns a CI event with `state == "failure"`, evaluate each failure object and decide whether to attempt an automatic fix or escalate.

## Fixable — attempt the fix

- **Lint errors** (ESLint, RuboCop, Clippy, Flake8, golint). The rule name plus file location is usually enough.
- **Formatting** (Prettier, gofmt, black, rustfmt). Run the formatter, commit the result.
- **Simple type errors** (TypeScript, mypy, type-checked Python, Rust): missing imports, simple parameter mismatches, obvious narrowing.
- **Missing imports**: clear `ImportError` / `module not found`; resolution is adding the import.
- **Tests broken by your own changes**: the test exercises a function you just modified, and the failure clearly reflects the API change you introduced. (The test should be updated; not always — see "gray areas".)
- **Snapshot mismatches** from changes you made: rerun, commit new snapshots.
- **Simple syntax errors** introduced by an edit: missing parenthesis, semicolon, etc.

## Not fixable — escalate

- **Infra flakes**: "Lost connection to runner", "Docker daemon not responding", CI provider 500s.
- **Credentials / auth**: token expired, missing secret, permission denied. You can't get new credentials.
- **External service down**: tests depending on third-party APIs the CI can't reach.
- **Test failures in code you haven't touched** and can't reason about.
- **Build environment issues**: missing OS packages, kernel-level issues, platform behavior.
- **Logic errors needing domain context**: the test correctly catches a bug you introduced, but understanding why requires context only the user has.
- **Anything where your attempt would be a guess**: if you can't form a confident hypothesis from the log, escalate.

## Gray areas — attempt once, then escalate

- **Flaky test, first instance**: re-push retries CI. After signature hits 2+ attempts, escalate as "looks flaky" — let the user decide retry / disable / fix.
- **Test failing in code you transitively affected**: a recent commit touched a shared module, an unrelated test now fails. One attempt is fine; on retry, escalate.
- **Refactor-induced breakage**: you changed a function's signature, several call sites' tests now fail. One sweeping fix is fine; if it doesn't take, the refactor probably needs reconsidering.

## When in doubt

Default to escalation. The 3-retry cap bounds *attempts*, not *certainty* — a confident "fixable" attempt that fails doesn't become a less-confident attempt; it becomes evidence the original judgment was off. After three tries, surface and let the user decide.

## Signature format (for context)

prtend's `failure.signature` follows `<tool>:<scope>:<short-rule>`. Examples:

- `eslint:src-widget-tsx:no-unused-vars`
- `jest:reducer-spec:NaN-NaN`
- `mypy:src-models-py:incompatible-return-type`

You don't compose signatures (prtend does); but you read them to recognize when the same failure is recurring.
```

---

## `comment-decision-rubric.md` (ships as-is)

```markdown
# Review comment evaluation

When evaluating an individual review comment, pick one of four:
**Reject** / **Accept** / **Ignore** / **Ask**.

## Reject

The comment is invalid or the code must stay as-is for reasons the reviewer may not have seen. Reject when:

- The comment misreads the code (points at a "bug" that isn't there).
- The suggestion would break something else (constraint the reviewer didn't see).
- The criticized convention is intentional and documented elsewhere.
- The reviewer suggests a refactor explicitly out of scope for this PR.

When Rejecting, the note body must explain *why*. "I disagree" isn't a reason. If you can't articulate why, this is Ask, not Reject.

## Accept

The comment identifies a real issue and you understand the fix. Accept when:

- The suggested change is correct and you can implement it.
- The reviewer caught a bug, naming issue, missed edge case, or other concrete improvement.
- The reviewer's *suggested* implementation isn't necessarily what you'll do — Accept covers "I'll address this concern", with the actual fix being whatever solves the underlying issue.

Apply the fix, commit, push, then post the note with the commit hash.

## Ignore

The comment is something you shouldn't engage with at all. Ignore when:

- The comment is a compliment or general remark not requesting action ("nice work", "interesting approach").
- The comment is between humans about something orthogonal to the code (planning, sidebar discussion).
- The comment is a question directed at another reviewer, not at the PR author.
- The comment has been resolved in a parallel discussion thread that humans have indicated supersedes this one.

Ignore is silent — no note. Used sparingly.

## Ask

You're not sure, or the decision needs human judgment. Ask when:

- You see the concern but the right fix isn't obvious.
- The suggestion would work but has tradeoffs you don't have authority to make.
- The reviewer's question touches business logic or design decisions only the user can answer.
- The fix would require changes beyond this PR's scope.
- The comment anchor is stale (`anchor_stale: true`) — the line doesn't exist but the concern may still apply.
- You'd Accept but the fix touches areas you don't have context on.

**Default to Ask whenever there's real uncertainty.** The 4-option frame is binary (fix it / don't fix it) plus an "I don't know" escape valve — use the escape valve.

## Ask resolution

User picks one of five:

- **Reject** / **Accept** / **Ignore**: as above.
- **Halt**: per-comment halt. Note posted saying work is stopped pending research. Other comments in the batch continue processing. Whole-session halt is a separate, explicit user action ("stop watching"), not a comment outcome.
- **Defer**: defer doc written via `prtend defer-write`, note posted via `prtend note-post --kind defer` pointing to the doc path.

## Multi-comment batches

When a batch has many comments:

- Evaluate independently. One Ask doesn't pause the others.
- If 3+ comments resolve to Ask in one batch, surface that observation — consider asking the user if they want to do a review pass together rather than answering one by one.
- Don't artificially batch decisions. Each comment gets its own resolution and note.

## AI reviewers (Copilot, Duo, etc.)

Treat the same as human reviewers. The Reject/Accept/Ignore/Ask frame applies. AI reviewers tend to:

- Over-suggest stylistic changes — be willing to Reject when project style differs from defaults.
- Miss context — be willing to Reject when constraints aren't visible.
- Catch real issues — Accept when they do.

Don't auto-Accept AI feedback; don't auto-Reject either. Evaluate.

## What about a reviewer who's also the user?

If the PR author leaves a comment on their own PR (rare but happens — TODO notes to themselves, second thoughts), treat as Ask by default. The user comments to remind themselves of something; the right move is usually to surface it back.
```

---

## `ask-options.md` (ships as-is)

```markdown
# AskUserQuestion option sets

Exact options the skill uses with `ask_user_input` at each decision point.

## `first-run-init` — system reviewers

- **Question**: "Any system-level reviewers (Copilot, Duo, etc.) to auto-request on every PR in this repo?"
- **Type**: multi-select
- **Options**:
  - "GitHub Copilot"
  - "GitLab Duo"
  - "Anthropic Code Review"
  - "None"
  - "Other (specify in next message)"

If user selects "Other", follow up with a free-text input: "Reviewer login(s), one per line."

## `first-run-init` — optional reviewers

Free-text first: "Optional reviewers to offer on every PR? (one login per line, or 'none')"

This is free-text rather than multi-select because the candidate set is unbounded.

## `first-run-init` — watch strategy

- **Question**: "How should prtend watch the PR after push?"
- **Type**: single-select
- **Options** (pruned by `prtend doctor --check forge_cli_version` to those the installed CLIs support):
  - "Block in this session (recommended for active work)"
  - "Poll when I resume (recommended for background tasks)"
  - "Background with cleanup hook (advanced)"

## `first-run-init` — write target

- **Question**: "Where should this config live?"
- **Type**: single-select
- **Options**:
  - "User config ($XDG_CONFIG_HOME/prtend/) — shared across machines if you sync"
  - "Repo-local (.claude/pr-reviewers.yml) — committed"
  - "Repo-local but gitignored"
  - "Custom path (I'll set $PRTEND_CONFIG)"

## `optional-reviewers-prompt` (every PR)

- **Question**: "Optional reviewers for this PR? (none selected by default)"
- **Type**: multi-select
- **Options**: one per configured optional reviewer, no defaults selected

## `ci-failure-escalation`

- **Question**: "CI failed on `<signature>` after `<N>` attempts. How to proceed?"
- **Type**: single-select
- **Options**:
  - "Retry — try a different fix approach"
  - "Mark unfixable — record and keep watching for other events"
  - "Abort watch — stop watching this PR"
  - "Pause — let me investigate, I'll resume manually"

## `review-comment-ask`

- **Question**: "Review comment from `<reviewer>` on `<path>:<line>`: `<truncated body>`. How should I handle it?"
- **Type**: single-select
- **Options**:
  - "Reject — I'll tell you why"
  - "Accept — go ahead and fix"
  - "Ignore — no action"
  - "Halt — stop work on this issue pending research"
  - "Defer — write a doc to track for later"

After Reject: free-text follow-up for the reason.
After Halt: free-text follow-up for the reason.
After Defer: free-text follow-up for what to include in the doc.

## `closed-pr-on-submit`

- **Question**: "A closed PR (#`<N>`) already exists for this branch. How to proceed?"
- **Type**: single-select
- **Options**:
  - "Reopen the existing PR"
  - "Create a new PR (need to push to a different branch first)"
  - "Abort — I'll handle this manually"

## `stale-comment-handling`

- **Question**: "This comment anchors to a line that no longer exists. The underlying concern may still apply. How to handle?"
- **Type**: single-select
- **Options**:
  - "Evaluate against current code"
  - "Reject — concern no longer applies"
  - "Defer — track for later review"
  - "Skip without action"

## `multi-ask-batch`

- **Question**: "I'm seeing several comments in this review batch I'd like to ask about (`<N>` so far). Want to walk through them together, or address them one at a time?"
- **Type**: single-select
- **Options**:
  - "Walk through them together"
  - "One at a time"
  - "Pause — let me read the batch first"
```

---

## `note-templates.md` (ships as-is)

```markdown
# Note templates

`prtend note-post` composes notes from kind + parameters. The skill should never craft these manually. This doc is here for recognizing them in existing comment threads.

## Marker

Every prtend note begins with:

```
<!-- prtend: handled v1 -->
```

`prtend reviews-poll` sets `comment.already_handled: true` when this marker is found on an existing reply. Don't strip, edit, or imitate the marker.

## Body shapes by kind

### Reject

```
<!-- prtend: handled v1 -->
Resolution: Reject — <reason>
```

### Accept

```
<!-- prtend: handled v1 -->
Resolution: Accept — fixed in <commit-hash>
```

### Halt

```
<!-- prtend: handled v1 -->
Resolution: Halt — <reason>; no further work pending research
```

### Defer

```
<!-- prtend: handled v1 -->
Resolution: Defer — tracked at <path>
```

## Reading existing notes

When `comment.already_handled` is true:

1. The note was posted by prtend in an earlier session — skip the comment, don't re-evaluate.
2. Or it was posted by something else using the same marker (unlikely) — treat the same.

Don't try to update an existing handled note. If the user wants re-evaluation, they say so explicitly.
```

---

## Example transcripts

These live in `examples/` alongside SKILL.md.

### `examples/first-run-init.md`

```
User: I just pushed to feature/widget-layout. What's the state of the PR?

[Claude runs prtend detect]
> {"forge":"github","branch":"feature/widget-layout","pr":123,"pr_state":"open","is_default_branch":false}

[Claude runs prtend config show]
> exit 4 — no config for this repo

Claude: You have an open PR (#123) on this branch. Quick first-time setup before I start watching — won't take long.

[Claude uses ask_user_input with first-run-init: system reviewers]

User: GitHub Copilot

[Claude follows up with optional reviewers free-text]

User: alice, bob

[Claude uses ask_user_input with first-run-init: watch strategy]

User: Block in this session

[Claude uses ask_user_input with first-run-init: write target]

User: User config ($XDG_CONFIG_HOME)

[Claude runs prtend config init --system-reviewer copilot \
  --optional-reviewer alice --optional-reviewer bob \
  --watch-strategy blocking --write-target xdg]
> {"written_to":"/home/beau/.config/prtend/owner-repo.yml", ...}

Claude: Config saved. Now watching PR #123.

[Claude runs prtend watch --pr 123 --block --timeout 300]
> ...
```

### `examples/ci-fix-loop.md`

```
[Initial watch returns CI failure]
[Claude runs prtend watch --pr 123 --block --timeout 300]
> {"type":"ci","pr":123,"state":"failure","failures":[
>   {"check_name":"lint","signature":"eslint:src-widget-tsx:no-unused-vars",
>    "log_excerpt":"src/widget.tsx:3:10  error  'useEffect' is defined but never used  no-unused-vars"}
> ]}

[Claude reads ci-fixable-rubric.md (first CI encounter this session)]

Claude: CI failed on a lint rule — unused `useEffect` import in src/widget.tsx. Going to remove it.

[Claude edits src/widget.tsx to remove the import]
[Claude runs git commit -m "fix: remove unused useEffect import"]
[Claude runs git push]

[Claude runs prtend watch --pr 123 --block --timeout 300]
> {"type":"ci","pr":123,"state":"running",...}

Claude: New CI run starting. Continuing to watch.

[Claude runs prtend watch --pr 123 --block --timeout 300]
> {"type":"ci","pr":123,"state":"success",...}

Claude: CI is green.

[Claude continues the loop]
```

### `examples/comment-mixed-outcomes.md`

```
[Watch returns a review batch]
[Claude runs prtend watch --pr 123 --block --timeout 300]
> {"type":"review_batch","pr":123,"author":"alice","review_state":"changes_requested",
>  "comments":[
>    {"comment_id":"456789","path":"src/widget.ts","line":42,
>     "body":"Could we use Array.from here instead of a loop?",
>     "anchor_stale":false,"already_handled":false},
>    {"comment_id":"456790","path":"src/utils/time.py","line":18,
>     "body":"This doesn't handle timezones — naive datetime will break in production.",
>     "anchor_stale":false,"already_handled":false},
>    {"comment_id":"456791","path":null,"line":null,
>     "body":"Nice refactor overall.",
>     "anchor_stale":false,"already_handled":false},
>    {"comment_id":"456792","path":"src/widget.ts","line":67,
>     "body":"Should this share state with the new auth module?",
>     "anchor_stale":false,"already_handled":false}
>  ]}

[Claude reads comment-decision-rubric.md (first comment-eval this session)]

Claude: Four comments to work through.

**Comment 1** (`src/widget.ts:42`): alice suggests `Array.from` instead of a loop. Looking at the loop — it has an early-exit on a sentinel value that `Array.from` wouldn't support cleanly. Rejecting.

[Claude runs prtend note-post --pr 123 --comment 456789 --kind reject \
  --reason "loop has an early-exit on sentinel value; Array.from would lose that"]
> {"posted":true,"reply_id":"456810","kind":"reject",...}

**Comment 2** (`src/utils/time.py:18`): real issue — naive datetime parsing. Going to add tz-aware parsing.

[Claude edits src/utils/time.py]
[Claude runs git commit -m "fix: tz-aware datetime parsing per review"]
> [main 8b9c2d3] fix: tz-aware datetime parsing per review
[Claude runs git push]

[Claude runs prtend note-post --pr 123 --comment 456790 --kind accept --commit 8b9c2d3]
> {"posted":true,"reply_id":"456811","kind":"accept",...}

**Comment 3**: general compliment, no action requested. Ignoring.

(no note posted)

**Comment 4** (`src/widget.ts:67`): cross-module design question about state-sharing with auth. I don't have context on the auth refactor — need to ask.

[Claude uses ask_user_input with review-comment-ask, comment quoted in question]

User: Defer for now, we'll revisit during the auth refactor.

[Claude asks for defer reason text]

User: Cross-module state-sharing pending auth refactor decision.

[Claude runs prtend defer-write --pr 123 --comment 456792 \
  --reason "Cross-module state-sharing pending auth refactor decision"]
> {"path":"/home/beau/.config/prtend/deferred/123-456792.md",...}

[Claude runs prtend note-post --pr 123 --comment 456792 --kind defer \
  --doc /home/beau/.config/prtend/deferred/123-456792.md]
> {"posted":true,"reply_id":"456812","kind":"defer",...}

Claude: Done with the batch — 1 rejected, 1 accepted (in 8b9c2d3), 1 ignored, 1 deferred.

[Claude continues the watch loop]
```

### `examples/defer-flow.md`

```
[After ask resolves to Defer, with reason "Behavioral change to public API needs RFC"]

[Claude runs prtend defer-write --pr 124 --comment 789012 \
  --reason "Behavioral change to public API needs RFC"]
> {"path":"/home/beau/.config/prtend/deferred/124-789012.md","pr":124,"comment_id":"789012",
>  "comment_url":"https://github.com/owner/repo/pull/124#discussion_r789012"}

[The deferred doc now exists at that path with the comment context, code snippet, and reason]

[Claude runs prtend note-post --pr 124 --comment 789012 --kind defer \
  --doc /home/beau/.config/prtend/deferred/124-789012.md]
> {"posted":true,"reply_id":"789045","kind":"defer",
>  "body":"<!-- prtend: handled v1 -->\nResolution: Defer — tracked at /home/beau/.config/prtend/deferred/124-789012.md"}

Claude: Comment 789012 deferred. The full context is captured at `/home/beau/.config/prtend/deferred/124-789012.md`; you can grep across all deferred docs later or revisit during the auth refactor.

[Claude continues with the next comment in the batch]
```

---

## Anti-patterns checklist

The skill must never:

1. **Resolve a review thread.** No API call. `prtend-forge-lib.bash` exposes no function for this on purpose. If a future contributor adds one, it's a regression.
2. **Merge or auto-close a PR.** The skill watches; the author decides.
3. **Post a note without going through `prtend note-post`.** The idempotency marker matters.
4. **Use `gh` or `glab` directly.** All forge work goes through `prtend`. If a needed operation isn't in the CLI, it's a CLI gap to fix, not a reason to bypass.
5. **Auto-Accept AI reviewer feedback.** Evaluate Copilot/Duo/etc. the same as humans.
6. **Auto-Reject AI reviewer feedback.** Same.
7. **Skip the watch loop after push.** If a push lands on a branch with an open PR, watch fires.
8. **Increase retry caps or timeouts** mid-session without the user asking.
9. **Compose PR titles or bodies unprompted** — supply minimal title/body from project conventions; if anything beyond that's needed, ask.
10. **Edit or replace an existing prtend-handled note.** Once posted, the resolution stands until the human author engages.
11. **Treat `anchor_stale` as auto-Ignore.** Default is Ask.
12. **Process other PRs in the same session.** One PR per skill invocation. If the user has multiple, ask which.

---

## Open prompt questions

These are pinned for revisiting once the skill has shipped and seen real use:

- **CI fixable rubric calibration.** The rubric is a starting point; real failures will show categories worth promoting or demoting. Worth re-reading after the first dozen real CI escalations.
- **Comment Ask threshold.** "Default to Ask when uncertain" is correct but may need a finer grain — maybe "Ask if the fix would touch more than one file" or similar concrete heuristics.
- **AI reviewer policy.** Treating Copilot/Duo the same as humans is the right principle but may generate too much Ask traffic. After observing, consider a default-Reject for stylistic AI suggestions that don't cite a project rule.
- **Commit-grouping defaults.** Per-fix vs batched per-review may need a stronger default. For v0, let the agent decide; revisit after seeing what actually produces cleaner history.

---

## See also

- `overview.md` — workflow spec and decision rules.
- `cli-contract.md` — full CLI reference with output JSON shapes.
- `forge-mapping.md` — `gh` / `glab` command translations.
- `repo-bootstrap.md` — repo layout, lib structure, distribution.
