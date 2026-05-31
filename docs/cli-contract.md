# `prtend` — CLI Contract

> Reference doc. Read `overview.md` first for the workflow spec and `forge-mapping.md` for the underlying `gh` / `glab` translations.

This doc is the source of truth for what `prtend`'s CLI does, what it emits, and how it can be composed. The SKILL.md content is written against this contract; test fixtures are pinned against these JSON shapes; future API changes start by editing this doc.

---

## Global conventions

### Output discipline

- **stdout** — always JSON when the command has structured output (one JSON document per event, or one document per call for state-mutating commands). Never mixed with human prose.
- **stderr** — human-readable diagnostics, errors, progress messages. Never machine-parsed.
- **Streamed commands** — `watch`, `ci-watch`, and `reviews-poll` emit one JSON line per event when running `--once` with multiple pending events, or exactly one JSON document per call in blocking modes. Each line is a complete JSON object; no JSON-Lines header.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, including idempotent no-ops and clean timeouts |
| 1 | General error |
| 2 | Invalid arguments / usage error |
| 3 | Missing dependency (CLI not installed, not authed) |
| 4 | Data / state issue (corrupt state file, ambiguous PR, refused operation needing human decision) |

A command that finds nothing-to-do is exit 0, not 4. Exit 4 is reserved for "the data prevents me from acting safely; you decide."

### Common flags

Every subcommand accepts:

| Flag | Purpose |
|---|---|
| `-h`, `--help` | Print usage and exit 0 |
| `--version` | Print `prtend <version>` and exit 0 (top-level only) |
| `-v`, `--verbose` | Extra diagnostics to stderr |
| `-q`, `--quiet` | Suppress non-error stderr output |

### Environment variables

| Variable | Effect |
|---|---|
| `PRTEND_CONFIG` | Override config file path (highest-precedence config location) |
| `PRTEND_LIB` | Override path to `lib/prtend/` (for dev installs) |
| `PRTEND_FORGE` | Force forge detection result (`github` / `gitlab`); skip auto-detection |
| `PRTEND_POLL_INTERVAL` | Override polling interval in seconds (default 15) |
| `PRTEND_CI_RETRY_LIMIT` | Override per-signature retry cap (default 3) |
| `PRTEND_WATCH_STRATEGY` | Override watch strategy (`blocking` / `poll-on-resume` / `background`) |
| `PRTEND_QUIET_WINDOW` | GitLab discussion settle window in seconds (default 60) |
| `GH_TOKEN`, `GITHUB_TOKEN`, `GITLAB_TOKEN` | Passed through to the underlying forge CLI |

prtend never reads tokens directly; the forge CLI handles auth.

---

## `prtend detect`

Detect forge, current branch, and PR state for the branch. The skill's first call on every invocation.

### Synopsis

```
prtend detect [--no-cache] [--branch BRANCH]
```

### Flags

| Flag | Default | Purpose |
|---|---|---|
| `--no-cache` | (off) | Force re-detection even if `$PRTEND_FORGE` is set |
| `--branch BRANCH` | current branch | Detect PR for a specific branch instead of HEAD |

### Output

```json
{
  "forge": "github",
  "branch": "feature/widget-layout",
  "pr": 123,
  "pr_state": "open",
  "is_default_branch": false,
  "remote": "origin"
}
```

| Field | Type | Notes |
|---|---|---|
| `forge` | `"github"` \| `"gitlab"` \| `null` | `null` if no supported forge detected |
| `branch` | string | Current branch (or `--branch` value) |
| `pr` | integer \| `null` | PR/MR number, `null` if no open PR |
| `pr_state` | `"open"` \| `"closed"` \| `"merged"` \| `"draft"` \| `null` | `null` when `pr` is `null` |
| `is_default_branch` | boolean | True when on the repo's default branch — skill should skip the watch flow |
| `remote` | string | Active remote name |

### Exit codes

| Code | Condition |
|---|---|
| 0 | Detection completed (even if `forge` is `null` or `pr` is `null`) |
| 1 | Not in a git repo |
| 2 | Bad flags |
| 4 | Multiple open PRs match the branch (ambiguous; skill must refuse) |

### Example

```
$ prtend detect
{"forge":"github","branch":"feature/widget-layout","pr":123,"pr_state":"open","is_default_branch":false,"remote":"origin"}
```

---

## `prtend pr-open`

Ensure the current branch is on the remote, create a PR if one doesn't exist, and add reviewers. Idempotent: if an open PR already exists for the branch, returns it without modification.

### Synopsis

```
prtend pr-open --title TITLE [--body BODY] [--draft]
               [--target-branch BRANCH]
               [--optional-reviewer LOGIN ...]
```

### Flags

| Flag | Required | Purpose |
|---|---|---|
| `--title TITLE` | yes | PR title |
| `--body BODY` | no | PR body (markdown). Empty if omitted. |
| `--draft` | no | Create as draft |
| `--target-branch BRANCH` | no | Defaults to repo's default branch |
| `--optional-reviewer LOGIN` | no | Add this optional reviewer (repeatable) |

System reviewers are read from config and added automatically — no flag.

### Output

```json
{
  "pr": 123,
  "action": "created",
  "url": "https://github.com/owner/repo/pull/123",
  "state": "open",
  "reviewers_requested": ["copilot", "alice"],
  "reviewers_skipped": []
}
```

| Field | Notes |
|---|---|
| `action` | `"created"` (new branch + new PR), `"created_existing_branch"` (branch was on remote, PR new), `"used_existing"` (open PR already there), `"pushed_existing_pr"` (branch had drifted, push + use existing) |
| `reviewers_requested` | Set actually requested |
| `reviewers_skipped` | Set requested but rejected by forge (unknown user, no permission); each entry includes the reason in stderr |

### Exit codes

| Code | Condition |
|---|---|
| 0 | PR exists (created or already existed) and reviewer flow ran |
| 2 | Missing required flags |
| 3 | Forge CLI missing or not authed |
| 4 | A closed/merged PR exists for the branch — refused; skill must ask user to decide reopen/new/abort |

### Example

```
$ prtend pr-open --title "Add widget layout" --draft --optional-reviewer alice
{"pr":123,"action":"created","url":"...","state":"draft","reviewers_requested":["copilot","alice"],"reviewers_skipped":[]}
```

---

## `prtend ci-watch`

Watch CI on a PR. Emits one CI event per blocking call, or any pending events with `--once`.

### Synopsis

```
prtend ci-watch --pr N [--block | --once | --timeout S]
```

### Flags

| Flag | Default | Purpose |
|---|---|---|
| `--pr N` | (required) | PR/MR number |
| `--block` | (default) | Block until a CI state change; emit one event; exit |
| `--once` | | Emit any pending events (0 or more JSON lines), exit immediately |
| `--timeout S` | | With `--block`: bounded wait. Exit 0 with no output on timeout |

`--block`, `--once`, and `--timeout` are mutually exclusive except that `--timeout S` modifies `--block`.

### Output

One JSON object per CI event (or 0+ with `--once`):

```json
{
  "type": "ci",
  "pr": 123,
  "state": "failure",
  "checks": [
    { "name": "test:unit", "state": "completed", "conclusion": "success", "url": "..." },
    { "name": "test:integration", "state": "completed", "conclusion": "failure", "url": "..." }
  ],
  "failures": [
    {
      "check_name": "test:integration",
      "conclusion": "failure",
      "log_url": "https://github.com/.../runs/456",
      "log_excerpt": "FAIL src/widget.test.ts\n  ● widget renders\n    Expected: 42\n    Received: NaN\n  …",
      "signature": "jest:widget-test:NaN-NaN"
    }
  ],
  "previous_state": "running"
}
```

Aggregate `state`: `"success"` (all checks succeeded), `"failure"` (any check failed), `"running"` (any still running), `"pending"` (none started), `"cancelled"`.

`failures` is present and non-empty only when `state == "failure"`. Each entry includes the prtend-computed signature.

`previous_state` lets the skill distinguish "first event after subscription" (`previous_state` is `null`) from "state changed mid-watch."

### Exit codes

| Code | Condition |
|---|---|
| 0 | One event emitted (blocking), 0+ events emitted (once), clean timeout |
| 2 | Missing `--pr`, conflicting flags |
| 3 | Forge CLI missing or not authed |
| 4 | PR not found, or PR closed/merged during wait |

### Example

```
$ prtend ci-watch --pr 123 --block
{"type":"ci","pr":123,"state":"failure","checks":[...],"failures":[...],"previous_state":"running"}
```

```
$ prtend ci-watch --pr 123 --once
# (no output if nothing pending; exit 0)
```

---

## `prtend reviews-poll`

Poll for new review batches on a PR.

### Synopsis

```
prtend reviews-poll --pr N [--block | --once | --timeout S] [--cursor CURSOR]
```

### Flags

| Flag | Default | Purpose |
|---|---|---|
| `--pr N` | (required) | PR/MR number |
| `--block` / `--once` / `--timeout S` | same as `ci-watch` | same behavior |
| `--cursor CURSOR` | (read from state file) | Override cursor; results returned are batches *after* this cursor |

The cursor is forge-specific (GitHub: last review ID; GitLab: last settled discussion timestamp). When `--cursor` is omitted, prtend reads from `<state-dir>/<pr>.json`. After emitting an event, prtend writes the new cursor back to state. With `--cursor` provided explicitly, state is read but not written — the caller manages cursor.

### Output

One JSON object per review batch:

```json
{
  "type": "review_batch",
  "pr": 123,
  "batch_id": "RR_kwDOAbc123",
  "submitted_at": "2026-05-31T19:48:13Z",
  "author": "alice",
  "review_state": "changes_requested",
  "comments": [
    {
      "comment_id": "456789",
      "author": "alice",
      "body": "This loop allocates a new array on every iteration; can we hoist it?",
      "path": "src/widget.ts",
      "line": 42,
      "anchor_stale": false,
      "already_handled": false,
      "created_at": "2026-05-31T19:48:13Z"
    }
  ],
  "next_cursor": "RR_kwDOAbc124"
}
```

| Field | Notes |
|---|---|
| `review_state` | `"changes_requested"` \| `"approved"` \| `"commented"` |
| `comments[].anchor_stale` | True when the comment's line no longer exists in current HEAD |
| `comments[].already_handled` | True when prtend's marker is present in an existing reply on this comment's thread |
| `next_cursor` | The cursor to pass on the next call (already written to state if `--cursor` was omitted) |

### Exit codes

Same as `ci-watch`.

---

## `prtend watch`

Multiplexes `ci-watch` and `reviews-poll`. Returns the first event of any type that arrives. Also reports PR-closed events that occur during the watch.

### Synopsis

```
prtend watch --pr N [--block | --once | --timeout S]
```

### Flags

Same as `ci-watch`.

### Output

One JSON object whose `type` indicates the event source:

```json
// CI event — same shape as ci-watch output
{ "type": "ci", "pr": 123, "state": "failure", "checks": [...], "failures": [...] }

// Review batch — same shape as reviews-poll output
{ "type": "review_batch", "pr": 123, "batch_id": "...", "comments": [...] }

// PR closed mid-watch — signals end of watch session
{ "type": "pr_closed", "pr": 123, "final_state": "merged", "closed_at": "2026-05-31T20:14:02Z" }
```

The skill switches on `type`.

### Exit codes

Same as `ci-watch`. Additionally: when `type == "pr_closed"` is emitted, prtend also clears the PR's state file before exiting 0 — the skill knows the session is over and can drop its subscription marker.

---

## `prtend note-post`

Post a resolution note (with idempotency marker) as a reply to a review comment. Never resolves the thread.

### Synopsis

```
prtend note-post --pr N --comment C --kind KIND <kind-specific flags>
```

### Flags

| Flag | Required | Purpose |
|---|---|---|
| `--pr N` | yes | PR/MR number |
| `--comment C` | yes | Comment ID to reply to |
| `--kind KIND` | yes | One of `reject` / `accept` / `halt` / `defer` (note: `ignore` is not valid — Ignore posts nothing) |
| `--reason TEXT` | for `reject` and `halt` | Human-readable reason |
| `--commit HASH` | for `accept` | Commit containing the fix |
| `--doc PATH` | for `defer` | Path to the defer Markdown doc |

Kind/flag pairings are enforced at parse time; exit 2 on mismatch.

### Output

```json
{
  "posted": true,
  "comment_id": "456789",
  "reply_id": "456810",
  "kind": "accept",
  "marker_version": "v1",
  "body": "<!-- prtend: handled v1 -->\nResolution: Accept — fixed in 4f7a2c1"
}
```

### Exit codes

| Code | Condition |
|---|---|
| 0 | Note posted |
| 2 | Bad flags, missing kind-specific flag, invalid kind |
| 3 | Forge CLI missing or not authed |
| 4 | Comment not found, or comment already has a `prtend` marker (idempotent re-call surfaces this rather than double-posting) |

### Example

```
$ prtend note-post --pr 123 --comment 456789 --kind accept --commit 4f7a2c1
{"posted":true,"comment_id":"456789","reply_id":"456810","kind":"accept","marker_version":"v1","body":"<!-- prtend: handled v1 -->\nResolution: Accept — fixed in 4f7a2c1"}
```

---

## `prtend defer-write`

Write a defer Markdown document capturing a review comment for later. Returns the path. Does *not* post a note — the skill should call `defer-write` first to get the path, then `note-post --kind defer --doc PATH`.

### Synopsis

```
prtend defer-write --pr N --comment C --reason REASON
```

### Flags

| Flag | Required | Purpose |
|---|---|---|
| `--pr N` | yes | PR/MR number |
| `--comment C` | yes | Comment ID being deferred |
| `--reason REASON` | yes | Human-readable reason for deferral |

### Output

```json
{
  "path": "/home/beau/.config/prtend/deferred/123-456789.md",
  "pr": 123,
  "comment_id": "456789",
  "comment_url": "https://github.com/owner/repo/pull/123#discussion_r456789"
}
```

The file is written with the structure shown in `overview.md` (YAML frontmatter + sections). Existing files are not overwritten; re-calling for the same `(pr, comment)` returns the existing path with exit 0.

### Exit codes

| Code | Condition |
|---|---|
| 0 | Doc written or already existed |
| 2 | Bad flags |
| 3 | Forge CLI missing or not authed (needed to fetch comment context) |
| 4 | Comment not found |

---

## `prtend config`

Manage the prtend config file.

### Subcommands

```
prtend config init <flags>       # write a new config file from flags
prtend config show               # print the active config as JSON
prtend config get KEY            # print the value of a single key
prtend config set KEY VALUE      # mutate a single key
prtend config path               # print the active config file path
```

### `config init` flags

The skill is responsible for prompting the user; the CLI just writes the file given the values.

| Flag | Required | Purpose |
|---|---|---|
| `--system-reviewer LOGIN` | no, repeatable | System reviewer auto-requested on every PR |
| `--optional-reviewer LOGIN` | no, repeatable | Optional reviewer presented on every PR |
| `--watch-strategy STRATEGY` | yes | `blocking` / `poll-on-resume` / `background` |
| `--write-target TARGET` | yes | Where to write the config: `env` (uses `$PRTEND_CONFIG`), `xdg`, or `repo` |
| `--poll-interval-seconds N` | no | Default 15 |
| `--ci-retry-limit N` | no | Default 3 |
| `--force` | no | Overwrite existing config without prompting |

### `config init` output

```json
{
  "written_to": "/home/beau/.config/prtend/owner-repo.yml",
  "write_target": "xdg",
  "keys_set": ["system_reviewers", "optional_reviewers", "watch_strategy", "write_target", "poll_interval_seconds", "ci_retry_limit"]
}
```

### `config show` output

```json
{
  "active_config_path": "/home/beau/.config/prtend/owner-repo.yml",
  "resolution_chain": [
    { "source": "env", "path": null, "active": false },
    { "source": "xdg", "path": "/home/beau/.config/prtend/owner-repo.yml", "active": true },
    { "source": "repo", "path": "/home/beau/code/repo/.claude/pr-reviewers.yml", "active": false }
  ],
  "values": {
    "system_reviewers": ["copilot"],
    "optional_reviewers": ["alice", "bob"],
    "watch_strategy": "blocking",
    "write_target": "xdg",
    "poll_interval_seconds": 15,
    "ci_retry_limit": 3
  }
}
```

### `config get` / `set` / `path`

- `get KEY` → prints the value (raw, not JSON-wrapped) on stdout
- `set KEY VALUE` → mutates and exits 0; for list-valued keys, accepts comma-separated input or repeated `--append KEY=VALUE` form (TBD; for v0, comma-separated)
- `path` → prints the active config file path on stdout

### Exit codes

| Code | Condition |
|---|---|
| 0 | Success |
| 2 | Bad flags, unknown key, malformed value |
| 4 | Config file unreadable or corrupted |

---

## `prtend doctor`

Run preconditions and consistency checks. With `--fix`, attempt safe repairs.

### Synopsis

```
prtend doctor [--fix] [--check CHECK_NAME ...]
```

### Flags

| Flag | Purpose |
|---|---|
| `--fix` | Apply safe repairs (e.g. clean stale state files) |
| `--check NAME` | Run only the named check (repeatable). Without it, all checks run. |

### Output

```json
{
  "checks": [
    { "name": "forge_cli_installed", "status": "pass", "message": "gh 2.62.0 detected", "fixable": false },
    { "name": "forge_cli_authed",    "status": "pass", "message": "Authenticated as procrastivity", "fixable": false },
    { "name": "config_readable",     "status": "pass", "message": "Loaded from /home/beau/.config/prtend/owner-repo.yml", "fixable": false },
    { "name": "state_dir_writable",  "status": "pass", "message": "Writable: /home/beau/.local/state/prtend/owner-repo/", "fixable": false },
    { "name": "stale_subscriptions", "status": "warn", "message": "2 state files for closed PRs (PR #115, #117)", "fixable": true, "fix_action": "remove stale state files" },
    { "name": "marker_consistency",  "status": "pass", "message": "All known PR threads have marker v1", "fixable": false }
  ],
  "summary": { "pass": 5, "warn": 1, "fail": 0 },
  "fixed": []
}
```

When `--fix` is passed, fixable warns/fails are applied and reported in `fixed`:

```json
{
  ...,
  "fixed": [
    { "check": "stale_subscriptions", "action": "removed", "details": ["/home/beau/.local/state/prtend/owner-repo/115.json", "/home/beau/.local/state/prtend/owner-repo/117.json"] }
  ]
}
```

### Standard checks

| Name | What it verifies |
|---|---|
| `forge_cli_installed` | `gh` or `glab` present on PATH |
| `forge_cli_authed` | `gh auth status` / `glab auth status` succeeds |
| `forge_cli_version` | Installed CLI version meets prtend's minimum |
| `config_readable` | Active config (per resolution chain) parses |
| `state_dir_writable` | Can create files in the state directory |
| `stale_subscriptions` | State files exist for PRs that are now closed/merged |
| `marker_consistency` | Existing prtend notes use known marker versions |

### Exit codes

| Code | Condition |
|---|---|
| 0 | All checks pass, or all failures were fixed with `--fix` |
| 1 | One or more `fail` results without `--fix` (or unfixable) |
| 2 | Bad flags |

---

## Composition patterns

How the SKILL composes these commands. Each pattern below is normative — the SKILL.md document references this section.

### Entry decision

```
detect → if pr is null and intent is "submit PR" → pr-open
       → if pr is null and intent is "commit + push" → done
       → if pr_state is "open" or "draft" → enter watch
       → if pr_state is "closed" or "merged" and intent is "submit PR" → ask user
       → if pr_state is "closed" or "merged" and intent is "commit + push" → done
```

### Watch loop (blocking strategy)

```
loop:
  event = watch --pr N --block --timeout 300
  if event is empty (timeout) → continue
  if event.type == "ci" and state == "failure":
    if any failure.signature has prtend_state_ci_attempts < 3:
      try a fix → commit → push → continue
    else:
      ask user
  if event.type == "review_batch":
    for each comment where not already_handled and not anchor_stale:
      evaluate → {reject | accept | ignore | ask}
      apply resolution (note-post / defer-write + note-post / no-op)
    for each comment where anchor_stale:
      ask
  if event.type == "pr_closed":
    break
```

### Single review comment resolution

```
Evaluate the comment with full context. Pick one:

reject:  note-post --pr N --comment C --kind reject --reason R
accept:  apply fix, commit (hash H), push
         note-post --pr N --comment C --kind accept --commit H
ignore:  (do nothing — no note)
ask:     prompt user; on response:
  reject/accept/ignore: as above
  halt:   note-post --pr N --comment C --kind halt --reason R
  defer:  defer-write --pr N --comment C --reason R → path P
          note-post --pr N --comment C --kind defer --doc P
```

### Post-PR-creation reviewer flow

```
pr-open --title T --body B  # adds system reviewers automatically
if optional_reviewers configured:
  prompt user with multi-select (no defaults)
  pr-open ... --optional-reviewer X --optional-reviewer Y  # SKILL re-invocation? No:
```

Note on the above: the optional-reviewer selection happens **before** `pr-open` is called, in a single invocation. The SKILL gathers the user's optional-reviewer choices first, then passes them all to a single `pr-open` call. If the SKILL discovers it needs to add reviewers after the fact, use the forge CLI directly via a future `prtend reviewer-add` subcommand (not in v0 — out of scope).

---

## What's not in v0

- `prtend reviewer-add` — adding reviewers after PR creation. Use `gh pr edit` / `glab mr update` manually if needed.
- `prtend pr-close`, `prtend pr-reopen` — out of scope; the skill never closes a PR.
- `prtend pr-update` — title/body edits. Use forge CLI directly.
- `prtend search` — full-text search across deferred docs. The user uses `grep` over `<config-dir>/deferred/` for v0.
- Anything that resolves a thread, marks a comment resolved, or merges a PR.

---

## See also

- `overview.md` — workflow spec and decision rules.
- `forge-mapping.md` — `gh` / `glab` command translations and JSON shape mappings.
- `skill-prompts.md` — SKILL.md content, decision-logic prompts, example transcripts.
