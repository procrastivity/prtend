# `prtend` — Forge mapping

> Reference doc. Read `overview.md` first for the workflow spec.

This doc is the implementation reference for `prtend-forge-lib.bash`. It maps every operation prtend needs onto the corresponding `gh` and `glab` invocations, the JSON shapes each forge returns, and the canonical JSON shape prtend emits. Anyone implementing or extending the forge lib reads this once instead of cross-referencing two CLI manuals.

Commands shown are accurate as of the doc date but may shift with new CLI releases. Validate against the installed version at implementation time; flag breakage as a `prtend doctor` check rather than discovering it mid-watch.

---

## Concept and term mapping

| Neutral name | GitHub | GitLab | Notes |
|---|---|---|---|
| Forge | github.com / GitHub Enterprise | gitlab.com / self-hosted | Identified by remote URL host. |
| PR | Pull Request | Merge Request | Identified by integer number, scoped to the repo. |
| PR identifier in API | `<owner>/<repo>` + number | project ID or path + IID | GitLab uses *internal ID* (IID) for the project-scoped number; the global ID is different. Use IID throughout — it's what `glab` accepts. |
| PR state | `OPEN`, `CLOSED`, `MERGED` (+ separate `isDraft` bool) | `opened`, `closed`, `merged`, `locked` (+ `draft` bool, or `Draft:` title prefix on older GitLab) | prtend normalizes to `open` / `closed` / `merged` / `draft`. |
| Draft | `--draft` flag on create; `isDraft: true` in JSON | `--draft` flag on newer `glab`; otherwise `Draft:` title prefix | Title prefix is the durable convention; `glab` may toggle the prefix even when the flag is used. |
| Reviewer | First-class concept; `reviewRequests` array | First-class concept; `reviewers` array | Approvers (GitLab) are a separate concept tied to approval rules; prtend does not use them. |
| Review batch | Submitted review (`gh pr review`) — a set of comments delivered together with a final state of `APPROVED` / `CHANGES_REQUESTED` / `COMMENTED` | Discussion / thread of notes; "settled" when all notes are present and no new ones arrive within the poll window | The granularity differs. See **Reviews / discussions** below. |
| Review comment | Inline comment on a diff position, part of a review | Inline note on a diff position, part of a discussion | Both forges allow non-inline comments too; prtend treats those identically. |
| Resolve | "Resolve conversation" on a review thread | "Resolve thread" on a discussion | prtend **never invokes either**; the marker doc explains. |
| CI check | A "check run" tied to a commit | A "job" tied to a "pipeline" tied to a commit | A "check" in prtend is the forge's smallest reportable unit (one `gh pr checks` row, one `glab ci status` job). |
| CI failure signature | derived as `<tool>:<scope>:<short-rule>` | same | Computed by prtend from check name + log excerpt, not by the forge. |

---

## Authentication

| Forge | Check command | Token env var (override) |
|---|---|---|
| GitHub | `gh auth status` | `GH_TOKEN` or `GITHUB_TOKEN` |
| GitLab | `glab auth status` | `GITLAB_TOKEN` |

`prtend_forge_cli_ready` runs the relevant `auth status` and returns:

- exit 0 — installed and authenticated
- exit 1 — installed but not authenticated (user must run `gh auth login` / `glab auth login`)
- exit 3 — CLI not installed

prtend never prompts for credentials, never reads tokens from config files, and never embeds tokens in URLs. Auth is the user's responsibility via the forge CLI's own login flow.

---

## Operation mapping

Each operation below shows the GitHub and GitLab invocations side-by-side, with notes on quirks and the canonical output shape prtend emits. Output translations are done in the forge-lib's per-forge private functions; the public API returns the canonical shape.

### Detect forge from repo

| Forge | Command |
|---|---|
| GitHub | `gh repo view --json url` |
| GitLab | `glab repo view --output json` |

Strategy: try `gh repo view` first; on non-zero exit, try `glab repo view`. The remote URL host (`github.com`, `gitlab.com`, GH/GL Enterprise hostnames) confirms. Cache the result in `$PRTEND_FORGE` for the rest of the dispatcher's lifetime.

If both succeed (e.g. a repo with a github.com origin and a gitlab.com mirror), prefer the remote pointed at by the current upstream tracking branch.

### Current branch

| Forge | Command |
|---|---|
| Either | `git rev-parse --abbrev-ref HEAD` |

Pure git — same on both forges. Lives in `prtend-forge-lib.bash` for cohesion with the rest of the branch/PR ops.

### Find PR for branch

| Forge | Command |
|---|---|
| GitHub | `gh pr list --head <branch> --state open --json number,state,isDraft` |
| GitLab | `glab mr list --source-branch <branch> --state opened --output json` |

Canonical output (stdout from `prtend_forge_pr_for_branch`):

```
123        # just the number, on success
            # empty stdout, exit 1, on no PR
            # empty stdout, exit 2, on multiple PRs
```

GitLab quirk: `glab mr list --source-branch` may return PRs from forks if `--all-groups` is implied; check `target_project_id` matches the current repo.

### PR state

| Forge | Command |
|---|---|
| GitHub | `gh pr view <pr> --json state,isDraft,mergedAt,closedAt` |
| GitLab | `glab mr view <pr> --output json` |

Canonical output:

```json
{ "state": "open" | "closed" | "merged" | "draft" }
```

Normalization:

- GitHub: `state == "OPEN" && isDraft` → `draft`; `state == "OPEN"` → `open`; `state == "MERGED"` → `merged`; `state == "CLOSED"` → `closed`
- GitLab: `state == "opened" && draft` → `draft`; `state == "opened"` → `open`; `state == "merged"` → `merged`; `state == "closed"` → `closed`. Locked state is reported as `closed` for prtend's purposes.

### Push branch

| Forge | Command |
|---|---|
| Either | `git push --set-upstream <remote> <branch>` (first push); `git push` (subsequent) |

Pure git. Detect "first push" by checking `git rev-parse --abbrev-ref @{upstream}` — if it fails, set upstream; otherwise plain push.

### Create PR

| Forge | Command |
|---|---|
| GitHub | `gh pr create --head <branch> --title <title> --body <body> [--draft]` |
| GitLab | `glab mr create --source-branch <branch> --title <title> --description <body> [--draft]` |

Canonical output: the new PR number on stdout.

Notes:

- Both CLIs print the PR/MR URL to stdout on success; parse out the trailing number.
- `glab mr create` defaults `--target-branch` to the project's default branch; same as `gh pr create`. Pass `--target` / `--target-branch` explicitly only when the target differs.
- Title and body come from the caller. prtend does not compose them.
- For draft: GitHub's `--draft` is durable; on GitLab, the `--draft` flag may or may not be supported depending on the `glab` version. Fall back to prepending `Draft: ` to the title.

### Add reviewer

| Forge | Command |
|---|---|
| GitHub | `gh pr edit <pr> --add-reviewer <login>` |
| GitLab | `glab mr update <pr> --reviewer <login>` |

Notes:

- GitHub allows team reviewers via `--add-reviewer <org>/<team>`. prtend treats team reviewers as opaque strings; the config file accepts whatever the user types.
- GitLab `--reviewer` replaces the reviewer set in older `glab` versions; check whether the installed version supports additive behavior or whether prtend needs to read existing reviewers and pass the combined list.
- GitLab approval rules (separate from reviewers) are not touched.

### List reviewers

| Forge | Command |
|---|---|
| GitHub | `gh pr view <pr> --json reviewRequests` |
| GitLab | `glab mr view <pr> --output json` (reviewers in the `reviewers` array) |

Canonical output:

```json
{ "reviewers": ["alice", "bob", "copilot"] }
```

### CI status snapshot

| Forge | Command |
|---|---|
| GitHub | `gh pr checks <pr> --json name,state,conclusion,workflow,startedAt,completedAt,link` |
| GitLab | `glab ci status --pipeline <pipeline-id> --output json` (resolve pipeline from MR via `glab mr view <pr> --output json` → `head_pipeline.id`) |

Canonical output:

```json
{
  "state": "running" | "success" | "failure" | "pending" | "cancelled",
  "checks": [
    {
      "name": "test:unit",
      "state": "completed",
      "conclusion": "failure",
      "url": "https://github.com/.../runs/..."
    }
  ]
}
```

GitHub state mapping: `state == "COMPLETED" && conclusion == "FAILURE"` → check is a failure; aggregate state is `failure` if any check failed, else `running` if any are running, else `success`.

GitLab state mapping: pipeline status (`status` field) directly maps: `failed`, `success`, `running`, `pending`, `canceled`.

### CI failures (detail)

| Forge | Command |
|---|---|
| GitHub | `gh run view <run-id> --log-failed` (run ID resolved from the failed check) |
| GitLab | `glab ci trace <job-id>` (job ID from the failed CI status entry) |

Canonical output:

```json
{
  "failures": [
    {
      "check_name": "test:unit",
      "conclusion": "failure",
      "log_url": "https://github.com/.../runs/123",
      "log_excerpt": "<last ~50 lines, truncated>",
      "signature": "jest:reducer-spec:NaN-NaN"
    }
  ]
}
```

The signature is computed by prtend, not the forge — parse the log excerpt to derive `<tool>:<scope>:<short-rule>`. Heuristics for signature extraction are in `prtend-state-lib.bash` (or a dedicated `prtend-signature-lib.bash` if it grows).

### CI watch (blocking)

| Forge | Command |
|---|---|
| GitHub | `gh pr checks <pr> --watch --interval <s>` |
| GitLab | Loop: `glab ci status --output json`; sleep `$PRTEND_POLL_INTERVAL` (default 15); compare state to last snapshot |

Notes:

- `gh pr checks --watch` blocks and prints rolling status; prtend's `prtend_forge_ci_wait` invokes it with a state-machine wrapper that emits exactly one JSON event when the aggregate state changes, then exits.
- `glab` has no built-in watch primitive; prtend implements the loop. Poll interval respects `$PRTEND_POLL_INTERVAL`.
- Both implementations honor `--timeout S` from the subcommand layer — wrap with `timeout S` (coreutils) or check elapsed time per poll cycle.

### Reviews / discussions since cursor

| Forge | Command |
|---|---|
| GitHub | `gh api repos/{owner}/{repo}/pulls/{n}/reviews --paginate --jq '...'` |
| GitLab | `glab api projects/{id}/merge_requests/{n}/discussions --paginate` |

Cursor semantics differ:

- **GitHub:** cursor is the last seen review ID. Fetch all reviews, filter to `id > cursor`, sorted by `submitted_at`.
- **GitLab:** cursor is the last seen `created_at` timestamp of a resolved thread. Fetch discussions, filter to threads where all notes have `created_at > cursor`, sorted by max note time.

Canonical output:

```json
{
  "batches": [
    {
      "batch_id": "<opaque, forge-specific>",
      "submitted_at": "2026-05-31T19:48:13Z",
      "author": "alice",
      "state": "changes_requested" | "approved" | "commented",
      "comment_ids": ["456789", "456790", "456791"]
    }
  ],
  "next_cursor": "<opaque>"
}
```

The "batch settles" rule for GitLab needs care — a discussion is considered settled when no new notes have arrived within a configurable quiet window (default 60s). prtend stores the last poll time and the last note time per discussion; a discussion settles when `now - last_note_time > quiet_window` and not before. Until then, the discussion is held out of the returned batch list.

### Comments in a review batch

| Forge | Command |
|---|---|
| GitHub | `gh api repos/{owner}/{repo}/pulls/{n}/reviews/{review_id}/comments` |
| GitLab | the discussion endpoint already returns notes; filter from the prior call's response |

Canonical output:

```json
{
  "comments": [
    {
      "comment_id": "456789",
      "author": "alice",
      "body": "<raw markdown body>",
      "path": "src/utils/time.py",
      "line": 42,
      "anchor_stale": false,
      "created_at": "2026-05-31T19:48:13Z"
    }
  ]
}
```

`anchor_stale` is true when the comment's `line` no longer exists in the current HEAD — derived by checking the diff against current HEAD, not from the forge API directly.

### Single comment body (for marker detection)

| Forge | Command |
|---|---|
| GitHub | `gh api repos/{owner}/{repo}/pulls/comments/{comment_id} --jq .body` |
| GitLab | `glab api projects/{id}/merge_requests/{n}/notes/{note_id} --jq .body` |

Returns just the body text on stdout. Used by `prtend_note_is_handled` to grep for the marker.

### Post reply to a review comment

| Forge | Command |
|---|---|
| GitHub | `gh api -X POST repos/{owner}/{repo}/pulls/{n}/comments/{comment_id}/replies -f body=<body>` |
| GitLab | `glab api -X POST projects/{id}/merge_requests/{n}/discussions/{discussion_id}/notes -f body=<body>` |

Notes:

- On GitHub, replies to a review comment are themselves review comments belonging to the same thread — they appear in the thread on the diff view.
- On GitLab, you reply by adding a note to the existing discussion, not by creating a new discussion.
- Neither call resolves the thread. **prtend never invokes the resolution endpoints** (`PUT /pulls/comments/{id}` with `resolved: true` on GitHub, `PUT /discussions/{id}?resolved=true` on GitLab). The forge-lib should not expose a resolution function at all, to remove the temptation.

---

## Canonical JSON shapes — summary

Subcommands always emit canonical shapes; per-forge translation lives entirely in the forge-lib private functions. Summary of the shapes referenced above:

```json
// prtend detect
{
  "forge": "github" | "gitlab",
  "branch": "feature/x",
  "pr": 123,
  "pr_state": "open" | "closed" | "merged" | "draft" | null
}

// prtend ci-watch / watch event
{
  "type": "ci",
  "pr": 123,
  "state": "failure",
  "failures": [ /* failure objects */ ]
}

// prtend reviews-poll / watch event
{
  "type": "review_batch",
  "pr": 123,
  "batch_id": "RR_kwDOAbc123",
  "submitted_at": "2026-05-31T19:48:13Z",
  "author": "alice",
  "comments": [ /* comment objects */ ]
}

// prtend watch event — PR closed
{
  "type": "pr_closed",
  "pr": 123,
  "final_state": "merged" | "closed"
}
```

The `watch` subcommand emits whichever event type arrived; the skill switches on `type`.

---

## Quirks and gotchas

- **GitHub Enterprise** uses a different host but otherwise identical `gh` syntax. Detection should recognize any host that responds to `gh repo view` regardless of host string; prtend doesn't gate on `github.com` specifically.
- **GitLab self-hosted** similarly works with the right `glab` config (`glab config set -g host <hostname>` or `GITLAB_HOST` env var).
- **`gh pr view` field availability** depends on `gh` version. Always pass `--json` with an explicit field list; the default human-readable output is unstable.
- **`glab` field naming** is snake_case in JSON output even though flags are kebab-case (`--source-branch`, but `source_branch` in JSON). prtend's translation table uses the JSON field names.
- **Pagination on `gh api`** requires `--paginate`. Without it, large review lists return only the first page.
- **`gh pr list --head <branch>`** does not match across forks by default; pass `--state all` if you ever need historical PR matches for diagnostic purposes.
- **GitLab discussion notes** include system notes (status changes, label changes). Filter to `system: false` when collecting review comments.
- **GitLab "suggestion" notes** (inline suggested changes) are regular notes with a `suggestion` field set. prtend treats them as normal comments; applying a suggestion is the user's choice, not the agent's.
- **Rate limits** differ. GitHub: 5000 req/hr authenticated. GitLab: configurable per-instance, often 600 req/min. The poll interval default of 15s keeps both well within budget for a single watch session.
- **`gh pr checks --watch` exit code** is 0 if all checks succeed, 1 if any fail, plus its own conventions on cancellation. prtend's wrapper translates these into "emit one event, exit 0" — the failure information is in the event payload.

---

## What doesn't map cleanly

Two places where the forge model genuinely differs and the lib does real translation work:

1. **Review batch detection.** GitHub gives you a clean "review submitted" event with an ID; GitLab gives you a stream of notes inside discussions that you have to decide when to consider "done." prtend uses a quiet-window heuristic for GitLab (no new notes for N seconds). This is the most likely source of behavioral drift between forges — worth a dedicated test fixture pair.

2. **Comment thread reply semantics.** GitHub's `replies` endpoint creates a new comment that is structurally a sibling of the comment being replied to, both attached to the parent review. GitLab's note-on-discussion appends a note to an existing discussion. Both achieve "reply in thread"; the API shapes are different. prtend's `post_review_reply` papers over this by taking `<comment_id>` and looking up the parent review (GH) or parent discussion (GL) internally.

Anywhere else, the lib is a one-liner wrapping a single CLI call.

---

## See also

- `overview.md` — workflow spec and decision rules.
- `repo-bootstrap.md` — file layout, dispatcher, lib structure.
- `cli-contract.md` — full subcommand reference with the JSON shapes above pinned to specific flags.
