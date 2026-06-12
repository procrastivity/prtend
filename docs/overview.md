# `prtend` — Overview

> **This doc is the shared workflow reference for `prtend`.** Other planning docs point back here for trigger rules, decision logic, and definitions. Read this first; skim the others as reference material.

`prtend` watches your PR while you pretend you're actually still there. After you push code to a branch with an open Pull Request (or Merge Request), it subscribes to CI events and code-review activity on that PR, auto-fixes what looks fixable, and resolves review comments with explicit notes — never marking threads resolved itself, because humans confirm.

It ships as two artifacts from one repo:

1. **A CLI** (`prtend`) that does all the deterministic, LLM-free work — detecting `gh` vs `glab`, opening PRs, polling CI, fetching review batches, posting resolution notes.
2. **A Claude Code plugin** that ships one skill (`prtend`) carrying the judgment — evaluating CI failures, deciding on review comments, composing fixes.

The CLI never calls an LLM. All summarization, evaluation, and composition happens in the skill. The skill never invokes `gh` or `glab` directly; the CLI abstracts both.

---

## Architecture

```
agent pushes commits ───────────────────► branch on remote
                                              │
                                              ▼
                            ┌─── prtend detect ──┐
                            │                    │
                       open PR? ──── no ─────► (do nothing)
                            │
                           yes
                            │
                            ▼
                     ┌──────────────┐
                     │   Watching   │ ◄────────┐
                     └──────┬───────┘          │
                            │                  │
            ┌───────────────┼──────────────┐   │
            ▼               ▼              ▼   │
       CI failure     review batch    PR closed
            │               │              │
            ▼               ▼              │
     ┌──────────────┐  ┌───────────────┐   │
     │  Auto-fix    │  │ Per-comment   │   │
     │  ≤3 attempts │  │ Reject/Accept/│   │
     │  per signature│ │ Ignore/Ask    │   │
     └──────┬───────┘  └───────┬───────┘   │
            │                  │           │
       fix succeeds       note posted      │
       (push) ────────────────┴────────────┘
            │
       3 fails or
       unfixable ────► Ask user ──────────► (resolution applied) ──► back to Watching
```

Two principles drive the design:

1. **The CLI is deterministic; the skill is the LLM surface.** Subscribing, polling, posting, and writing files is mechanical work. Evaluating "is this failure fixable", "what does this review comment want", and "what should the fix look like" is judgment work and stays in the skill.
2. **The agent observes but does not finalize.** It posts resolution notes; it never marks threads resolved, never auto-merges, never closes a PR. The author confirms.

---

## Terminology mapping

`prtend` uses neutral names internally; the forge adapter translates at the command layer.

| Neutral name | GitHub | GitLab |
|---|---|---|
| PR | Pull Request | Merge Request |
| Reviewer | Reviewer | Reviewer (Approvers are a separate concept and not used here) |
| Draft | Draft flag | `Draft:` title prefix |
| Resolve | Resolve conversation | Resolve thread |
| Review batch | Submitted review | Settled thread / discussion |
| Forge CLI | `gh` | `glab` |
| Watch CI | `gh pr checks --watch` | poll `glab ci status` |
| Poll reviews | `gh api .../pulls/:n/reviews` | `glab api .../merge_requests/:n/discussions` |

The full forge command map lives in `forge-mapping.md`.

---

## Glossary

| Term | Meaning |
|---|---|
| **Forge** | A code hosting platform with a CLI prtend supports. Today: `gh` (GitHub) or `glab` (GitLab). |
| **PR** | Pull Request or Merge Request, depending on forge. Identified by its forge-assigned number. |
| **Watch session** | The state in which prtend is subscribed to events on a specific PR. One PR per invocation. |
| **Review batch** | A set of review comments submitted together (GitHub: a submitted review; GitLab: a settled discussion thread). prtend reacts at batch boundaries, not per individual comment. |
| **Resolution note** | A reply prtend posts to a review comment recording how the agent handled it. Carries an idempotency marker so future polls recognize handled comments. |
| **Marker** | `<!-- prtend: handled v1 -->`. Inserted as the first line of every resolution note. Used to detect already-handled comments. |
| **CI failure signature** | A stable identifier derived from a failure, format `<tool>:<scope>:<short-rule>` (e.g. `eslint:src-utils-time:no-unused-vars`). Used as the key for the per-signature retry counter. |
| **Defer document** | A Markdown file written when a comment's resolution is "Defer" — captures the comment context, code snippet, and reason. Referenced from the resolution note. |
| **Subscription marker** | A state-file flag indicating prtend is already watching a given PR; prevents double-subscription across pushes. |

---

## Trigger model

Two distinct concerns:

- **PR submission** is a user-initiated operation. The agent ensures the branch is on the remote, checks whether a PR exists, creates one if it doesn't, runs the reviewer flow, then hands off to watch entry.
- **Watch entry** is a post-condition of any push: does this push land on a branch with an open PR? If yes and not already watching, subscribe. Else do nothing.

"Submit PR" simply guarantees the watch-entry post-condition will be true afterward; "commit + push" doesn't.

---

## Entry decision

| User intent | Branch on remote? | Open PR for branch? | Action |
|---|---|---|---|
| Submit PR | No | — | Push branch → create PR → reviewer flow → start watch |
| Submit PR | Yes | No | Create PR for existing branch → reviewer flow → start watch |
| Submit PR | Yes | Yes (open) | Use existing PR (no duplicate) → ensure watching |
| Submit PR | Yes | Closed / merged | Ask user: reopen / new PR / abort |
| Commit + push | No | — | Push; no PR → done |
| Commit + push | Yes | No | Push; no PR → done |
| Commit + push | Yes | Yes (open) | Push → start watch (if not already) |
| Commit + push | Yes | Closed / merged | Push only; do not watch a closed PR |
| Any push | (default branch) | — | Skip entirely |

---

## First-run init (per repo)

Triggered by absence of config across the resolution chain. Prompts for:

- **System reviewers** — auto-requested on every PR (e.g. Copilot, Duo).
- **Optional reviewers** — multi-select on every PR with no default selections.
- **Watch strategy** — `blocking` / `poll-on-resume` / `background-with-cleanup`. Options pruned to those the detected forge CLI can support.
- **Write target** — which slot in the resolution chain (`$PRTEND_CONFIG` env path, XDG, or in-repo `.claude/`) to write the new config to.

Defer documents live alongside whichever config location is chosen (`<config-dir>/deferred/<pr>-<comment-id>.md`).

---

## PR submission

When the user invokes "submit PR" (or the agent has decided one is needed):

1. **Add all system reviewers automatically.**
2. **If optional reviewers are configured:** present them as a multi-select with no default selections. Add whichever the user picks.
3. **Title and body composition is out of scope for prtend.** The agent or user supplies them via CLI flags; prtend doesn't compose them.

The PR is created as a regular (non-draft) PR by default; `--draft` is supported.

---

## Watch session

Entered when a push has landed on a branch with an open PR and prtend isn't already watching it. Preconditions:

- Exactly one PR matches the pushed branch. If zero or multiple, refuse and surface to the user.
- A subscription marker (in-memory for `blocking`; state-file for `background` and `poll-on-resume`) records "already watching."
- Pushes to the default branch (`main`/`master`/etc.) skip the watch entirely.

Two parallel concerns observed during a watch session: **CI events** and **review batches**.

### CI loop

When a CI failure is detected:

1. Inspect the failure and derive its signature.
2. **If it looks fixable** (lint, format, simple type errors, obvious breakage from changed surface): apply a fix, commit, push, continue watching.
3. **If it doesn't look fixable** (infra failure, flaky test, unrelated service): escalate to Ask.
4. Track retries per signature. After **3 failed fix attempts on the same signature**, escalate to Ask.
5. Ask surfaces the failure with options: retry / mark unfixable / abort watch.

Retry counts are keyed on signature, not failure occurrence — three different lint rules failing is three signatures, each with its own counter. A flaky test that fails the same way three times trips the cap.

### Review comment loop

prtend reacts at review-batch boundaries, not per individual comment. On GitHub this means a new review ID; on GitLab, a settled thread / discussion.

For each comment in a new batch that does not already carry a `prtend` resolution note (detected via the marker):

- **Evaluate and pick one of four:** Reject / Accept / Ignore / Ask.
- **Reject** — post a note explaining why the comment is invalid or why the code must stay as-is.
- **Accept** — apply a fix; commit grouping is the agent's call based on the nature of the fixes; the note links the specific commit hash containing that comment's fix.
- **Ignore** — no note posted. The agent doesn't intend to comment on this issue at all.
- **Ask** — halt processing of this single comment, prompt the user. Other comments in the same batch keep processing.

When **Ask** is chosen, the user picks one of five resolutions: **Reject / Accept / Ignore / Halt / Defer**.

- **Halt** — post a note saying the agent has stopped work on this issue pending research. Per-comment scope only; other comments continue. (Whole-session halt is the user's explicit "abort watch" action, not a comment outcome.)
- **Defer** — write a Markdown doc to `<config-dir>/deferred/<pr>-<comment-id>.md` with the comment context, the relevant code snippet, the reason for deferral, and a back-link to the PR. Post a resolution note pointing to that document's path.

**Threads are never marked resolved by prtend.** Even when the agent has applied an accepted fix, the comment thread stays open until the human author confirms.

---

## Note templates

Every note prtend posts begins with the marker:

```
<!-- prtend: handled v1 -->
```

Bodies, by resolution kind:

| Kind | Body |
|---|---|
| Reject | `Resolution: Reject — <reason>` |
| Accept | `Resolution: Accept — fixed in <commit-hash>` |
| Halt | `Resolution: Halt — <reason>; no further work pending research` |
| Defer | `Resolution: Defer — tracked at <path>` |

Ignore posts nothing — that's the definition of Ignore. The marker version (`v1`) lets future format changes coexist with old notes; bumping to `v2` would mean both versions are recognized for idempotency, but new notes use the new format.

---

## Defer documents

Path: `<config-dir>/deferred/<pr>-<comment-id>.md`. Contents:

```markdown
---
pr: 123
comment_id: 456789
forge: github
deferred_at: 2026-05-31T19:48:13Z
reason: <user-supplied reason>
---

# Deferred review feedback — PR #123, comment 456789

**Comment location:** `path/to/file.py:42`

**Reviewer:** @alice

**Original comment:**

> [pasted comment body]

**Code in question:**

```python
[snippet]
```

**Reason for deferral:** [reason]

**Comment link:** https://github.com/owner/repo/pull/123#discussion_r456789
```

These docs are durable — they survive PR close, branch deletion, and machine moves. The intent is that revisiting deferred feedback later (post-merge, in a follow-up PR, or during a refactor) is a matter of `ls <config-dir>/deferred/`.

---

## State and config locations

Resolution chain for config (first hit wins):

1. `$PRTEND_CONFIG` env override
2. `$XDG_CONFIG_HOME/prtend/<repo-slug>.yml`
3. `<repo>/.claude/pr-reviewers.yml`
4. Built-in defaults (empty)

State files live alongside config:

- Config in-repo → state at `<repo>/.claude/prtend-state/<pr>.json` (gitignored)
- Config in XDG → state at `$XDG_STATE_HOME/prtend/<repo-slug>/<pr>.json`

State file contents: subscribed-at timestamp, per-signature CI retry counters, last review-batch cursor.

---

## Edge cases

1. **Closed/merged PR on the branch** — "submit PR" must not silently create a new one. Ask: reopen / new PR / abort.
2. **Push to default branch** — skip the watch flow entirely; there's no PR concept.
3. **Force-push to a watched branch** — stay subscribed; CI re-runs; review state survives.
4. **Multiple remotes** (origin + fork upstream) — follow the active remote (`gh` / `glab` config); surface if ambiguous.
5. **Draft PRs** — watch them. CI runs, comments can land, the loop still applies.
6. **Co-authoring** (open PR on the branch authored by someone else) — still enter watch; the marker plus self-reply skip handle idempotency.
7. **Push fails** (rejected, conflicts) — no watch entry; surface the push failure.
8. **PR HEAD differs from local** (someone else pushed) — treat as a normal CI event after our push; same handling.
9. **Stale review comment** (anchor line no longer exists) — treat as **Ask**, not auto-Ignore. The human decides whether the underlying concern still applies.
10. **Agent's own comments** (self-reply during a session) — skip on subsequent polls.
11. **New comment on a thread after Accept** — treated as a fresh comment in the next review batch; runs through the decision tree again.
12. **Mid-session auth loss** — surface immediately, don't silently retry.
13. **Multiple PRs on the same branch** (possible on GitLab forks) — refuse and ask.
14. **First-run prompts skipped or cancelled** — write nothing, don't subscribe. The next push re-prompts.

---

## What this design explicitly does not address

- **Forges beyond `gh` / `glab`** (Gitea, Bitbucket, Codeberg, Phabricator). Out of scope for v1; the forge-lib could grow to support them later.
- **Thread resolution.** prtend deliberately never resolves threads. Humans confirm.
- **Auto-merge.** Out of scope. The agent watches and addresses feedback; the author decides when to merge.
- **PR title and body composition.** Out of scope; supplied by the user or agent via flags.
- **Cross-PR coordination** (e.g. stacked PRs, dependent branches). One PR per invocation; the user manages the stack manually.
- **Anthropic Code Review skills or other Claude-side review automation.** Orthogonal — prtend reacts to forge-side reviews from any source (human, Copilot, Duo, another agent).
- **Webhooks or server-side event subscription.** prtend polls via the forge CLIs; webhooks would require a host the user must maintain, which is the opposite of the no-infrastructure design.

---

## Reference docs

- **`repo-bootstrap.md`** — repo layout, dispatcher shape, forge-lib function surface, distribution.
- **`cli-contract.md`** — full subcommand reference: flags, output JSON shapes, exit codes.
- **`skill-prompts.md`** — SKILL.md content, decision-logic prompts, example transcripts.
- **`forge-mapping.md`** — GitHub ↔ GitLab term and command translation table, full version.
