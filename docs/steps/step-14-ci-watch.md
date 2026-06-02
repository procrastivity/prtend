# Step 14 — `prtend ci-watch` subcommand

## Context

Land the first of the three watch primitives. `prtend ci-watch` is what the skill calls inside the CI half of a watch session: it samples the PR's checks, emits exactly one JSON event when the aggregate state changes (or — with `--once` — any pending events without blocking), and exits. With this in place the skill can finally close the CI-loop branch of `../overview.md` § "Watch session"; today the skill can post PRs (step 08), defer comments (step 11), and post notes (step 10), but it has no way to see when CI flips from `running` to `failure` and back, so the loop's `1. Inspect the failure …` step has nothing to inspect.

This step composes the read-only forge surface from step 04 (`prtend_forge_ci_status` already returns the aggregate-state + per-check shape we want) and the per-PR state helpers from step 05 (`prtend_state_increment_ci_attempt` / `prtend_state_ci_attempts`). It introduces two new forge entry points — `prtend_forge_ci_failures` for the detailed log excerpt per failed check, and `prtend_forge_ci_watch_block` for the GH `--watch` / GL poll-loop primitive — and a small new lib, `prtend-signature-lib.bash`, that turns a log excerpt into the canonical `<tool>:<scope>:<short-rule>` signature.

See `../cli-contract.md` § "`prtend ci-watch`" for the output contract and exit-code table, `../forge-mapping.md` §§ "CI status snapshot" / "CI failures (detail)" / "CI watch (blocking)" for the per-forge command shapes, and `../overview.md` § "Watch session" → "CI loop" for the workflow this primitive feeds (signature-keyed retry counting on top, escalation to Ask on 3rd repeat).

## Prerequisites

- Step 02 (`dispatcher`) complete — `bin/prtend` already routes `ci-watch` to `lib/prtend/prtend-subcommands/ci_watch.bash` and calls `prtend_cmd_ci_watch`; `prtend_log_*`, `prtend_atomic_write`, `prtend_repo_slug`, `prtend_json_get`, and the `--verbose` plumbing are available.
- Step 03 (`forge-detect`) complete — `prtend_forge_cli_ready` and `prtend_forge_dispatch` are the readiness/dispatch gates this step relies on.
- Step 04 (`forge-read`) complete — `prtend_forge_ci_status` exists and returns the canonical `{state, checks[]}` shape (`../forge-mapping.md` § "CI status snapshot"). `ci-watch` reads it on entry to know the *current* aggregate state and uses it as the `--once` answer; the new `ci_failures` private feeds off the same check listing.
- Step 05 (`state`) complete — `prtend_state_path`, `prtend_state_read`, `prtend_state_write`, `prtend_state_increment_ci_attempt`, and `prtend_state_ci_attempts` are available. `ci-watch` does not itself escalate on attempt counts (that's the skill's job per `../overview.md` § "CI loop") but it **does** increment the per-signature counter for each emitted failure event so the skill can read the count on its next iteration.
- Step 08 (`pr-open`) complete — establishes the "subcommand + adjacent forge addition" bundling pattern and the `prtend_forge_pr_state` we reuse to detect PR-closed-mid-watch.

Required on the host for smoke tests: the forge CLI matching the checkout (`gh` or `glab`), authenticated, an open PR/MR with CI configured and a recent CI run (preferably one with both a passing and a failing check across history, so the state-transition path can be exercised). `coreutils`-`timeout` (already in the devShell) for `--timeout S`.

## Goal

After this step:

- `bin/prtend ci-watch --pr N --block` samples CI on entry, then blocks until the aggregate state changes from that entry state. Exactly one JSON event is emitted on stdout when the change happens, matching `../cli-contract.md` § "`prtend ci-watch`" → "Output" (the `state` / `checks[]` / `failures[]` / `previous_state` object). Exits 0.
- `bin/prtend ci-watch --pr N --once` emits **zero or more** JSON events covering anything pending: nothing if the live aggregate state equals the recorded `state.ci.last_state` in the state file, or one event if it differs. Exits 0 either way. Does not block.
- `bin/prtend ci-watch --pr N --block --timeout S` is `--block` wrapped in a wall-clock bound: on timeout it exits 0 with **no output**. The contract specifies "clean timeout" as exit 0; do not exit 124 or surface `timeout`'s native code.
- `failures[]` is present and non-empty only when the emitted event's `state == "failure"`. Each entry carries `check_name`, `conclusion`, `log_url`, a `log_excerpt` ≤ 50 lines, and a prtend-computed `signature`. Signature shape: `<tool>:<scope>:<short-rule>` — see `../forge-mapping.md` § "CI failures (detail)".
- `previous_state` is the aggregate state observed on entry (the first sample), so it is `null` only when there was no prior state (first event after subscription, no state file, no prior `state.ci.last_state`). On the second `--block` call in the same session the prior call's emitted state is `previous_state`.
- PR-closed-mid-watch is observable. If the PR transitions to `closed`/`merged` during the blocking wait, `ci-watch` exits 4 with stderr `prtend: PR <n> closed during watch` and no stdout. (The richer `{type: "pr_closed", …}` event lives in `prtend watch`, the multiplexer — `ci-watch` only needs to surface the precondition violation.)
- For every emitted failure event, `prtend_state_increment_ci_attempt "$pr" "$signature"` runs once per distinct signature in `failures[]`. The state file's `ci.attempts.<signature>` counter is the contract the skill reads next iteration to decide "3 strikes → escalate."
- `prtend-forge-lib.bash` gains:
  - `prtend_forge_ci_failures <pr>` — echoes the canonical `{failures: [...]}` JSON (`../forge-mapping.md` § "CI failures (detail)") on stdout. Includes `signature` per failure (computed via the new signature lib, not the forge). Exit 0 on success even when `failures` is empty (e.g. CI is `success` or `running`); exit 1 on forge error; exit 3 propagated from `prtend_forge_cli_ready`.
  - `prtend_forge_ci_watch_block <pr> <last_state>` — blocks until the aggregate state observed by `prtend_forge_ci_status` differs from `<last_state>` (or the PR closes). Echoes the **new** canonical CI status JSON on stdout and exits 0; exits 4 if the PR closes during the wait. Honors `$PRTEND_POLL_INTERVAL` (default 15s).
- `lib/prtend/prtend-signature-lib.bash` (NEW, small) exposes `prtend_signature_from_log <check_name> <log_excerpt_path>` echoing `<tool>:<scope>:<short-rule>`. Heuristic set is bounded to a handful of well-known tools (jest/vitest, eslint, tsc, mypy, pytest, go test, cargo test, shellcheck); unknown patterns fall back to `unknown:<check_name>:<sha1-of-first-failing-line>` so the counter is at least stable.

## Files to create or modify

- `lib/prtend/prtend-subcommands/ci_watch.bash` (NEW)
- `lib/prtend/prtend-forge-lib.bash` (MODIFY) — add `prtend_forge_ci_failures`, `prtend_forge_ci_watch_block`, plus the four privates (`_prtend_forge_<gh|gl>_ci_failures`, `_prtend_forge_<gh|gl>_ci_watch_block`)
- `lib/prtend/prtend-signature-lib.bash` (NEW)
- `lib/prtend/prtend-state-lib.bash` (MODIFY, minor) — add `prtend_state_set_ci_last_state <pr> <state>` and `prtend_state_get_ci_last_state <pr>`. These are the state-file fields `ci-watch` reads/writes for the `previous_state` field and for `--once`'s "is there a pending event?" comparison.
- `test/fixtures/ci_watch/` (NEW)
- `test/test-ci-watch.sh` (NEW) — match `test/test-defer-write.sh` harness style.

No changes to `bin/prtend`, `prtend-lib.bash`, `prtend-notes-lib.bash`, the `config` subcommand family, or `docs/`. If you find yourself touching them, you've drifted out of scope.

## Implementation

### `lib/prtend/prtend-subcommands/ci_watch.bash`

Public surface:

```bash
prtend_cmd_ci_watch "$@"   # parses flags, samples / blocks / emits, returns documented exit codes
```

Flag parsing (same conventions as `pr-open`/`note-post`/`defer-write`):

- `--pr N` — required; must match `^[0-9]+$`. Exit 2 otherwise.
- `--block` — default if neither `--once` nor `--timeout` is given. Idempotent if specified explicitly.
- `--once` — mutually exclusive with `--block` and `--timeout`. Exit 2 on conflict with `prtend: --once and --block are mutually exclusive` (or analogous wording for `--timeout`).
- `--timeout S` — integer seconds, `^[1-9][0-9]*$` (reject 0 and dash-leading values). Implies `--block`; explicit `--block --timeout S` is allowed; `--once --timeout S` is exit 2.
- Anything else → exit 2.

Composition (in order):

1. **Git repo + readiness gate.** `git rev-parse --git-dir >/dev/null` or exit 1 (`prtend: not in a git repository`). Then `prtend_forge_cli_ready`: propagate exit 1/3 verbatim. There is no offline path — CI state lives on the forge.

2. **Pre-flight PR existence + state.** Call `prtend_forge_pr_state "$pr"` once. If the PR is not found, exit 4 with `prtend: PR <n> not found`. If the PR is already `closed`/`merged` on entry, exit 4 with `prtend: PR <n> is <state>` — do not begin a watch that has nothing to watch.

3. **Resolve `previous_state`.** Read the state file via `prtend_state_get_ci_last_state "$pr"`. If empty (no state file yet, or no `ci.last_state` key), `previous_state="null"`; else `previous_state="$cached"` (a JSON string in quotes when emitted).

4. **Sample.** Call `prtend_forge_ci_status "$pr"` and capture stdout as `status_json`. Extract `state` via `prtend_json_get '.state'`.

5. **Branch on mode:**

   - **`--once`:** If `previous_state` is `null` OR `state != previous_state`, emit one event (jump to step 7 with this status). Otherwise emit nothing and exit 0. Do not touch state in the no-emit path; the cursor is moved only when the skill acknowledges via the emitted event.
   - **`--block` (with or without `--timeout`):**
     - If `state != previous_state` on entry, emit immediately (the "first event after subscription" case) and exit 0 — do not block waiting for a *second* change.
     - Otherwise call `prtend_forge_ci_watch_block "$pr" "$state"`. With `--timeout S`, wrap the call in `timeout --preserve-status "$timeout_seconds"`; on timeout (exit 124) exit 0 with no stdout. Without `--timeout`, the block is unbounded — the caller controls cancellation.
     - On block success, capture the new `status_json` from the watch primitive's stdout and the new `state` from `.state`.
     - On block exit 4 (PR closed), exit 4 with the documented stderr and no stdout.

6. **Materialize `failures[]`.** Only when `state == "failure"`: call `prtend_forge_ci_failures "$pr"` and capture its `failures` array. Project it to the subcommand's output shape (`check_name`, `conclusion`, `log_url`, `log_excerpt`, `signature`). When `state != "failure"`, `failures` is omitted from the emitted JSON entirely (the contract treats absence and `[]` as the same signal but absence keeps the line shorter and matches the contract's example).

7. **Emit the event.** One compact JSON object on stdout via `jq -c -n --argjson status "$status_json" --argjson failures "$failures_json" --arg prev "$previous_state_for_jq"` matching the contract's example: `{type, pr, state, checks, failures?, previous_state}`. Order: `type`, `pr`, `state`, `checks`, `failures`, `previous_state`. `previous_state` is emitted as a JSON string or `null` — when `previous_state` is `null`, pass `null` as a `--argjson` value, not the string `"null"`.

8. **Persist cursor + retry counters.** After emission:
   - `prtend_state_set_ci_last_state "$pr" "$state"` — moves the cursor.
   - For each distinct `signature` in `failures[]`: `prtend_state_increment_ci_attempt "$pr" "$signature"`. Distinct so a single emission of three failed checks with the same signature counts once.
   - On `--once` with no emission, neither call runs.

9. **Exit 0.**

### `lib/prtend/prtend-forge-lib.bash` additions

Three new public surfaces, same one-liner dispatch pattern as the existing forge ops:

```bash
prtend_forge_ci_failures()      { prtend_forge_dispatch ci_failures "$@"; }
prtend_forge_ci_watch_block()   { prtend_forge_dispatch ci_watch_block "$@"; }
```

`prtend_forge_ci_failures <pr>` — echoes canonical `{failures: [...]}` JSON. Each entry has `check_name`, `conclusion`, `log_url`, `log_excerpt`, `signature`. Empty `failures` array when CI is success/running. Exit 0 on success, exit 1 on forge error.

- `_prtend_forge_gh_ci_failures <pr>`:
  - Resolve `slug="$(_prtend_forge_gh_repo_slug)"`.
  - List checks via `gh pr checks "$pr" --json name,state,conclusion,workflow,link`.
  - Filter to entries where `conclusion == "failure"`. For each, extract the run id from `link` (URL form `…/actions/runs/<run-id>/job/<job-id>`; if `link` is empty, fall back to `gh run list --workflow "$workflow" --json databaseId,headSha --limit 5 | jq` to find the run whose `headSha` matches the PR head — but only as a fallback; the URL parse is the hot path).
  - Fetch the failing log via `gh run view <run-id> --log-failed`. Tail to the last 50 lines via `tail -n 50`. Write to a temp file.
  - Compute the signature: `prtend_signature_from_log "$check_name" "$tmp_log_path"`. (The signature lib reads the file rather than taking the excerpt on argv to avoid argv length limits on large excerpts and to make testing easier.)
  - Emit one JSON object per failure into a jq slurp; final shape: `{"failures":[...]}`.

- `_prtend_forge_gl_ci_failures <pr>`:
  - Resolve `project_id="$(_prtend_forge_gl_project_id)"`.
  - Resolve `pipeline_id="$(glab mr view "$pr" --output json | jq -r '.head_pipeline.id // empty')"`. If empty, exit 1.
  - List jobs via `glab api "projects/${project_id}/pipelines/${pipeline_id}/jobs"`. Filter to `status == "failed"`.
  - For each failed job, fetch the trace via `glab ci trace <job-id>` (or `glab api "projects/${project_id}/jobs/<job-id>/trace"` if `glab ci trace` proves interactive in non-tty contexts — pick whichever returns plain text to stdout in the devShell; document the choice).
  - Tail to last 50 lines; signature via the same `prtend_signature_from_log` call (the lib is forge-agnostic).
  - Emit the same canonical shape.

`prtend_forge_ci_watch_block <pr> <last_state>` — blocks until the aggregate state observed by `prtend_forge_ci_status` differs from `<last_state>`. Echoes the new `prtend_forge_ci_status` JSON on stdout. Exit 0 on state change; exit 4 if the PR closes during the wait.

- `_prtend_forge_gh_ci_watch_block <pr> <last_state>`:
  - Option A (preferred): use `gh pr checks <pr> --watch --interval "$PRTEND_POLL_INTERVAL"` to block on rolling output, but only as the heartbeat — re-poll `prtend_forge_ci_status` on each non-empty output line and compare its aggregate `state` against `<last_state>`. When they differ, kill the `--watch` child and echo the fresh status JSON.
  - Option B (fallback if `--watch` proves too noisy to wrap cleanly): plain poll loop calling `prtend_forge_ci_status` every `$PRTEND_POLL_INTERVAL` seconds. The loop body is identical in shape to the GitLab path, which keeps the two implementations symmetric and easier to test. Pick option B if it isn't significantly slower; A is the doc's stated mapping but B is simpler.
  - Either way: every iteration also checks `prtend_forge_pr_state "$pr"`; on `closed`/`merged`, exit 4.

- `_prtend_forge_gl_ci_watch_block <pr> <last_state>`:
  - Loop: `prtend_forge_ci_status "$pr"`; if `.state != <last_state>`, echo and exit 0. Else `prtend_forge_pr_state` for the close check, then `sleep "${PRTEND_POLL_INTERVAL:-15}"`. Repeat.

A code comment near both pairs should point at `../docs/forge-mapping.md` §§ "CI watch (blocking)" / "CI failures (detail)".

### `lib/prtend/prtend-signature-lib.bash`

Pure string work; no I/O beyond reading the excerpt file. Public:

```bash
prtend_signature_from_log <check_name> <log_excerpt_path>
```

Echoes `<tool>:<scope>:<short-rule>` on stdout. Exit 0 always (signature derivation cannot meaningfully fail — the fallback is always reachable).

Heuristic order (first match wins):

| Tool tag | Match (line-anchored regex on excerpt) | Scope / rule |
|---|---|---|
| `jest` | `FAIL ([^\s]+)\s*\n\s*●\s*([^\n]+?)\s*\n\s*Expected: ([^\n]+)\s*Received: ([^\n]+)` | scope = basename of file (group 1); rule = `<expected>-<received>` (groups 3–4) |
| `vitest` | analogous to jest but `FAIL` line prefix differs | same projection as jest |
| `eslint` | `^([^\s:]+):(\d+):\d+\s+error\s+(.+?)\s+([a-z0-9-]+/[a-z0-9-]+)$` | scope = basename(file); rule = the rule id |
| `tsc` | `^([^\s(]+)\(\d+,\d+\): error (TS\d+):` | scope = basename(file); rule = the `TS\d+` code |
| `mypy` | `^([^\s:]+):\d+: error: .+ \[([a-z-]+)\]$` | scope = basename(file); rule = the bracketed code |
| `pytest` | `^FAILED ([^\s:]+)::([^\s]+)` | scope = the test node id's basename; rule = the test function name |
| `go test` | `^--- FAIL: ([^\s]+) ` then `\s+([^\s:]+):\d+:` | scope = file basename; rule = test func name |
| `cargo test` | `^test ([^\s]+) ... FAILED$` then a panic line | scope = module path tail; rule = panic short message |
| `shellcheck` | `^In ([^\s]+) line \d+:` then `SC\d+` | scope = file basename; rule = `SC` code |

Fallback: `unknown:<check_name>:<sha1-of-first-non-blank-line-of-excerpt | cut -c1-12>`. The 12-char prefix is enough to be stable across runs while not being absurdly long for human reading; if a test ever wants to assert it, it can stub the input.

`<check_name>` is included in the fallback specifically so two unrelated `unknown:` failures don't collide and trip the 3-strike retry cap incorrectly. For the well-known tools above the tool tag itself is distinctive enough — the file basename is sufficient scope.

### `lib/prtend/prtend-state-lib.bash` additions

Two thin accessors over the existing state JSON document:

- `prtend_state_set_ci_last_state <pr> <state_string>` — read state, jq-set `.ci.last_state = $state`, `prtend_atomic_write` back. Creates `.ci` if missing.
- `prtend_state_get_ci_last_state <pr>` — read state, echo `.ci.last_state // empty`. Empty stdout when not set.

These complement `prtend_state_increment_ci_attempt` / `prtend_state_ci_attempts` already shipped in step 05. The state-file shape under `ci.` therefore becomes `{last_state, attempts: {<signature>: <int>, …}}`. Nothing else owns `.ci` so no merge logic is needed beyond the standard read/jq-set/write.

### Key decisions

- **`previous_state` is "the state we sampled on entry", not "the state recorded in the state file before this call".** They usually agree; they differ on the first call ever (no state file, `previous_state=null`) and after a session boundary. Sampling on entry is the source of truth — the state file is the cursor for the *next* call.
- **`--once` does not write the cursor when it emits nothing.** The skill polls; missing the cursor write on no-op calls means a subsequent `--block` correctly treats the prior recorded state as `previous_state`. Writing the cursor unconditionally would silently advance it past unobserved transitions during the gap between two `--once` calls.
- **`--once` *does* write the cursor when it emits.** Same contract as `--block`: the emitted event is the acknowledgment that the skill saw the transition.
- **No clamping of `previous_state` to the contract's enum.** If a forge ever returns a state string we don't know, it round-trips through `previous_state` verbatim rather than being normalized to `null`. The contract enumeration is descriptive, not prescriptive — defending the field against unknown values would hide real upstream changes.
- **Signature library is its own file.** It's small today, but the heuristic table will grow; isolating it keeps `prtend-state-lib.bash` from accreting unrelated concerns, and it sources cleanly into the forge-lib privates without dragging state-file machinery along. The forge-mapping doc anticipates this exact split ("Heuristics for signature extraction are in `prtend-state-lib.bash` (or a dedicated `prtend-signature-lib.bash` if it grows)").
- **The retry counter increments here, not in the skill.** The skill-side contract is to *read* `state.ci.attempts.<signature>` after each emission and compare against 3. Incrementing on the CLI side means the skill cannot accidentally double-count by re-reading an event; it also means a skill restart picks up the right counter on next emission. The CLI never enforces the 3-strike cap itself — that decision is `../overview.md` § "CI loop" step 4, which lives in `comment-decision-rubric.md` / `ci-fixable-rubric.md`.
- **`timeout --preserve-status` is the wrap, not `timeout` plain.** Plain `timeout` exits 124 on timeout; we want exit 0 with no stdout per the contract. Preserve-status with a `||` clause discriminating 124 → 0 is cleaner than re-mapping every exit code.
- **PR-closed-during-watch is exit 4, not exit 0 with a synthetic event.** That synthetic event is `prtend watch`'s job (step 15, multiplexer). `ci-watch` is single-purpose; exit 4 with a clear stderr is the unambiguous "your assumption no longer holds" signal. The multiplexer can translate it.
- **No `--interval` flag.** `$PRTEND_POLL_INTERVAL` (default 15s) is the one tunable. Adding a CLI flag invites per-call divergence between `ci-watch` and `reviews-poll` (step 15) and complicates the multiplexer. Env-var only matches the env-driven cadence the forge-mapping doc already specifies.
- **`gh pr checks --watch` is allowed but optional.** Option B (plain poll loop) in both forges keeps the two implementations symmetric and easier to test; Option A is closer to the forge-mapping doc's stated mapping. Either is acceptable; pick one and stay consistent. Do not start with A and fall back to B at runtime — that's two code paths to maintain.
- **No `failures[]` recomputation between sample and emit.** `prtend_forge_ci_failures` is called exactly once per emitted event. The aggregate `state` comes from `prtend_forge_ci_status`; the failure detail comes from `prtend_forge_ci_failures`; the two are not stitched together with a cross-call freshness check. If the forge state changes between the two calls, the event is "a snapshot consistent with the second call's aggregate" and that's good enough — the next event will reconcile.
- **Signature lib does not know about state.** It takes a check name and an excerpt path; it returns a string. The state-side concern of "have we seen this signature N times" stays in `prtend-state-lib.bash`. Keeping the lib pure means the test for the signature lib is a one-liner per heuristic.

### Test shape

Match `test/test-defer-write.sh` exactly. Mock `prtend_forge_dispatch` by shadowing the `_prtend_forge_<gh|gl>_*` privates; do not exercise real network and do not spawn real `sleep` loops — the watch primitive's loop body should be parametrized on `$PRTEND_POLL_INTERVAL` and the test sets it to `0`.

Fixtures under `test/fixtures/ci_watch/`:

- `ci_status.success.json` — canonical `{state:"success", checks:[...]}` with two passing checks.
- `ci_status.failure.json` — `{state:"failure", checks:[...]}` with one passing and one failing check.
- `ci_status.running.json` — `{state:"running", checks:[...]}` with one running check.
- `ci_failures.jest.json` — `{failures:[{check_name, conclusion, log_url, log_excerpt, signature:"jest:widget-spec:42-NaN"}]}`.
- `log.jest.txt` — the matching multi-line excerpt the signature lib parses to produce the above signature.
- `log.eslint.txt`, `log.tsc.txt`, `log.mypy.txt`, `log.pytest.txt`, `log.go.txt`, `log.cargo.txt`, `log.shellcheck.txt`, `log.unknown.txt` — one per signature-lib heuristic plus the fallback, with the expected signature recorded in a sibling `*.expected.sig` file.
- `pr_state.open.json`, `pr_state.closed.json` — for the PR-closed-mid-watch path.

Test cases (one assertion block each):

1. `--once` with no prior state, sampled state is `success` → emits one event, `previous_state` is `null`, cursor written to `success`.
2. `--once` with prior state `success`, sampled state is `success` → no output, no cursor write, no counter increment, exit 0.
3. `--once` with prior state `running`, sampled state is `failure` → emits one event with `failures` populated and one counter increment for the failure's signature.
4. `--block` with prior state matching sampled state → enters watch loop; on the *next* polling iteration the mocked status flips to `failure`; emits one event and exits 0.
5. `--block --timeout 1` with prior state matching sampled and no flip → exits 0 with no output. Verify no cursor write, no counter increment.
6. `--once` against a PR that returns `pr_state == closed` on entry → exit 4 with the documented stderr; no output.
7. `--block` where the PR closes mid-loop (mock flips `pr_state` to `merged` between samples) → exit 4 with the documented stderr; no output.
8. `--pr foo` (non-numeric) → exit 2.
9. `--once --block` → exit 2 with the mutual-exclusion error.
10. Signature lib unit tests: feed each fixture log to `prtend_signature_from_log` and compare against the `*.expected.sig` value.

## Verification

```bash
# Lint & shape
shellcheck bin/prtend lib/prtend/prtend-lib.bash lib/prtend/prtend-forge-lib.bash \
           lib/prtend/prtend-state-lib.bash lib/prtend/prtend-notes-lib.bash \
           lib/prtend/prtend-signature-lib.bash \
           lib/prtend/prtend-subcommands/*.bash
# → no output, exit 0

# Help advertises ci-watch
bin/prtend --help | grep -q '\bci-watch\b'
# → exit 0

# Flag-level errors
bin/prtend ci-watch                      # missing --pr
# → exit 2; stderr mentions --pr

bin/prtend ci-watch --pr foo             # non-numeric pr
# → exit 2

bin/prtend ci-watch --pr 1 --once --block
# → exit 2; stderr mentions mutually exclusive

bin/prtend ci-watch --pr 1 --once --timeout 5
# → exit 2

# Subcommand-level test harness
bash test/test-ci-watch.sh
# → "OK" on stdout, exit 0

# Manual smoke (against a real PR with CI configured; substitute your own number):
bin/prtend ci-watch --pr 7 --once
# → 0 or 1 lines of JSON; exit 0; if a line is emitted, parses as a single CI event with
#   .type == "ci", .pr == 7, .state matches reality, .checks non-empty.

bin/prtend ci-watch --pr 7 --block --timeout 5
# → exit 0; usually no output (state stable inside 5s); if CI is actively running through a
#   transition, one event is emitted.

# State file inspection after a manual failure-emitting run:
jq '.ci' "$(bin/prtend config path 2>/dev/null | head -n1 | xargs dirname)/state/7.json" 2>/dev/null \
  || jq '.ci' "$XDG_STATE_HOME/prtend/$(git remote get-url origin | sed 's|.*[/:]||; s|\.git$||')/7.json"
# → shows {"last_state":"failure","attempts":{"<signature>":1}} (or analogous)

# Pre-commit
pre-commit run --all-files
# → all hooks pass
```

## Done

- [ ] `lib/prtend/prtend-subcommands/ci_watch.bash` exists; `prtend_cmd_ci_watch` handles `--pr`, `--block`, `--once`, `--timeout` with documented exit codes
- [ ] `prtend_forge_ci_failures` and `prtend_forge_ci_watch_block` added to `prtend-forge-lib.bash` with both `_gh_` and `_gl_` privates
- [ ] `lib/prtend/prtend-signature-lib.bash` exists; covers the nine heuristics in the table plus the `unknown:` fallback
- [ ] `prtend_state_set_ci_last_state` / `prtend_state_get_ci_last_state` added to `prtend-state-lib.bash`
- [ ] `failures[]` only present when `state == "failure"`; each entry has `check_name`, `conclusion`, `log_url`, `log_excerpt`, `signature`
- [ ] Per-signature counter increments exactly once per distinct signature per emitted event
- [ ] PR closed mid-watch surfaces as exit 4 with the documented stderr and no stdout
- [ ] `--timeout S` on `--block` exits 0 with no output on timeout (not 124, not stderr noise)
- [ ] `test/test-ci-watch.sh` covers the ten cases listed under "Test shape"; `bash test/test-ci-watch.sh` is green
- [ ] `shellcheck` clean across the touched libs and the new subcommand
- [ ] `pre-commit run --all-files` clean
- [ ] One commit on a feature branch: `feat(ci-watch): add ci-watch subcommand, signature lib, ci_failures forge op (step 14)`
