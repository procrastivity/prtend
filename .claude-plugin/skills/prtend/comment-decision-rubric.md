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
