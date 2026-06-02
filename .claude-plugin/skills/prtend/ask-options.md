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
