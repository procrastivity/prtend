# Step 15 — `prtend reviews-poll` subcommand

## Context

Land the second of the three watch primitives. `prtend reviews-poll` is what the skill calls inside the review half of a watch session: it fetches review batches that have arrived since the recorded cursor, emits one JSON event per batch on stdout, persists the new cursor, and exits. With ci-watch already in place (step 14) this is the last piece needed before the `watch` multiplexer (step 16) can fan the two together. Today the skill can detect a PR (step 07), open one (step 08), post notes (step 10), defer (step 11), and watch CI (step 14) — but it has no way to learn about new review comments, so the review branch of `../overview.md` § "Watch session" still has nothing to react to.

This step composes the read-only review surface already in `prtend-forge-lib.bash` from step 04 (`prtend_forge_reviews_since`, `prtend_forge_review_comments`, `prtend_forge_comment_body`), the per-PR cursor helpers from step 05 (`prtend_state_set_cursor` / `prtend_state_get_cursor`, which already point at `.last_review_cursor`), the marker-detection helper from step 06 (`prtend_note_is_handled`), and the PR-state preflight from step 04 (`prtend_forge_pr_state`, already reused by ci-watch). It introduces no new forge ops and no new state-lib functions — every primitive is already shipped.

The one piece of *new* work outside the subcommand file is the `anchor_stale` projection: `prtend_forge_review_comments` emits `anchor_stale: false` unconditionally (see the comment at `lib/prtend/prtend-forge-lib.bash:594`); the subcommand overwrites it after diffing the comment's `(path, line)` against the current HEAD. That logic lives in the subcommand, not the forge lib, because the forge lib has no view of the local checkout.

See `../cli-contract.md` § "`prtend reviews-poll`" for the output contract and exit-code table, `../forge-mapping.md` §§ "Reviews / discussions since cursor" / "Comments in a review batch" / "Single comment body (for marker detection)" for the per-forge command shapes the forge lib already implements, and `../overview.md` § "Watch session" → review batch handling for the workflow this primitive feeds (skill iterates per-comment through the decision tree, calling `note-post` or `defer-write` per outcome).

## Prerequisites

- Step 02 (`dispatcher`) complete — `bin/prtend` already routes `reviews-poll` to `lib/prtend/prtend-subcommands/reviews_poll.bash` and calls `prtend_cmd_reviews_poll`; `prtend_log_*`, `prtend_atomic_write`, `prtend_repo_slug`, `prtend_json_get`, and the `--verbose` plumbing are available.
- Step 03 (`forge-detect`) complete — `prtend_forge_cli_ready` is the readiness gate.
- Step 04 (`forge-read`) complete — `prtend_forge_reviews_since`, `prtend_forge_review_comments`, `prtend_forge_review_thread_bodies`, and `prtend_forge_pr_state` are the four forge ops this subcommand uses, in that order per batch.
- Step 05 (`state`) complete — `prtend_state_set_cursor` / `prtend_state_get_cursor` are already wired to `.last_review_cursor` in the per-PR state file. No state-lib additions are needed.
- Step 06 (`notes`) complete — `prtend_note_is_handled` is the marker grep used to fill `already_handled`.
- Step 14 (`ci-watch`) complete — establishes the watch-primitive flag conventions (`--block` / `--once` / `--timeout S`) and the PR-closed-mid-watch contract (exit 4 with documented stderr, no stdout). reviews-poll follows the same shape so the multiplexer in step 16 can treat them symmetrically.

Required on the host for smoke tests: the forge CLI matching the checkout (`gh` or `glab`), authenticated, an open PR/MR with at least one submitted review (GitHub) or one discussion with a settled note (GitLab). For GitLab, the per-discussion quiet-window default of 60s applies — a smoke test against a freshly-posted note will not return until the window elapses unless `$PRTEND_QUIET_WINDOW` is reduced.

## Goal

After this step:

- `bin/prtend reviews-poll --pr N --block` reads the recorded cursor, calls `prtend_forge_reviews_since` once, and:
  - if any batches are returned, emits one JSON object per batch on stdout, advances the cursor, exits 0;
  - otherwise enters a poll loop until at least one batch arrives, then emits and exits 0.
- `bin/prtend reviews-poll --pr N --once` makes a single call and emits **zero or more** JSON events covering anything pending since the cursor. Exits 0 either way. Does not block.
- `bin/prtend reviews-poll --pr N --block --timeout S` is `--block` wrapped in a wall-clock bound. On timeout it exits 0 with **no output**, no cursor write.
- `bin/prtend reviews-poll --pr N --once --cursor CURSOR` reads from the supplied cursor instead of state, runs once, and does **not** write the cursor back. `--cursor` is honored on `--block` too (same read-only-cursor semantics — the caller manages cursor in that case as well).
- Each emitted event matches `../cli-contract.md` § "`prtend reviews-poll`" → "Output": `{type:"review_batch", pr, batch_id, submitted_at, author, review_state, comments[], next_cursor}`. `comments[]` carries fully-projected comment objects (`comment_id`, `author`, `body`, `path`, `line`, `anchor_stale`, `already_handled`, `created_at`).
- `anchor_stale` is true when the comment's `(path, line)` no longer exists at the current HEAD; false otherwise. Computed locally by diffing, never trusted from the forge.
- `already_handled` is true when the comment thread already contains a prtend marker. Computed by calling `prtend_forge_review_thread_bodies "$pr" "$comment_id"` (the same idempotency primitive `note-post` uses; see `lib/prtend/prtend-subcommands/note_post.bash:122`) and running the concatenated thread bodies through `prtend_note_is_handled`. The marker lives in the *reply* `note-post` writes — sibling walks of the batch's `comment_ids` would miss replies posted to the same thread but outside the current review (the common case on GitHub).
- `next_cursor` is the cursor the *next* call should resume from — for GitHub the largest review id observed across the emitted batches; for GitLab the latest settled-note ISO timestamp. The same value is written to state when `--cursor` was not passed.
- PR-closed-mid-poll is observable. If the PR transitions to `closed`/`merged` while the loop is waiting for the first batch, `reviews-poll` exits 4 with stderr `prtend: PR <n> closed during poll` and no stdout. Symmetric to ci-watch's PR-closed contract.
- No new forge entry points, no new state-lib functions, no changes to the notes lib. The only new file is the subcommand.

## Files to create or modify

- `lib/prtend/prtend-subcommands/reviews_poll.bash` (NEW)
- `test/fixtures/reviews_poll/` (NEW)
- `test/test-reviews-poll.sh` (NEW) — match `test/test-ci-watch.sh` harness style.

No changes to `bin/prtend`, `prtend-lib.bash`, `prtend-state-lib.bash`, `prtend-notes-lib.bash`, `prtend-forge-lib.bash`, `prtend-signature-lib.bash`, the `config` / `defer-write` / `note-post` / `pr-open` / `ci-watch` subcommand files, or `docs/`. If you find yourself touching them, you've drifted out of scope.

## Implementation

### `lib/prtend/prtend-subcommands/reviews_poll.bash`

Public surface:

```bash
prtend_cmd_reviews_poll "$@"   # parses flags, samples / blocks / emits, returns documented exit codes
```

Flag parsing (same conventions as `ci-watch`):

- `--pr N` — required; must match `^[0-9]+$`. Exit 2 otherwise.
- `--block` — default if neither `--once` nor `--timeout` is given. Idempotent if specified explicitly.
- `--once` — mutually exclusive with `--block` and `--timeout`. Exit 2 on conflict with `prtend: --once and --block are mutually exclusive` (or analogous wording for `--timeout`).
- `--timeout S` — integer seconds, `^[1-9][0-9]*$` (reject 0 and dash-leading values). Implies `--block`; explicit `--block --timeout S` is allowed; `--once --timeout S` is exit 2.
- `--cursor CURSOR` — optional, free-form string. When present, the resolved cursor for the call is this value; state is *not* written back at the end. When absent, the cursor is read from `prtend_state_get_cursor "$pr"` (empty string is allowed and means "all"); state is written at the end. Mirror the `ci-watch` rule of trusting the contract — no normalization of the cursor string.
- Anything else → exit 2.

Composition (in order):

1. **Git repo + readiness gate.** `git rev-parse --git-dir >/dev/null` or exit 1 (`prtend: not in a git repository`). Then `prtend_forge_cli_ready`: propagate exit 1/3 verbatim. No offline path — review state lives on the forge.

2. **Pre-flight PR existence + state.** Call `prtend_forge_pr_state "$pr"` once. If the PR is not found, exit 4 with `prtend: PR <n> not found`. If the PR is already `closed`/`merged` on entry, exit 4 with `prtend: PR <n> is <state>` — symmetric to ci-watch.

3. **Resolve cursor.** If `--cursor` was passed, `cursor="$flag_cursor"` and `write_cursor=false`. Otherwise `cursor="$(prtend_state_get_cursor "$pr")"` (empty allowed) and `write_cursor=true`.

4. **Branch on mode:**

   - **`--once`:** call `_reviews_poll_emit_pending "$pr" "$cursor" "$write_cursor"` exactly once. The helper does the `reviews_since` → `review_comments` → projection → emit dance described below. Whatever it returns (0 batches or N batches), exit 0 unless the call surfaced exit 4 (PR closed → propagate).
   - **`--block` (with or without `--timeout`):** track elapsed time in-process — do *not* wrap the loop in `timeout(1)`. Capture `start="$SECONDS"` before entering the loop. Loop body:
     1. Call the same helper.
     2. If it emitted ≥1 batch, exit 0. (The helper has already written the cursor when `write_cursor=true`.)
     3. Else re-check PR state via `prtend_forge_pr_state "$pr"`; on `closed`/`merged`, exit 4 with the documented stderr.
     4. If `--timeout` is present and `(( SECONDS - start >= timeout_seconds ))`, return 0 with no output and no cursor write (clean timeout).
     5. `sleep "${PRTEND_POLL_INTERVAL:-15}"` (cap the sleep to the remaining wall-clock budget when `--timeout` is set, so a short timeout actually returns near its bound) and repeat.

     This mirrors `_prtend_forge_ci_watch_block_common` in `lib/prtend/prtend-forge-lib.bash:1140` — same elapsed-time pattern, same 124-style semantics absorbed locally without the `timeout(1)` wrap.

5. **Helper `_reviews_poll_emit_pending <pr> <cursor> <write_cursor>`** (private to this file, prefix `_reviews_poll_`):
   - Call `prtend_forge_reviews_since "$pr" "$cursor"` and capture the `{batches, next_cursor}` JSON. Propagate any non-zero forge exit code.
   - Read `count = batches | length`. If 0, return 0 without emitting or writing the cursor (the caller decides whether to loop).
   - For each batch (0..count-1):
     - Extract `batch_id`, `submitted_at`, `author`, `state` (review_state), `comment_ids[]`.
     - Call `prtend_forge_review_comments "$pr" "$batch_id"` → `{comments: [...]}`. Note: for GitHub the second argument is the review id (== `batch_id`); for GitLab it is the discussion id (also `batch_id`). The dispatch is identical from the subcommand's perspective.
     - For each comment in `comments[]`:
       - Compute `anchor_stale` locally (see "Anchor staleness" below). Overwrite the `anchor_stale: false` field returned by the forge lib.
       - Compute `already_handled` by calling `prtend_forge_review_thread_bodies "$pr" "$comment_id"` (see `lib/prtend/prtend-forge-lib.bash:737`) and running the result through `prtend_note_is_handled`. The primitive returns the concatenated bodies of every comment in the thread containing `comment_id` — original anchored note + every reply on GitHub, all notes in the discussion on GitLab — which is exactly what `note-post`'s own idempotency probe uses. Treat exit 1 (id unknown — shouldn't happen, since we just received the id from `review_comments`) as "not handled" and move on. Cache the result in a per-batch associative array keyed by `comment_id` (only useful when two projected comments resolve to the same thread, but cheap to keep).
       - Replace `already_handled: …` in the comment object with the computed boolean.
     - Project the per-batch event:
       - `type`: `"review_batch"`
       - `pr`: numeric
       - `batch_id`, `submitted_at`, `author`: from the batch
       - `review_state`: from the batch's `state` field (rename: contract field is `review_state`, forge lib emits `state`)
       - `comments`: the projected comments array
       - `next_cursor`: the `next_cursor` from the `reviews_since` response (same value for every batch in this call — the cursor advances only past the *last* batch)
     - Emit one compact JSON object on stdout.
   - After all batches emitted: if `write_cursor == true`, call `prtend_state_set_cursor "$pr" "$next_cursor"`. Return 0.

### Anchor staleness

`anchor_stale` is the only piece of new logic. The rule is "this `(path, line)` no longer exists at the current HEAD." Implementation:

- If `path` is empty or `line` is null, `anchor_stale = false`. (A comment that wasn't anchored to a line in the first place can't go stale.)
- Else, run `git rev-parse --verify -q "HEAD:$path"`. If the path doesn't exist at HEAD, `anchor_stale = true`.
- Else, count the lines: `lines="$(git show "HEAD:$path" | wc -l)"`. If `line > lines`, `anchor_stale = true`.
- Else `anchor_stale = false`.

This is a deliberately cheap check — not a full diff-rename detection, not a line-content comparison. The skill treats a true `anchor_stale` as a hint to escalate (the comment is *probably* obsolete) but the rubric in `comment-decision-rubric.md` is the final arbiter. A cheap false negative (line still exists but was rewritten) is acceptable; a cheap false positive (path renamed) is acceptable too. Don't reach for `git log --follow`.

Cache the per-`path` result inside `_reviews_poll_emit_pending` (associative array `path → "0"|"1"` for existence, and `path → <int>` for line count) so a batch with N comments on the same file pays the `git show` cost once.

### `lib/prtend/prtend-forge-lib.bash` — no changes

Every forge primitive this subcommand needs is already public (`prtend_forge_reviews_since`, `prtend_forge_review_comments`, `prtend_forge_comment_body`, `prtend_forge_pr_state`, `prtend_forge_cli_ready`). If you find yourself adding a new private — stop. The shape mismatch (forge lib's `state` vs contract's `review_state`, forge lib's `anchor_stale: false` vs computed) is intentionally absorbed by the subcommand, not pushed into the lib. The lib's contract is "canonical forge data"; the subcommand's contract is "the CLI output shape."

### `lib/prtend/prtend-state-lib.bash` — no changes

`prtend_state_set_cursor "$pr" "$cursor"` and `prtend_state_get_cursor "$pr"` already do what we need (they write `.last_review_cursor` and `.last_review_at`; see `lib/prtend/prtend-state-lib.bash:130-160`). The cursor type is opaque — GitHub IDs are numeric strings, GitLab cursors are ISO timestamps; the state lib stores either verbatim.

### Key decisions

- **`--cursor CURSOR` is read-only.** When the caller passes a cursor explicitly, prtend reads from it but does not write back. This matches `../cli-contract.md` § "`prtend reviews-poll`" → "Flags". The semantics are "the caller is managing cursor on its own"; silently overwriting state would surprise that caller on the next implicit-cursor call.
- **`next_cursor` is the same value in every event of a single call.** The forge lib computes one `next_cursor` per `reviews_since` invocation; we emit it on every batch in that response so a consumer that processes one event at a time can drop the rest and still resume correctly from any single observed event. Don't try to compute per-batch cursors — that's not what the forge lib returns and the contract treats it as a single resume token.
- **Per-batch second call to `review_comments` is unavoidable on GitHub.** The reviews endpoint returns batch metadata; comments require a follow-up call per review id. On GitLab the discussion endpoint already returns notes, but the canonical `_prtend_forge_gl_review_comments` still re-fetches the discussion by id for shape symmetry. Don't try to optimize by reading the GitLab discussions response twice in the subcommand — the forge lib is the right place to dedupe that, and it's already a separate step's concern.
- **`already_handled` uses `prtend_forge_review_thread_bodies`, not a sibling walk of the batch's `comment_ids`.** `note-post` writes the marker to a *reply* keyed by the original comment id — on GitHub that reply is part of the PR-level review-comments stream and does NOT appear in the source review's `comment_ids` (and won't on subsequent reviews either). The thread-bodies primitive is the same one `note_post.bash:122` uses for its own double-post guard; reusing it keeps the "what counts as handled" rule in exactly one place. A sibling walk would miss the common case (prior run replied via `note-post`, current run re-polls the same review) and let the watch loop double-post.
- **The thread-bodies fetch includes the reviewer's own comment body.** `prtend_forge_review_thread_bodies` concatenates root + replies, so a human who quotes the marker into the original comment will register as handled. That's the conservative call — we won't double-post — and it matches `note-post`'s own behavior. The decision rubric handles the surprise case; the CLI just reports.
- **Anchor staleness uses the cheapest possible check.** No `git diff` walk, no line-by-line content compare. The skill's downstream rubric is what decides whether stale means "skip" or "escalate" — the CLI's job is to mark the bit.
- **`--block` re-checks PR state on every poll cycle, not just on entry.** The pre-flight check in step 2 catches "PR already closed"; the loop's per-cycle check catches "PR closed while we were waiting." Without it the loop would block forever against a merged PR.
- **`PRTEND_POLL_INTERVAL` is the only tunable.** No `--interval` flag. Same rationale as ci-watch (step 14): per-subcommand flag divergence complicates the watch multiplexer.
- **`PRTEND_QUIET_WINDOW` applies on GitLab only.** It's already honored inside `_prtend_forge_gl_reviews_since`; the subcommand does not need to know about it. A test that wants to bypass the window sets `PRTEND_QUIET_WINDOW=0` before calling.
- **No `--cursor` validation.** The cursor is opaque to the subcommand; pass it through. The forge lib's per-forge handler decides what's valid (GitHub: numeric; GitLab: ISO timestamp). A malformed cursor produces a forge error, which propagates as exit 1.
- **In-process elapsed-time check, no `timeout(1)` wrap.** ci-watch lifts the wall-clock bound into `_prtend_forge_ci_watch_block_common` so it can short-circuit between polls and `return 124`; reviews-poll's loop lives in the subcommand, so the same pattern lives here: track `start="$SECONDS"`, compare per cycle, return 0 (no output, no cursor write) when the budget is spent. A `timeout --preserve-status` wrap would not produce 124 — `--preserve-status` returns the child's exit status (typically 143 from SIGTERM), defeating the 124-maps-to-clean-timeout contract; and a plain `timeout` wrap would mask the subcommand's own non-zero exits (e.g. PR-closed exit 4 would become 124 if it raced the timeout). Doing it in-process keeps both exit codes and "no partial cursor advance" cleanly under our control.
- **Cursor is written exactly once per call, after all batches are emitted.** If the second `review_comments` fetch fails mid-batch, no cursor advance — the next call will re-fetch from the same cursor and re-emit. Idempotency on the skill side is guaranteed by the marker (`already_handled` will flip true on the second pass for any thread the skill already replied to).

### Test shape

Match `test/test-ci-watch.sh` exactly. Mock `prtend_forge_dispatch` by shadowing the `_prtend_forge_<gh|gl>_*` privates; do not exercise real network and do not spawn real `sleep` loops — the subcommand's poll loop body should be parametrized on `$PRTEND_POLL_INTERVAL` and the test sets it to `0`. For the staleness tests, build a tiny on-disk repo in a tmp dir (the harness already does this) and `git add`/`git commit` real files so `git show "HEAD:$path"` returns what the test expects.

Fixtures under `test/fixtures/reviews_poll/`:

- `reviews_since.empty.json` — `{batches:[], next_cursor:"0"}`.
- `reviews_since.one_batch.json` — one batch with two `comment_ids`.
- `reviews_since.two_batches.json` — two batches; the second's `submitted_at` is later (so order assertions are meaningful).
- `review_comments.batch_a.json` — `{comments:[...]}` matching the first batch, with one comment anchored to `src/widget.ts:10` and one to `src/widget.ts:9999` (forces stale-path-line-count branch).
- `review_comments.batch_b.json` — second batch's comments.
- `thread_bodies.handled.txt` — concatenated thread (root + replies) containing `<!-- prtend: handled v1 -->`.
- `thread_bodies.unhandled.txt` — concatenated thread without the marker.
- `pr_state.open.json`, `pr_state.closed.json`, `pr_state.merged.json` — for the preflight and mid-loop paths.

Test cases (one assertion block each):

1. `--once` with no prior cursor, forge returns `reviews_since.empty.json` → no output, cursor not written, exit 0.
2. `--once` with prior cursor `"5"`, forge returns `reviews_since.one_batch.json` (one batch, two comments; one anchor is stale; the second comment's thread contains a marker-bearing reply, surfaced via the mocked `review_thread_bodies`) → emits one event with `comments[0].anchor_stale=true`, `comments[1].already_handled=true`, cursor written to the `next_cursor` from the response.
3. `--once` with prior cursor and `reviews_since.two_batches.json` → emits two events on stdout, both carry the same `next_cursor`, cursor written once.
4. `--once --cursor abc` with `reviews_since.one_batch.json` → emits one event, cursor NOT written to state.
5. `--block` with empty first poll, then one batch on the second poll → emits one event, exits 0. (`PRTEND_POLL_INTERVAL=0`.)
6. `--block --timeout 1` with always-empty polls → exits 0 with no output, no cursor write.
7. `--once` against a PR that returns `pr_state == closed` on entry → exit 4 with the documented stderr; no output.
8. `--block` where the PR closes mid-loop (mock flips `pr_state` to `merged` between polls) → exit 4 with the documented stderr; no output.
9. `--pr foo` (non-numeric) → exit 2.
10. `--once --block` → exit 2 with the mutual-exclusion error.
11. Anchor-staleness unit-ish test: build a sandbox repo with `src/widget.ts` (20 lines), then directly call the subcommand's anchor-check helper (or invoke the subcommand end-to-end with a fixture that names `src/widget.ts:10` and `src/widget.ts:9999` and `does/not/exist.ts:1`) and assert the three booleans.
12. `already_handled` thread-walk + cache test: a batch with two projected comments whose marker lives in a thread reply (NOT in either projected comment, NOT in the batch's `comment_ids`) → both `comments[*].already_handled=true`. Mock `review_thread_bodies` with a per-comment-id call counter and assert each id is fetched at most once (verifying the per-batch cache; proves we never fall back to a sibling walk).

## Verification

```bash
# Lint & shape
shellcheck bin/prtend lib/prtend/prtend-lib.bash lib/prtend/prtend-forge-lib.bash \
           lib/prtend/prtend-state-lib.bash lib/prtend/prtend-notes-lib.bash \
           lib/prtend/prtend-signature-lib.bash \
           lib/prtend/prtend-subcommands/*.bash
# → no output, exit 0

# Help advertises reviews-poll
bin/prtend --help | grep -q '\breviews-poll\b'
# → exit 0

# Flag-level errors
bin/prtend reviews-poll                      # missing --pr
# → exit 2; stderr mentions --pr

bin/prtend reviews-poll --pr foo             # non-numeric pr
# → exit 2

bin/prtend reviews-poll --pr 1 --once --block
# → exit 2; stderr mentions mutually exclusive

bin/prtend reviews-poll --pr 1 --once --timeout 5
# → exit 2

# Subcommand-level test harness
bash test/test-reviews-poll.sh
# → "OK" on stdout, exit 0

# Manual smoke (against a real PR with at least one submitted review; substitute your own number):
bin/prtend reviews-poll --pr 7 --once
# → 0 or 1+ lines of JSON; exit 0; each line parses as one review_batch event
#   with .type == "review_batch", .pr == 7, .comments[] populated.

PRTEND_POLL_INTERVAL=2 bin/prtend reviews-poll --pr 7 --block --timeout 5
# → exit 0; usually no output (no new reviews inside 5s).

# State file inspection after a manual emitting run:
jq '.last_review_cursor, .last_review_at' \
   "$XDG_STATE_HOME/prtend/$(git remote get-url origin | sed 's|.*[/:]||; s|\.git$||')/7.json"
# → shows the cursor and timestamp written by the call.

# Pre-commit
pre-commit run --all-files
# → all hooks pass
```

## Done

- [ ] `lib/prtend/prtend-subcommands/reviews_poll.bash` exists; `prtend_cmd_reviews_poll` handles `--pr`, `--block`, `--once`, `--timeout`, `--cursor` with documented exit codes
- [ ] No new public functions in `prtend-forge-lib.bash` or `prtend-state-lib.bash`
- [ ] Each emitted event matches the contract shape (`type`, `pr`, `batch_id`, `submitted_at`, `author`, `review_state`, `comments[]`, `next_cursor`)
- [ ] `comments[].anchor_stale` is computed locally against HEAD and overrides the forge lib's `false`
- [ ] `comments[].already_handled` is computed by walking the batch's `comment_ids` and running each fetched body through `prtend_note_is_handled`; per-batch body fetches are cached
- [ ] `--cursor CURSOR` overrides state read and suppresses state write; both `--once` and `--block` respect it
- [ ] PR closed mid-poll surfaces as exit 4 with the documented stderr and no stdout
- [ ] `--timeout S` on `--block` exits 0 with no output on timeout (not 124, not stderr noise)
- [ ] `test/test-reviews-poll.sh` covers the twelve cases listed under "Test shape"; `bash test/test-reviews-poll.sh` is green
- [ ] `shellcheck` clean across the touched libs and the new subcommand
- [ ] `pre-commit run --all-files` clean
- [ ] One commit on a feature branch: `feat(reviews-poll): add reviews-poll subcommand (step 15)`
