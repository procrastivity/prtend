# Step 17 — `prtend doctor` subcommand

## Context

Land the operational health check. `prtend doctor` is what the skill (and the human author) runs to confirm the environment is sane before — or during — a watch session, and what cleans up stale per-PR state files left behind when a watch session ended without a clean `pr_closed` event (machine crash, killed terminal, the user closing a PR through the web UI while no `watch` was attached). Today the only path to discover such drift is to read `<state-dir>` by hand; with `doctor` in place the skill can call one CLI to verify forge auth + cleanup safely, matching the existing `gh extension doctor` / `glab check-update` muscle memory.

This step composes existing primitives only: `prtend_forge_cli_ready` (step 03) for the forge gate, `prtend_forge_pr_state` (step 04) for closed-PR detection, `prtend_state_dir` (step 05) for the state directory, `prtend_state_clear` (step 05) for `--fix` cleanup of stale state files, `prtend_config_resolve` and the config resolution chain (step 12) for the readable-config check, and `prtend_note_marker_version` (step 06) for the marker-version self-check. It introduces no new forge ops, no new state-lib functions, and no new note-lib functions — every primitive is already shipped. The new file is the subcommand itself.

The output contract is a single JSON document (not a stream), unlike the watch primitives: `doctor` is a one-shot reporter. See `../cli-contract.md` § "`prtend doctor`" for the exact shape (one `checks[]` array plus `summary` and `fixed[]`), the per-check status enum (`pass` / `warn` / `fail`), and the exit-code table (0 when no `fail` remains, 1 otherwise, 2 on bad flags). Each check has a stable `name` slug; `--check NAME` runs only the named subset, repeatable. `--fix` applies safe repairs and lists them under `fixed[]`.

This subcommand is the natural place to land `stale_subscriptions` cleanup because nothing else in the CLI walks `<state-dir>` — `state_clear` is called by `watch` on `pr_closed`, but a session that died before reaching `pr_closed` leaks. `doctor --fix` is the supported escape valve referenced in `../overview.md` § "What's not in v0" → "Cross-PR coordination" (one PR per invocation; doctor reconciles the population across PRs).

## Prerequisites

- Step 02 (`dispatcher`) complete — `bin/prtend` already routes `doctor` to `lib/prtend/prtend-subcommands/doctor.bash` and calls `prtend_cmd_doctor` (see `bin/prtend` case statement); `prtend_log_*`, the `--verbose` / `--quiet` plumbing, and `prtend_json_get` are available.
- Step 03 (`forge-detect`) complete — `prtend_forge_cli_ready` is the readiness gate; `prtend_forge_detect` resolves `github` / `gitlab` per checkout.
- Step 04 (`forge-read`) complete — `prtend_forge_pr_state` is the per-PR closed/merged probe used by `stale_subscriptions`.
- Step 05 (`state`) complete — `prtend_state_dir`, `prtend_state_path`, and `prtend_state_clear` are the file-system surface this subcommand touches. `prtend_state_clear` already removes the per-PR JSON via `rm -f` (see `lib/prtend/prtend-state-lib.bash:190`); no new state-lib functions.
- Step 06 (`notes`) complete — `prtend_note_marker_version` returns `v1` and is the canonical source for the `marker_consistency` check's known-version list.
- Step 12 (`config`) complete — `prtend_config_resolve` returns the active config path (or empty if none), and the resolution chain is what `config_readable` walks. `prtend_config_target_path` is not needed.

Required on the host for the forge-touching checks (`forge_cli_installed`, `forge_cli_authed`, `forge_cli_version`, `stale_subscriptions`): the forge CLI matching the checkout (`gh` or `glab`), authenticated. The non-forge checks (`config_readable`, `state_dir_writable`, `marker_consistency`) must work in an unauthed / offline checkout — they're the "is my install sane" subset that should never require network.

## Goal

After this step:

- `bin/prtend doctor` runs all standard checks in the order listed in `../cli-contract.md` § "Standard checks" (`forge_cli_installed`, `forge_cli_authed`, `forge_cli_version`, `config_readable`, `state_dir_writable`, `stale_subscriptions`, `marker_consistency`) and emits **one** JSON document on stdout with `checks[]`, `summary`, and `fixed[]`. Exit 0 if no `fail` results; exit 1 otherwise. No streaming — `doctor` always produces a single document.
- `bin/prtend doctor --fix` additionally applies the safe repairs each fixable check exposes. For v0 the only fixable check is `stale_subscriptions` (removes state files for PRs that the forge reports as `closed` / `merged`). When a fix is applied, the corresponding check's post-fix `status` flips to `pass` and the action is recorded in `fixed[]`. Exit 0 if no unfixable `fail` remains; exit 1 if any `fail` survived `--fix`.
- `bin/prtend doctor --check NAME` runs only the named checks, repeatable (`--check forge_cli_installed --check config_readable`). Unknown names → exit 2 with `prtend: doctor: unknown check '<name>'` on stderr, no JSON on stdout. `--check` composes with `--fix`.
- Each check object matches the contract: `{name, status, message, fixable}`, plus optional `fix_action` (human-readable description of what `--fix` would do) when `fixable=true` and `status != "pass"`. `status` is one of `"pass"` / `"warn"` / `"fail"`. `summary` is `{pass, warn, fail}` counters; `fixed[]` is `[{check, action, details[]}]`.
- The `stale_subscriptions` check walks `<state-dir>/*.json`, extracts the PR number from each filename's stem (`123.json` → `123`, validating `^[0-9]+$`), calls `prtend_forge_pr_state` per file, and treats a result of `closed` / `merged` as stale. The check produces a `warn` (not `fail`) with a `message` summarizing count + the PR numbers, and `fixable=true`. With `--fix`, each stale file is removed via `prtend_state_clear`; on per-file removal failure log a warning to stderr but continue the loop, and the surviving file shows up under the still-warn check after the pass. Files whose stem is not a positive integer are ignored silently (other prtend artifacts may eventually share the dir). A state file for a PR that `prtend_forge_pr_state` reports as not found (exit 1) is **also** stale — same fix path.
- The `stale_subscriptions` check requires forge readiness. If `prtend_forge_cli_ready` failed earlier in the same `doctor` run, `stale_subscriptions` is reported as `{status:"warn", message:"forge CLI not ready; skipped"}` with `fixable=false`. The walk itself is skipped — never partial cleanup based on partial data.
- The `config_readable` check calls `prtend_config_resolve` and reports the resolved path under `message`; when the chain returns empty, status is `warn` (no config is fine — built-in defaults apply) with `message:"no config file found; using built-in defaults"` and `fixable=false`. When the chain returns a path but reading the file fails (`prtend_config_get` on any well-known key returns non-zero with a non-empty stderr), status is `fail` with `message` carrying the parser error, `fixable=false` (the user has to repair the file by hand — auto-rewriting a malformed YAML/JSON config is too risky).
- The `state_dir_writable` check resolves `prtend_state_dir`, attempts to create it if missing, writes + removes a probe file (`<state-dir>/.prtend-doctor-probe`), and reports `pass` on success. On failure (no write permission, parent missing and uncreatable, etc.), status is `fail` with `fixable=false` and `message` carrying the OS-level reason. The probe file must never linger — even on signal interruption — so wrap the write/remove in a trap or remove it inside an `EXIT` trap scoped to the subcommand.
- The `marker_consistency` check confirms `prtend_note_marker_version` returns a value the v0 schema recognizes (currently the single string `v1`). In v0 this is a tautology and always `pass`; the check exists so future marker bumps (`v2`) can surface "old prtend notes on the forge use a deprecated marker" without renaming the CLI surface. For v0 do **not** scan the forge — no per-PR or per-thread queries from this check. Message: `"Only marker v1 in use"`. `fixable=false`.
- `--verbose` / `--quiet` are honored: at default verbosity, stderr is silent unless something goes wrong. `--verbose` echoes "Running check: <name>" lines to stderr as each runs. `--quiet` suppresses even those plus the per-file warnings during `--fix` (the JSON still lists what was attempted under `fixed[]`).
- No changes to `bin/prtend`, no changes to any lib file, no changes to `cli-contract.md` / `overview.md` / `forge-mapping.md` / `skill-prompts.md`. The only new files are the subcommand and its test surface.

## Files to create or modify

- `lib/prtend/prtend-subcommands/doctor.bash` (NEW)
- `test/fixtures/doctor/` (NEW) — fake-forge readiness/`pr_state` stubs, sample config files (well-formed + malformed), and a small set of pre-seeded state files for stale-detection tests.
- `test/test-doctor.sh` (NEW) — match `test/test-watch.sh` / `test/test-reviews-poll.sh` harness style: a per-test tmp `PRTEND_STATE_DIR` plus function overrides for `prtend_forge_cli_ready` and `prtend_forge_pr_state`.

No changes to `bin/prtend`, `prtend-lib.bash`, `prtend-forge-lib.bash`, `prtend-state-lib.bash`, `prtend-notes-lib.bash`, `prtend-signature-lib.bash`, the existing subcommand files (`ci_watch.bash`, `reviews_poll.bash`, `watch.bash`, `note_post.bash`, `defer_write.bash`, `pr_open.bash`, `detect.bash`, `config.bash`), or any file under `docs/`. If you find yourself touching any of those, you've drifted out of scope.

## Implementation

### `lib/prtend/prtend-subcommands/doctor.bash`

Public surface:

```bash
prtend_cmd_doctor "$@"   # parses flags, runs checks, emits one JSON doc, returns documented exit codes
```

Flag parsing:

- `--fix` — boolean, default off.
- `--check NAME` — repeatable; case-sensitive against the canonical slug set. Unknown name → exit 2 with `prtend: doctor: unknown check '<name>'` on stderr. When omitted, all standard checks run.
- `--verbose` / `-v`, `--quiet` / `-q` — already handled by the dispatcher's pre-parse layer if present; otherwise propagate the convention.
- Any other flag → exit 2 with `prtend: doctor: unknown option '<flag>'`.

Composition (in order):

1. **Lazy-source the support libs.** Source `prtend-state-lib.bash` and `prtend-notes-lib.bash` from `${PRTEND_LIB:-…}` with the same lazy-load guard pattern (`PRTEND_STATE_LIB_LOADED`, `PRTEND_NOTES_LIB_LOADED`) the watch primitives use. The forge lib is already sourced by `bin/prtend` before dispatch.

2. **Resolve the check set.** Define a single canonical array `_DOCTOR_CHECKS=(forge_cli_installed forge_cli_authed forge_cli_version config_readable state_dir_writable stale_subscriptions marker_consistency)` — this is the order the JSON `checks[]` array preserves. When `--check NAME` is given (one or more times), filter to that subset preserving canonical order; unknown names exit 2 before any check runs (catching typos early). The set runs in the **same order regardless of how `--check` was passed** so output is deterministic.

3. **Run each check, accumulate one row per check.** Each check is a small helper function that returns its row as a single JSON object on stdout (so the outer driver can `jq -s` the whole set into the final array). The helpers do not exit on failure — they always emit a row and return 0. A check that needs forge readiness consults a memoized `_doctor_forge_ready` value computed once at the start of the run (see "Per-check details" → `stale_subscriptions`).

4. **Apply `--fix` after the first pass.** If `--fix` is set, iterate over the rows. For each row with `fixable=true` and `status != "pass"`, dispatch to the check-specific fix routine (currently only `_doctor_fix_stale_subscriptions`). The fix routine returns the list of details to record under `fixed[]`. After every fix is attempted, **re-run only the checks that were fixed** (not the whole set) and replace their rows in the accumulator with the new results. This means a successful fix flips the status to `pass` in the final document; a partial / failed fix leaves the row at `warn` / `fail` and the user can read `fixed[]` to see what was tried.

5. **Compute `summary` and emit the document.** `summary={pass:N1, warn:N2, fail:N3}` is a count over the final rows. Emit one JSON document built with `jq -cn` (or `jq -n` if `--verbose` — pretty-printed is a quality-of-life upgrade for human consumers): `{checks, summary, fixed}`. Then determine exit code: `0` when `summary.fail == 0`, `1` otherwise.

### Per-check details

Each helper is named `_doctor_check_<slug>` and returns a row of shape `{name, status, message, fixable[, fix_action]}`. Build rows with `jq -cn --arg name X --arg status Y --arg message Z --argjson fixable B '{name:$name, status:$status, message:$message, fixable:$fixable}'`.

#### `forge_cli_installed`

Read `_PRTEND_FORGE` (set by `prtend_forge_detect` during `bin/prtend` startup) or call `prtend_forge_detect` directly if unset (memoize the result for `forge_cli_authed` / `forge_cli_version` to reuse). On `github`, check `command -v gh` and capture `gh --version | head -n 1` for the message. On `gitlab`, mirror with `glab`. When forge detection itself fails (no `.git`, no remote, no `PRTEND_FORGE`), status is `fail` with `message:"no forge detected"`, `fixable=false`. When the binary isn't on PATH, status is `fail` with `message:"gh not found on PATH"` (or `glab`), `fixable=false`.

#### `forge_cli_authed`

Skip with `status:"warn", message:"forge CLI not installed; skipped"`, `fixable=false` when `forge_cli_installed` failed. Otherwise call the forge-specific auth probe: `gh auth status` (exit 0 = authed; reads stderr to recover the user login) or `glab auth status`. On success, status is `pass` with `message:"Authenticated as <login>"`. On failure, status is `fail` with `message` carrying the first line of the CLI's error output, `fixable=false`. (Authing the user is out of scope — the message tells them to run `gh auth login` / `glab auth login`.)

#### `forge_cli_version`

Skip with `warn` when `forge_cli_installed` failed (same skip pattern). Parse the version from `gh --version` (line 1: `gh version 2.62.0 (2025-...)`) or `glab --version` (line 1: `glab version 1.39.0 ...`). Compare against a per-forge floor constant defined at the top of the file (`PRTEND_GH_MIN_VERSION=2.50.0`, `PRTEND_GLAB_MIN_VERSION=1.35.0` — pick values that match what step 04's forge-lib actually needs; if uncertain, set both to the lowest version the dev environment was tested with and TODO-comment a future tightening). On parse failure (the CLI changed its `--version` format), status is `warn` with `message:"could not parse <cli> version"`, `fixable=false`. When the parsed version meets the floor, status is `pass`. When below, status is `fail` with `message:"<cli> X.Y.Z is below minimum A.B.C"`, `fixable=false`.

Use a small Bash function for the version compare (no `sort -V` reliance — `sort -V` is GNU-only and the macOS dev path uses BSD `sort` unless `coreutils` is on PATH); compare three numeric components after splitting on `.`. Trailing pre-release suffixes (`-beta.1`, `-rc.2`) are stripped before compare; a pre-release at the floor version is treated as the same as the floor (don't fail on `2.62.0-beta.1` if `2.62.0` would pass).

#### `config_readable`

Call `prtend_config_resolve` (already returns the active config path or empty). On empty → `status:"warn", message:"no config file found; using built-in defaults"`, `fixable=false`. On non-empty path:

- If the file doesn't exist (the resolution chain returned a stale candidate path), `status:"fail", message:"<path> does not exist"`, `fixable=false`.
- If the file exists but `prtend_config_get system_reviewers` (any well-known key — pick one that's always read at startup) returns non-zero with non-empty stderr, `status:"fail", message:"<path>: <first-line-of-stderr>"`, `fixable=false`.
- Otherwise `status:"pass", message:"Loaded from <path>"`, `fixable=false`.

Probing with one key is enough; the config-lib already validates the file structure on first read. Do not enumerate all known keys.

#### `state_dir_writable`

Resolve `prtend_state_dir`. On resolve failure (no slug derivable, no `git` ancestor, no `XDG_STATE_HOME`, no `HOME`), `status:"fail", message:"state directory could not be resolved"`, `fixable=false`.

On success, create the directory if missing (`mkdir -p`). Write a probe file `<state-dir>/.prtend-doctor-probe` containing `ok`, then `rm -f` it. Wrap the probe in an `EXIT` trap (scoped to the function via `trap '…' RETURN` Bash 4.4+ pattern, or via a subshell `( … )` that always removes the probe before exiting) so a signal can't leave the probe behind. On any failure, `status:"fail"` with `message` carrying the OS error (capture stderr from `mkdir` / `touch` / `rm` via `2>&1`), `fixable=false`. On success, `status:"pass", message:"Writable: <state-dir>"`, `fixable=false`.

#### `stale_subscriptions`

If `_doctor_forge_ready != 1` (forge installed + authed both passed), report `{status:"warn", message:"forge CLI not ready; skipped", fixable:false}` and return. The walk itself requires both `gh`/`glab` and auth.

Resolve `prtend_state_dir`; if it doesn't exist yet, `status:"pass", message:"No state files yet"`, `fixable=false`. Otherwise walk `<state-dir>/*.json` (use a `for f in "$state_dir"/*.json; do ... done` loop with a `[[ -e "$f" ]]` guard against the unmatched-glob case). For each file:

- Stem (`basename -s .json`) must match `^[0-9]+$`; skip silently otherwise (other artifacts may share the dir).
- Call `prtend_forge_pr_state "$pr"`. Treat exit 1 (PR not found) as stale. Treat a successful call returning `.state` in `{closed, merged}` as stale. Treat anything else (still `open` / `draft`, forge transient error) as non-stale — `doctor` is conservative; a transient network glitch must never trigger a cleanup of an open subscription.
- Collect stale PR numbers in an array.

When the array is non-empty: `status:"warn"`, `message:"<N> state files for closed PRs (PR #<list>)"`, `fixable=true`, `fix_action:"remove stale state files"`. Where `<list>` is `#A, #B, #C` (deterministic order — sort numerically). When empty: `status:"pass"`, `message:"No stale subscriptions"`, `fixable=false`.

Fix routine `_doctor_fix_stale_subscriptions`: receives the row's PR list (the helper re-derives it by re-running the check — do not parse the message string; preserve the list as a sidecar via a module-scoped associative array `_DOCTOR_STALE_PRS` populated by the check function and consumed by the fix function). For each stale PR, call `prtend_state_clear "$pr"`. On per-call failure, log a warning to stderr (unless `--quiet`) and continue. Return the list of state-file paths actually removed (consult `prtend_state_path` before the remove and accumulate the path strings for `fixed[].details`).

Re-run `_doctor_check_stale_subscriptions` after the fix pass; surviving stale PRs (each removal that failed) stay in the warn row.

#### `marker_consistency`

Read `prtend_note_marker_version`. If the value is in the known-version allowlist (currently the single string `v1` — define `_DOCTOR_KNOWN_MARKER_VERSIONS=(v1)` at the top of the file), `status:"pass", message:"Only marker v1 in use"`. Otherwise (a future bump landed without updating doctor) `status:"warn", message:"Unknown marker version <value>; doctor's known-version list may be stale"`, `fixable=false`. Do **not** call the forge — this is a metadata-only check in v0.

### Key decisions

- **Doctor emits a single JSON document, never a stream.** Aligned with `../cli-contract.md` § "Output discipline" — `doctor` is one-shot, not event-driven. The watch primitives stream because they describe ongoing observation; `doctor` answers "is everything sane right now".
- **`--fix` only re-runs fixed checks, not the whole set.** Re-running everything after a state-file removal would also re-run forge auth probes — slow and unnecessary, since fixes are local and can't affect upstream check results. The narrow re-run keeps `--fix` predictable.
- **Stale detection treats a transient forge error as non-stale.** A `prtend_forge_pr_state` call that returns rc 1 *because the PR was actually deleted* and one that returns rc 1 *because the user's net dropped for two seconds* are indistinguishable from the CLI's exit code alone. The contract from step 04 is that exit 1 means "not found"; if a future forge-lib change starts using exit 1 for transient errors, that's a bug in forge-lib, not here. `doctor` documents the rule explicitly so the reasoning survives the next reviewer.
- **`marker_consistency` does not scan the forge in v0.** The forge scan would require per-PR-per-thread queries and there's no obvious bound (every PR the user has ever pushed). The v1 marker is hardcoded in `prtend_note_marker_version`; the only realistic way the check fails is if a future schema bump forgets to update the allowlist constant in doctor — that's a developer error, caught locally. When the codebase needs a real forge-side audit (post-v2 marker rollout), bump the check to a v2 form with explicit `--audit` opt-in.
- **No `--json` flag.** stdout is JSON unconditionally. Consumers that want pretty output pipe through `jq .`.
- **No `--check NAME` deprecation alias.** Slugs are the canonical surface from day one.
- **Forge-readiness memoization spans the whole doctor run, not per-check.** A single `_doctor_forge_ready` flag set after the first two checks finish lets later checks (`stale_subscriptions`) skip cleanly. Re-probing per check would cost two extra `gh auth status` calls every run.

## Verification

Tests use a fake forge (functions overriding `prtend_forge_cli_ready` / `prtend_forge_pr_state` and where needed shadowing `gh` / `glab` invocations via `PATH` shim) the same way `test/test-ci-watch.sh` and `test/test-watch.sh` do. No real `gh` / `glab` calls. Each test asserts on captured stdout (JSON shape), captured stderr (text), exit code, and on-disk state-file contents.

```bash
shellcheck lib/prtend/prtend-subcommands/doctor.bash test/test-doctor.sh
# → no output, exit 0

bin/prtend doctor --check no_such_check
# → "prtend: doctor: unknown check 'no_such_check'" on stderr, exit 2, no stdout

bin/prtend doctor --bogus
# → "prtend: doctor: unknown option '--bogus'" on stderr, exit 2

test/test-doctor.sh
# → all cases pass; exit 0
```

`test/test-doctor.sh` cases (at minimum):

1. **All checks pass (clean install, no state files)** — fake forge returns `gh` installed + authed + version `2.62.0`; config resolves to a well-formed in-repo file; state dir is creatable + writable; no state files. Output: 7 rows all `pass`; `summary={pass:7, warn:0, fail:0}`; `fixed=[]`; exit 0.
2. **Forge CLI missing** — `prtend_forge_detect` returns 1. `forge_cli_installed` → `fail`; `forge_cli_authed`, `forge_cli_version`, and `stale_subscriptions` are skipped with `warn`. Other checks unaffected. Exit 1.
3. **Forge CLI present but unauthed** — `gh auth status` returns 1. `forge_cli_installed` passes; `forge_cli_authed` → `fail`; `forge_cli_version` still runs (binary is there); `stale_subscriptions` skipped with `warn`. Exit 1.
4. **Forge CLI below minimum version** — fake `gh --version` returns `1.50.0`. `forge_cli_version` → `fail`; others unaffected. Exit 1.
5. **Forge CLI version pre-release at floor** — fake returns `2.62.0-rc.1` with floor `2.62.0`. `forge_cli_version` → `pass`. Confirms the pre-release-strip rule.
6. **Config missing entirely** (`prtend_config_resolve` returns empty) — `config_readable` → `warn`, `message` mentions defaults. Exit 0 (warn isn't fail).
7. **Config malformed** — write a syntactically broken YAML to the resolved path. `config_readable` → `fail`, message carries the first parser-stderr line. Exit 1.
8. **State dir not writable** — pre-create the dir read-only via `chmod 0500`. `state_dir_writable` → `fail`, message carries the OS error. Exit 1. Test cleans up by `chmod 0700` before tearing down.
9. **Stale subscriptions — none stale** — seed two state files for PRs the fake reports as `open`. `stale_subscriptions` → `pass`. Exit 0.
10. **Stale subscriptions — two stale, no `--fix`** — seed three state files; fake reports PR 100 = `open`, 101 = `closed`, 102 = `merged`. `stale_subscriptions` → `warn` with `message:"2 state files for closed PRs (PR #101, #102)"`, `fixable=true`. `summary.warn=1`, `fail=0`. Exit 0. State files still on disk.
11. **Stale subscriptions — two stale, `--fix`** — same fixture as case 10, run with `--fix`. After the fix pass, the row's `status` is `pass`; `fixed=[{check:"stale_subscriptions", action:"removed", details:[<path-101>, <path-102>]}]`. The two state files are gone from disk; PR 100's state file is untouched. Exit 0.
12. **Stale subscriptions — partial fix failure** — same fixture but `chmod 0500` the state dir before `--fix` so `rm` fails. The fix routine logs warnings to stderr; the row stays `warn`; `fixed=[{check:"stale_subscriptions", action:"removed", details:[]}]` (empty details — nothing was actually removed). Exit 1 (the row didn't flip to `pass`; in step 10 it was warn → still warn after fix). **Note:** for v0, a surviving `warn` does **not** trip the fail-exit rule (only `fail` does); update this case to match the actual `summary.fail` count — exit 0 if all surviving statuses are `pass`/`warn`, exit 1 only if any are `fail`. Confirm against the contract before finalizing the assertion.
13. **`--check` subset** — `prtend doctor --check config_readable --check state_dir_writable` runs exactly two checks, in canonical order (config_readable first), and emits `checks[]` of length 2. Other checks absent.
14. **`--check` unknown name** — `prtend doctor --check bogus` exits 2 with stderr `prtend: doctor: unknown check 'bogus'`. No stdout.
15. **Marker version tautology** — confirm `marker_consistency` is `pass` with `message:"Only marker v1 in use"` under default conditions.
16. **Marker version mismatch** — override `prtend_note_marker_version` in the test to return `v999`. `marker_consistency` → `warn`, `fixable=false`. Exit 0 (warn).

Reuse the fake-forge harness pattern from `test/test-watch.sh:30-80`; the harness should set `PRTEND_STATE_DIR` to a per-test tmp dir and override forge entry points by sourcing replacements **after** sourcing the real `prtend-forge-lib.bash`. Override `gh` / `glab` binaries via a per-test `PATH` shim that emits the version line / auth-status line the test wants (most cases need only `prtend_forge_cli_ready` and `prtend_forge_pr_state` overrides; the version test additionally needs a `gh` shim emitting the desired version banner).

## Done

- [ ] `lib/prtend/prtend-subcommands/doctor.bash` exists, no executable bit (it's a sourced file), `shellcheck` clean.
- [ ] All flag-parsing rejections behave as specified (bad `--check NAME`, unknown options).
- [ ] `test/test-doctor.sh` exists, sources the harness pattern, exercises all 16 numbered cases above, and exits 0.
- [ ] `prtend_forge_cli_ready` / `prtend_forge_pr_state` / `prtend_state_dir` / `prtend_state_path` / `prtend_state_clear` / `prtend_config_resolve` / `prtend_note_marker_version` are called as their existing signatures (no shimming, no flag additions, no new optional parameters).
- [ ] No diff to `bin/prtend`, `prtend-lib.bash`, `prtend-forge-lib.bash`, `prtend-state-lib.bash`, `prtend-notes-lib.bash`, `prtend-signature-lib.bash`, `ci_watch.bash`, `reviews_poll.bash`, `watch.bash`, `note_post.bash`, `defer_write.bash`, `pr_open.bash`, `detect.bash`, `config.bash`, or any file under `docs/`.
- [ ] `git status` shows only: `lib/prtend/prtend-subcommands/doctor.bash`, `test/fixtures/doctor/...`, `test/test-doctor.sh`.
- [ ] One commit on the `step-17-doctor` branch: `feat(doctor): add doctor health-check subcommand`.
