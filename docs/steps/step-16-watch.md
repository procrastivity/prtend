# Step 16 — `prtend watch` multiplexer subcommand

## Context

Land the last of the three watch primitives. `prtend watch` is what the skill actually calls inside a watch session: it multiplexes `ci-watch` and `reviews-poll` and emits **one** JSON event for whichever source produces something first — a CI state change (`type:"ci"`), a new review batch (`type:"review_batch"`), or the PR itself transitioning to `closed`/`merged` mid-watch (`type:"pr_closed"`). With this in place the workflow described in `../overview.md` § "Watch session" finally has a single CLI entry point; today the skill has to choose between calling `ci-watch` and `reviews-poll` and would miss whichever one it didn't pick.

This step composes the two existing watch primitives (step 14 — `ci-watch`, step 15 — `reviews-poll`) and the `prtend_forge_pr_state` preflight from step 04. The multiplexer itself does no new forge I/O beyond a periodic `pr_state` re-check; each iteration delegates to `prtend_cmd_ci_watch --once` and `prtend_cmd_reviews_poll --once --cursor …`, takes the first event, and either advances state or forwards what the child already wrote. Critically, the children are invoked in **`--once`** mode (never `--block`) so they never sleep on the multiplexer's behalf — the wall-clock budget is owned entirely by `watch`. The single new lib surface is a state-clear call when `pr_closed` fires (step 05 already ships `prtend_state_clear`, see `lib/prtend/prtend-state-lib.bash:190`); no other libs change.

See `../cli-contract.md` § "`prtend watch`" for the output contract and exit-code table, `../cli-contract.md` § "`prtend ci-watch`" and § "`prtend reviews-poll`" for the per-source event shapes that this subcommand re-emits verbatim, `../overview.md` § "Watch session" for the workflow this primitive feeds, and `../forge-mapping.md` § "Watch event shapes" for the `pr_closed` payload schema.

## Prerequisites

- Step 02 (`dispatcher`) complete — `bin/prtend` already routes `watch` to `lib/prtend/prtend-subcommands/watch.bash` and calls `prtend_cmd_watch`; `prtend_log_*`, `prtend_atomic_write`, `prtend_repo_slug`, `prtend_json_get`, and the `--verbose` plumbing are available.
- Step 03 (`forge-detect`) complete — `prtend_forge_cli_ready` is the readiness gate.
- Step 04 (`forge-read`) complete — `prtend_forge_pr_state` is reused for the entry preflight and the periodic mid-watch re-check that drives `pr_closed`.
- Step 05 (`state`) complete — `prtend_state_get_cursor` / `prtend_state_set_cursor` (review cursor) and `prtend_state_clear` (state-file removal on `pr_closed`) are already wired.
- Step 14 (`ci-watch`) complete — `prtend_cmd_ci_watch` is the CI half of the multiplex. Its `--once` mode contract ("0 events if `state == previous_state`, else exactly 1 event") and its own `state.ci.last_state` write are what `watch` depends on per iteration.
- Step 15 (`reviews-poll`) complete — `prtend_cmd_reviews_poll` is the review half. Its `--once --cursor <c>` mode contract ("emit every pending batch, do **not** write state") is what lets `watch` own the cursor write for the single batch it forwards.

Required on the host for smoke tests: the forge CLI matching the checkout (`gh` or `glab`), authenticated, an open PR/MR with CI configured and at least one history of submitted reviews. `coreutils`-`timeout` is **not** required — `watch` tracks its own wall clock the same way `ci-watch` and `reviews-poll` do.

## Goal

After this step:

- `bin/prtend watch --pr N --block` runs an inline poll loop: each iteration delegates to `prtend_cmd_ci_watch --pr N --once` and `prtend_cmd_reviews_poll --pr N --once --cursor "$cursor"` in that order, re-checks `prtend_forge_pr_state` if both were silent, and either emits **exactly one** JSON event and exits 0 or sleeps `$PRTEND_POLL_INTERVAL` (default 15s) and re-iterates. Matches `../cli-contract.md` § "`prtend watch`" → "Output".
- `bin/prtend watch --pr N --once` runs that loop body **exactly once** (no sleep) and exits 0 — emitting one event if any source had something, zero events otherwise. Never blocks.
- `bin/prtend watch --pr N --block --timeout S` is `--block` wrapped in a wall-clock bound. On timeout it exits 0 with **no output**, no cursor write, no state-file clear. The sleep at the end of the loop body is capped to the remaining budget so the call returns near its bound rather than at the next 15s tick.
- The emitted event matches `../cli-contract.md` § "`prtend watch`" → "Output" — one of:
  - `{type:"ci", pr, state, checks, [failures], previous_state}` — re-emitted verbatim from `ci-watch --once`'s stdout.
  - `{type:"review_batch", pr, batch_id, submitted_at, author, review_state, comments[], next_cursor}` — re-emitted verbatim from the **first** event in `reviews-poll --once`'s stdout. When `reviews-poll` emitted more than one batch in the same iteration, the extra batches are dropped on this call; the next `watch` call picks them up because `watch` writes only the forwarded event's `next_cursor` back to state.
  - `{type:"pr_closed", pr, final_state, closed_at}` — synthesized by `watch` when its periodic `pr_state` re-check sees the PR transition to `closed`/`merged`. `final_state` is the new pr_state value; `closed_at` is whatever `prtend_forge_pr_state` reports for that field (already projected — no new forge op).
- When `type == "pr_closed"` is emitted, `watch` calls `prtend_state_clear "$pr"` **after** the event is written to stdout and **before** returning 0 — the contract in `../cli-contract.md` § "`prtend watch`" → "Exit codes" is "prtend also clears the PR's state file before exiting 0." If the clear fails, log a warning to stderr but still return 0 — the event is already on the wire and the skill needs to see it to drop its subscription marker.
- Event-source precedence inside a single iteration is **ci → review → pr_closed**, because CI moves the conversation forward fastest (a green build often unblocks the skill from re-reading a review batch). The choice is deterministic but not user-visible: in practice both sources rarely fire in the same 15-second window, and dropping the second one is safe because (a) ci-watch already wrote `ci.last_state` for the suppressed event and (b) reviews-poll's batches are still pending in the forge and surface on the next call.
- Pre-entry preflight matches `ci-watch` and `reviews-poll`: missing git repo → exit 1, forge CLI missing/unauthed → exit 3, PR not found → exit 4 with `prtend: PR <n> not found`, PR already `closed`/`merged` on entry → exit 4 with `prtend: PR <n> is <state>` (do **not** emit a `pr_closed` event — that's only for mid-watch transitions; on-entry-closed is a precondition violation symmetric to the existing two primitives).
- A child returning exit code 4 mid-loop (e.g. `ci-watch --once`'s own preflight catching a mid-watch PR-state transition between our preflight and the child's first sample) is transmuted into a `pr_closed` event by `watch` — same flow as the periodic re-check path. Other child exit codes (1 forge error, 3 CLI gone) propagate verbatim; 2 (bad flags) should be unreachable because `watch` constructs the child argv.
- No changes to `bin/prtend`, no changes to the forge lib, no changes to the state lib, no changes to the notes lib, no changes to `cli-contract.md` / `forge-mapping.md` / `overview.md`. The only new files are the subcommand and its test surface.

## Files to create or modify

- `lib/prtend/prtend-subcommands/watch.bash` (NEW)
- `test/fixtures/watch/` (NEW)
- `test/test-watch.sh` (NEW) — match `test/test-reviews-poll.sh` and `test/test-ci-watch.sh` harness style.

No changes to any other file. If you find yourself touching `prtend-forge-lib.bash`, `prtend-state-lib.bash`, `prtend-notes-lib.bash`, the `ci_watch.bash` / `reviews_poll.bash` subcommand files, `bin/prtend`, or `docs/`, you've drifted out of scope.

## Implementation

### `lib/prtend/prtend-subcommands/watch.bash`

Public surface:

```bash
prtend_cmd_watch "$@"   # parses flags, multiplexes ci-watch+reviews-poll, returns documented exit codes
```

Flag parsing (same conventions as `ci-watch`/`reviews-poll`, minus `--cursor` — `watch` always reads/writes its review cursor from state):

- `--pr N` — required; must match `^[0-9]+$`. Exit 2 otherwise.
- `--block` — default if neither `--once` nor `--timeout` is given. Idempotent if specified explicitly.
- `--once` — mutually exclusive with `--block` and `--timeout`. Exit 2 on conflict with `prtend: --once and --block are mutually exclusive` (or analogous wording for `--timeout`).
- `--timeout S` — integer seconds, `^[1-9][0-9]*$`. Implies `--block`; explicit `--block --timeout S` is allowed; `--once --timeout S` is exit 2.
- Anything else → exit 2.

Composition (in order):

1. **Source the child subcommand files.** The dispatcher loads subcommand files lazily and `watch` calls `prtend_cmd_ci_watch` / `prtend_cmd_reviews_poll` directly (as Bash functions, not subprocesses — keeps stderr handling clean and avoids re-paying preflight cost per iteration on the child side). Source `ci_watch.bash` and `reviews_poll.bash` from `${PRTEND_LIB:-...}/prtend-subcommands/` with the same lazy-load guard pattern (`PRTEND_CI_WATCH_LOADED`, `PRTEND_REVIEWS_POLL_LOADED`) the other files use for state/notes libs. Also load the state lib (`prtend-state-lib.bash`) — needed for `prtend_state_get_cursor`, `prtend_state_set_cursor`, and `prtend_state_clear`.

2. **Git repo + readiness gate.** `git rev-parse --git-dir >/dev/null` or exit 1 (`prtend: not in a git repository`). Then `prtend_forge_cli_ready`: propagate exit 1/3 verbatim. No offline path — both children require the forge.

3. **Pre-flight PR existence + state.** Call `prtend_forge_pr_state "$pr"` once. If the PR is not found, exit 4 with `prtend: PR <n> not found`. If the PR is already `closed`/`merged` on entry, exit 4 with `prtend: PR <n> is <state>` — **not** a `pr_closed` event; on-entry-closed is a precondition violation, symmetric to `ci-watch` and `reviews-poll`.

4. **Resolve initial review cursor.** `cursor="$(prtend_state_get_cursor "$pr" || true)"` (empty allowed — means "all"). `watch` owns the cursor write; the child is always invoked with `--cursor "$cursor"` so it doesn't touch state.

5. **Loop.** `start="$SECONDS"`, `first=1`. Loop body:

   a. **Deadline pre-call (after the first iteration).** If `(( first == 0 ))` and `(( saw_timeout == 1 ))` and `(( SECONDS - start >= timeout_s ))`, return 0 with no output. Same shape as the analogous check in `reviews_poll.bash:131-137`. The first iteration always runs.

   b. **CI sample.** Call `prtend_cmd_ci_watch --pr "$pr" --once` inside `set +e ... set -e` to capture both stdout and exit code:

      ```bash
      local ci_out ci_rc
      set +e
      ci_out="$(prtend_cmd_ci_watch --pr "$pr" --once)"
      ci_rc=$?
      set -e
      ```

      - `ci_rc == 0` and `-n "$ci_out"`: emit `ci_out` to stdout verbatim (it's already a single canonical JSON event), return 0. The child already wrote `state.ci.last_state` and any per-signature attempt counters; `watch` does **not** repeat that work.
      - `ci_rc == 0` and empty `ci_out`: no CI event pending; fall through to (c).
      - `ci_rc == 4`: PR closed between our preflight and the child's preflight. Jump to (e) (emit `pr_closed`) — we synthesize the event ourselves rather than scraping the child's stderr.
      - `ci_rc == 3` (CLI gone) / `1` (forge error): propagate verbatim — these are environmental, retrying the same call won't help.

   c. **Reviews sample.** Call `prtend_cmd_reviews_poll --pr "$pr" --once --cursor "$cursor"` with the same `set +e` capture:

      ```bash
      local rev_out rev_rc
      set +e
      rev_out="$(prtend_cmd_reviews_poll --pr "$pr" --once --cursor "$cursor")"
      rev_rc=$?
      set -e
      ```

      - `rev_rc == 0` and `-n "$rev_out"`: extract the **first** JSON object from `rev_out` (newline-separated when multiple batches are present). Emit it to stdout verbatim. Extract its `.next_cursor` via `jq -r '.next_cursor'`, write it back: `prtend_state_set_cursor "$pr" "$next_cursor"`. Return 0. The remaining batches in `rev_out` are dropped — they're still pending in the forge and the next `watch` call (now resumed from `next_cursor`) picks them up. **Important:** because the child was called with `--cursor`, it did **not** write state itself — `watch` owns that write.
      - `rev_rc == 0` and empty `rev_out`: no review batch pending; fall through to (d).
      - `rev_rc == 4`: same as CI's 4 — jump to (e).
      - `rev_rc == 3` / `1`: propagate.

   d. **PR-state re-check.** Call `prtend_forge_pr_state "$pr"` once (rc captured). If the call succeeded and the state is `closed`/`merged`, fall through to (e). Otherwise — including when the rc was non-zero (transient forge error) — leave the loop body and continue to (f). Do **not** convert a transient `pr_state` error into a `pr_closed` event; the loop will re-check next iteration.

   e. **Emit `pr_closed`.** Build the event from the most recently captured `pr_state_json`:

      ```bash
      jq -cn \
        --argjson pr "$pr" \
        --arg final_state "$pr_state" \
        --arg closed_at "$(printf '%s' "$pr_state_json" | jq -r '.closed_at // ""')" \
        '{type:"pr_closed", pr:$pr, final_state:$final_state, closed_at:$closed_at}'
      ```

      Emit it on stdout. Then call `prtend_state_clear "$pr"`. On clear failure, `prtend_log_warn "watch: failed to clear state for PR $pr"` but still return 0 — the event is on the wire. **Do not** emit anything else after `pr_closed`. Return 0.

   f. **`--once` mode returns now.** If `mode == "once"`, return 0 with no output (nothing was pending on any of the three sources this single iteration).

   g. **`--block` mode: sleep, then loop.** Pre-sleep deadline short-circuit: if `(( saw_timeout == 1 )) && (( SECONDS - start >= timeout_s ))`, return 0. Otherwise compute `nap="${PRTEND_POLL_INTERVAL:-15}"`, cap it to the remaining budget when `--timeout` is set (`remaining = timeout_s - (SECONDS - start); if remaining < nap then nap = remaining; if nap < 0 then nap = 0`), `sleep "$nap"`, set `first=0`, continue.

### Multi-batch reviews-poll output: first vs rest

`prtend_cmd_reviews_poll --once` emits one JSON object per line, one line per pending batch. To pick the first one robustly:

```bash
first_event="$(printf '%s' "$rev_out" | head -n 1)"
```

`head -n 1` is the right primitive — `jq -s '.[0]'` would also work but adds a needless slurp. The remaining lines are intentionally dropped; the cursor write below ensures they re-surface on the next call.

### Synthesized `pr_closed` payload

`prtend_forge_pr_state` already returns a canonical object with at least `.state` and `.closed_at` fields per `../forge-mapping.md` § "PR state". The `pr_closed` event keys map straight from that:

- `pr` → from `$pr` (numeric).
- `final_state` → `.state` from the pr_state probe.
- `closed_at` → `.closed_at` from the pr_state probe; empty string if the forge omits the field for a still-being-closed PR (rare; the contract allows it).

Do **not** add fields the contract doesn't list (no `pushed_at`, no commit sha, no author). The skill switches on `type` and unsubscribes; nothing else looks at the payload.

### Key decisions

- **Children are called as Bash functions, not subprocesses.** This keeps stderr handling identical to the rest of the dispatcher (a child's `prtend_log_error` line goes straight to the user's terminal) and avoids paying `bin/prtend` re-source overhead on every 15-second tick. The downside is that the child's `set -uo pipefail` runtime state leaks into the parent — mitigated by the `set +e ... set -e` capture wrapper which restores `errexit` after each call.
- **Children are invoked in `--once`, never `--block`.** A `--block` child would block the watch's own wall clock. `--once` gives `watch` the per-iteration "is there something pending?" probe it needs while preserving the children's already-tested cursor / counter / preflight logic.
- **Watch owns the review cursor write; children do not.** Achieved by passing `--cursor "$cursor"` to every `reviews-poll` call. The child's `--cursor` mode contract is "read this, don't write state" — exactly what's needed so `watch` can advance the cursor past *only the forwarded batch* when the child emitted multiple.
- **CI's per-iteration state write stays with the child.** `ci-watch --once` always writes `state.ci.last_state` and increments per-signature counters when it emits — `watch` does **not** re-do that work for the forwarded CI event. It also means dropping a CI event in favor of a same-iteration review event is *not* free (the cursor advances even though the parent didn't forward it) — but per the "precedence" decision above, CI is always preferred when both fire, so this case can't arise.
- **`pr_closed` is synthesized by `watch`, never propagated from a child.** A child's exit-4 path emits to *stderr* and exits, not to stdout. `watch` always builds the `pr_closed` event itself from the most recent `pr_state_json`, even when a child triggered the realization that the PR closed.
- **`prtend_state_clear` runs after stdout, not before.** If the clear fails (permissions, disk full) we still want the skill to receive the `pr_closed` event so it drops its subscription marker. The clear failure is logged as a warning; the next `prtend doctor` run can surface persistent state-file leaks.
- **No new `bin/prtend` plumbing.** `watch` is already in the dispatcher's case statement from step 02. The lazy-source pattern works without any changes there.
- **Do NOT add a `--poll-interval` flag.** Tuning lives in `$PRTEND_POLL_INTERVAL` (already documented in `../cli-contract.md` § "Environment"), and the child commands already honor it. A flag would just duplicate the knob.

## Verification

Tests use a fake forge (functions overriding `prtend_forge_pr_state` / `prtend_forge_ci_status` / `prtend_forge_ci_failures` / `prtend_forge_reviews_since` / `prtend_forge_review_comments` / `prtend_forge_review_thread_notes` / `prtend_forge_cli_ready`) the same way `test/test-ci-watch.sh` and `test/test-reviews-poll.sh` do. No real `gh`/`glab` calls. Each test asserts on captured stdout, captured stderr, exit code, and on-disk state-file contents.

```bash
shellcheck lib/prtend/prtend-subcommands/watch.bash test/test-watch.sh
# → no output, exit 0

bin/prtend watch
# → "prtend: watch: --pr is required" on stderr, exit 2

bin/prtend watch --pr abc
# → "prtend: watch: --pr must be a positive integer" on stderr, exit 2

bin/prtend watch --pr 1 --once --block
# → "prtend: watch: --once and --block are mutually exclusive" on stderr, exit 2

bin/prtend watch --pr 1 --once --timeout 30
# → "prtend: watch: --once and --timeout are mutually exclusive" on stderr, exit 2

bin/prtend watch --pr 1 --timeout 0
# → "prtend: watch: --timeout must be a positive integer" on stderr, exit 2

test/test-watch.sh
# → all cases pass; exit 0
```

`test/test-watch.sh` cases (at minimum):

1. **No git repo** → exit 1, stderr `prtend: not in a git repository`.
2. **Forge unauthed** (fake `prtend_forge_cli_ready` returns 3) → exit 3.
3. **PR not found** (fake `prtend_forge_pr_state` returns 1) → exit 4, stderr `prtend: PR 123 not found`, no stdout.
4. **PR already closed on entry** → exit 4, stderr `prtend: PR 123 is closed`, no stdout, no `pr_closed` event.
5. **`--once`, nothing pending** (fake CI returns `state==previous_state`, fake reviews returns `{batches:[],next_cursor:""}`, fake pr_state stays `open`) → exit 0, no stdout, state file unchanged.
6. **`--once`, CI has a pending event** → exit 0, stdout is exactly the canonical `{type:"ci",...}` event from the fake `ci-watch --once`, state file has `ci.last_state` updated (the child did that), review cursor unchanged.
7. **`--once`, reviews has one batch** → exit 0, stdout is the canonical `{type:"review_batch",...}` event, state file's `last_review_cursor` advanced to that batch's `next_cursor`.
8. **`--once`, reviews has *three* batches** → exit 0, stdout is only the **first** batch (one JSON line on stdout), state cursor advanced to that first batch's `next_cursor` (NOT the across-call cursor). Re-running `watch --once` then yields the second batch with the cursor advanced accordingly.
9. **`--once`, both CI and reviews have events** → exit 0, stdout is the **CI** event (precedence). The review cursor stays at its prior value. State file's `ci.last_state` is updated by the ci-watch child. Re-running `watch --once` then yields the review batch.
10. **`--once`, both silent, but pr_state shows `closed`** → exit 0, stdout is `{"type":"pr_closed","pr":123,"final_state":"closed","closed_at":"..."}` (one line), state file is **removed** (`prtend_state_clear` succeeded). No stderr.
11. **`--once`, ci-watch child returns exit 4 mid-call** (fake `prtend_forge_pr_state` flips to `closed` after our preflight) → exit 0, stdout is `pr_closed`, state file removed.
12. **`--block --timeout 2`, nothing ever happens** (fakes never change) → exit 0, no stdout, no state changes, returns near 2s (allow ±1s slack). Set `PRTEND_POLL_INTERVAL=1` for the test so the loop spins faster.
13. **`--block --timeout 5`, review batch appears on iteration 2** (fake's `reviews_since` returns empty first call, one batch second call) → exit 0, stdout is the review event, state cursor advanced. Set `PRTEND_POLL_INTERVAL=1`.
14. **`--block`, PR closes after iteration 2** (fake pr_state flips on third call) → exit 0, stdout is `pr_closed`, state file removed.
15. **`--once`, `prtend_state_clear` fails** (test forces a read-only state dir) → exit 0, stdout still has the `pr_closed` event, stderr contains `watch: failed to clear state for PR <n>`. **Hardest test case** — verifies the contract that the event reaches the skill even when cleanup fails.

The fake-forge harness should set `PRTEND_STATE_DIR` to a per-test tmp dir (so cases 6–14 can assert on the file contents) and override the forge entry points by sourcing replacements *after* sourcing the real `prtend-forge-lib.bash`. Reuse the pattern from `test/test-reviews-poll.sh:30-80`.

## Done

- [ ] `lib/prtend/prtend-subcommands/watch.bash` exists, executable bit not set (it's a sourced file), `shellcheck` clean.
- [ ] All flag-parsing rejections behave as specified (cases 1–5 of the manual `bin/prtend watch …` verification block above).
- [ ] `test/test-watch.sh` exists, sources the harness pattern, exercises all 15 numbered cases above, and exits 0.
- [ ] `prtend_forge_pr_state` / `prtend_state_clear` / `prtend_cmd_ci_watch` / `prtend_cmd_reviews_poll` are called as their existing signatures (no shimming, no flag additions).
- [ ] No diff to `bin/prtend`, `prtend-lib.bash`, `prtend-forge-lib.bash`, `prtend-state-lib.bash`, `prtend-notes-lib.bash`, `prtend-signature-lib.bash`, `ci_watch.bash`, `reviews_poll.bash`, `config.bash`, `defer_write.bash`, `detect.bash`, `note_post.bash`, `pr_open.bash`, or any file under `docs/`.
- [ ] `git status` shows only: `lib/prtend/prtend-subcommands/watch.bash`, `test/fixtures/watch/...`, `test/test-watch.sh`.
- [ ] One commit on the `step-16-watch` branch: `feat(watch): add watch multiplexer subcommand`.
