# Step 08 — `prtend pr-open` subcommand

## Context

Wire the first *mutating* subcommand. `prtend pr-open` is what the skill calls when the user's intent is "submit PR": it guarantees the branch is on the remote, ensures an open PR exists for it, then runs the reviewer flow (system reviewers from config, optional reviewers from flags). It is idempotent — re-running on a branch that already has an open PR returns that PR without modification.

Step 07 (`detect`) gave the skill its read-only entrypoint. This step gives it the corresponding write-side entrypoint. After this step the skill can compose `detect → pr-open → (watch)` to satisfy the entry decision table in `../overview.md` § "Entry decision". The watch entrypoints land in subsequent steps; this step does not start a watch session.

This is also where the forge-lib gains its first mutation surfaces. So far every `_prtend_forge_<gh|gl>_*` private has been a read; the privates landing here (`pr_create`, `reviewer_add`, `pr_url`) post or PATCH. The dispatch + naming convention is unchanged — mutations route through `prtend_forge_dispatch` exactly like reads.

See `../cli-contract.md` § "`prtend pr-open`" for the exact output contract and `../forge-mapping.md` §§ "Push branch", "Create PR", "Add reviewer" for the per-forge command map.

## Prerequisites

- Step 02 (`dispatcher`) complete — `bin/prtend` already routes `pr-open` to `lib/prtend/prtend-subcommands/pr_open.bash` and calls `prtend_cmd_pr_open`.
- Step 03 (`forge-detect`) complete — `prtend_forge_detect`, `prtend_forge_cli_ready`, `prtend_forge_current_branch`, `prtend_forge_dispatch` exist.
- Step 04 (`forge-read`) complete — `prtend_forge_pr_for_branch` and `prtend_forge_pr_state` exist; this step composes them to decide created-vs-used.
- Step 07 (`detect`) complete — `prtend_forge_active_remote` and `prtend_forge_default_branch` exist; this step reuses both.
- Core lib (`prtend-lib.bash`) provides `prtend_config_resolve` and `prtend_config_get` — used to read `system_reviewers` from the resolved config.

Required on the host for smoke tests: the forge CLI matching the checkout (`gh` or `glab`), authenticated, and a sandbox repo where you can actually create and close a PR. Reviewer-add testing wants at least one valid login on the forge plus one bogus login (to exercise the `reviewers_skipped` path).

## Goal

After this step:

- `lib/prtend/prtend-subcommands/pr_open.bash` exists and defines `prtend_cmd_pr_open`.
- `prtend pr-open --title TITLE [--body BODY] [--draft] [--target-branch BRANCH] [--optional-reviewer LOGIN ...]` succeeds against a real PR, emits the JSON object documented in `cli-contract.md` § "`prtend pr-open`" (single line, compact) with every field populated per its declared type, and is idempotent on re-invocation.
- The `action` field correctly distinguishes the four documented cases:
  - `created` — branch was not on remote; pushed it; created a new PR.
  - `created_existing_branch` — branch was already on remote; created a new PR.
  - `used_existing` — open PR already existed; no push needed; reviewer flow ran additively (no duplicate requests).
  - `pushed_existing_pr` — open PR existed and local was ahead of remote; pushed; PR unchanged otherwise.
- Closed/merged PR on the branch → exit 4 with `prtend: branch '<branch>' has a closed/merged PR (#N); user must decide reopen/new/abort` on stderr. The subcommand never silently creates a duplicate PR.
- Pushing to the default branch is refused (exit 2) — `pr-open` is a no-op there; the skill should not have called it. Catching it in the CLI keeps the error precise even if the skill skips the check.
- Forge-CLI missing or not authed → exit 3 (per `cli-contract.md` § "Exit codes"). Bad flags (missing `--title`, conflicting flags, unknown flag, `--draft` value) → exit 2.
- `prtend-forge-lib.bash` gains three new dispatched functions: `prtend_forge_pr_create`, `prtend_forge_pr_url`, `prtend_forge_reviewer_add`. Each follows the `_prtend_forge_<gh|gl>_<suffix>` pattern, returns the canonical shapes (or raw values, where the existing reads do), and is the *only* place that constructs the underlying CLI invocation.
- A focused test fixture + script under `test/` exercises the subcommand against a mocked forge dispatch, matching the harness style chosen in step 07. No real network calls in tests.

## Files to create or modify

- `lib/prtend/prtend-subcommands/pr_open.bash` (NEW)
- `lib/prtend/prtend-forge-lib.bash` (MODIFY — add `prtend_forge_pr_create`, `prtend_forge_pr_url`, `prtend_forge_reviewer_add` and their `_gh`/`_gl` privates)
- `lib/prtend/prtend-lib.bash` (MODIFY — add `prtend_config_list_get <key>` reading a list-valued YAML key; small, see below)
- `test/pr_open.bats` or `test/pr_open.sh` (NEW — match the harness from step 07)
- `test/fixtures/pr_open/` (NEW — small JSON / text fixtures for the mocked dispatch)

## Implementation

### `lib/prtend/prtend-subcommands/pr_open.bash`

Public surface:

```bash
prtend_cmd_pr_open "$@"   # parses flags, runs the flow, emits JSON, returns documented exit codes
```

Flag parsing:

- `--title TITLE` (required) — fail with exit 2 if absent or empty.
- `--body BODY` (optional, default empty string).
- `--draft` (optional, no value; default off).
- `--target-branch BRANCH` (optional) — defaults to `prtend_forge_default_branch`; if that lookup fails, omit the flag from the underlying forge invocation and let the CLI use its own default (which is also the repo default branch).
- `--optional-reviewer LOGIN` (optional, repeatable) — accumulate into an array.
- Every value-bearing flag must reject empty and dash-leading values, same as `detect --branch`.
- Anything else → exit 2 with a usage error on stderr.

Composition (in this order, so error mapping stays clean):

1. **Git repo + readiness gate.** `git rev-parse --git-dir` or exit 1 with `prtend: not in a git repository`. Then `prtend_forge_cli_ready`: propagate exit 1/3 verbatim. Unlike `detect`, `pr-open` *must* have an authed forge CLI — there is no fallback URL sniff path that lets it create a PR.
2. **Resolve current branch.** `prtend_forge_current_branch`. Then read `prtend_forge_default_branch`; if the current branch equals it, exit 2 with `prtend: refusing to open a PR from the default branch ('<branch>')`. (Skip the check if `default_branch` lookup fails — better to attempt than to refuse incorrectly.)
3. **Resolve remote.** `prtend_forge_active_remote`. Required; exit 1 if it fails.
4. **Existing-PR probe.** `prtend_forge_pr_for_branch "$branch"`:
   - exit 1 → no PR. Continue to push + create.
   - exit 2 → ambiguous (multiple open). Exit 4 with `prtend: branch '<branch>' has multiple open PRs; refusing` on stderr.
   - exit 0 → PR `$pr`. Then `prtend_forge_pr_state "$pr"`:
     - `open` / `draft` → existing open PR; remember it, decide push action in step 6.
     - `closed` / `merged` → exit 4 with the documented stderr message.
5. **Push decision.** Compute three booleans before mutating anything:
   - `branch_on_remote` — `git ls-remote --exit-code --heads "$remote" "$branch"` succeeds.
   - `local_ahead` — `branch_on_remote` is true AND the local tip is not contained in `<remote>/<branch>`. Use `git fetch --quiet "$remote" "$branch"` once, then compare `git rev-parse HEAD` to `git rev-parse "$remote/$branch"`; if they differ and the remote tip is reachable from `HEAD~...HEAD` (`git merge-base --is-ancestor "$remote/$branch" HEAD`), the local has commits to push. If the remote tip is *not* an ancestor of HEAD (divergence), surface `prtend: branch '<branch>' diverges from <remote>/<branch>; push manually first` on stderr and exit 1 — `pr-open` does not force-push.
   - `pr_existed_open` — set in step 4.
6. **Push (or not) and choose action.** Decision table — implement as a single `if/elif` chain on the three booleans:

   | `pr_existed_open` | `branch_on_remote` | `local_ahead` | Push? | Resulting `action` |
   |---|---|---|---|---|
   | true | (must be true) | true | yes (`git push <remote> <branch>`) | `pushed_existing_pr` |
   | true | true | false | no | `used_existing` |
   | false | false | (n/a) | yes (`git push --set-upstream <remote> <branch>`) | `created` |
   | false | true | true | yes (`git push <remote> <branch>`) | `created_existing_branch` (after create) |
   | false | true | false | no | `created_existing_branch` (after create) |

   Push failures (`git push` non-zero) propagate as exit 1; print the git stderr on stderr unmodified.
7. **Create PR if needed.** When `pr_existed_open` is false: call `prtend_forge_pr_create --title "$title" [--body "$body"] [--draft] [--target-branch "$target"]` (passing the flags through with proper quoting). Capture the new PR number into `$pr`. Failure is exit 1.
8. **Resolve URL and final state.** `prtend_forge_pr_url "$pr"` and `prtend_forge_pr_state "$pr"`. Final `state` for the JSON output is whatever `pr_state` reports — usually `open` or `draft`, matching whether `--draft` was passed for a new PR.
9. **Reviewer flow.** Read system reviewers from config; combine with the `--optional-reviewer` list (dedup, preserve order: system reviewers first, then optional in flag order). For each login:
   - `prtend_forge_reviewer_add "$pr" "$login"`:
     - exit 0 → push login into `reviewers_requested`.
     - exit 1 → push login into `reviewers_skipped` and emit a one-line reason on stderr (e.g. `pr-open: reviewer 'badname' rejected by forge (unknown user)`). Do not abort.
     - exit ≥2 → propagate (real error: CLI broken, network).
   - Idempotency on re-invocation: when `pr_existed_open` is true, the reviewer is already requested; the underlying CLI no-ops harmlessly. The lib reports exit 0 in that case — same JSON, same `reviewers_requested` set. *Do not* try to diff against existing reviewers in this step; that's reviewer-list-aware behavior and is out of scope for v0 (see `cli-contract.md` § "What's not in v0").
10. **Emit JSON on stdout** via `jq -c -n`, matching the field order from `cli-contract.md`. Arrays must always emit as arrays (`[]` when empty, not omitted, not `null`).

### `prtend-forge-lib.bash` additions

Three public functions, each a one-liner dispatching through `prtend_forge_dispatch`. Privates per the patterns established in step 04. All three are mutations — they `POST`/`PATCH`, so error handling must distinguish "forge said no" (data, exit 1) from "CLI broken" (exit 3) where possible.

`prtend_forge_pr_create` — create a PR for the *current* branch on the *current* repo. Args are forwarded as long-form flags so the lib can quote them safely:

```
prtend_forge_pr_create --title T [--body B] [--draft] [--target-branch BR]
```

Echoes the new PR number on stdout (just the integer, like `pr_for_branch`).

- `_prtend_forge_gh_pr_create`: assemble `gh pr create --head "$branch" --title "$title"` plus optional `--body`, `--draft`, `--base "$target"`. `gh` prints the PR URL on stdout; parse the trailing integer (`awk -F/ '{print $NF}'`). Validate that the parsed value is `^[0-9]+$` before echoing; otherwise propagate stderr and exit 1.
- `_prtend_forge_gl_pr_create`: assemble `glab mr create --source-branch "$branch" --title "$title"` plus optional `--description`, `--draft`, `--target-branch "$target"`. glab also prints the MR URL on stdout; parse trailing integer the same way.
- Both privates derive `$branch` from `prtend_forge_current_branch`; the subcommand never passes it down, because forge CLIs default to the current branch and the privates honor that convention.

`prtend_forge_pr_url <pr>` — echo the canonical web URL for the PR, exit 0. Empty + exit 1 if the forge can't tell us.

- `_prtend_forge_gh_pr_url`: `gh pr view "$pr" --json url -q .url`.
- `_prtend_forge_gl_pr_url`: `glab mr view "$pr" --output json | jq -r '.web_url // empty'`.

`prtend_forge_reviewer_add <pr> <login>` — request `login` as a reviewer. Echo nothing on success.

- Exit 0 — added (or already on the list — both CLIs report this idempotently in current versions; verify against the version pinned in `flake.nix` and fall back to "if stderr matches 'already requested' or equivalent, treat as success").
- Exit 1 — forge rejected (unknown user, no permission). Surface the stderr to the caller; the subcommand wraps it.
- Exit ≥2 — CLI invocation error; propagate.

- `_prtend_forge_gh_reviewer_add`: `gh pr edit "$pr" --add-reviewer "$login"`. Stderr text patterns of interest: `Could not request reviewer` → exit 1; auth/network failures → exit 3 propagated by the higher-level dispatch.
- `_prtend_forge_gl_reviewer_add`: `glab mr update "$pr" --reviewer "$login"`. **Caveat documented in `../forge-mapping.md` § "Add reviewer":** older `glab` versions *replace* the reviewer set instead of appending. The implementation must:
  1. Read current reviewers via `glab mr view "$pr" --output json | jq -r '.reviewers[]?.username'`.
  2. Append `$login` (skip if already present — exit 0).
  3. Build the combined comma-separated list and pass it as `--reviewer "a,b,c"`.
  This makes the additive behavior version-independent. Add a one-line comment pointing at the forge-mapping note so future maintenance knows why the lookup is required.

### `prtend-lib.bash` addition: `prtend_config_list_get`

`prtend_config_get` only handles scalar keys. The reviewer flow needs `system_reviewers`, a YAML list:

```yaml
system_reviewers:
  - copilot
  - duo
```

Add `prtend_config_list_get <key>` next to `prtend_config_get`, with the same key-safety regex (`^[A-Za-z_][A-Za-z0-9_]*$`). Behavior:

- If `${PRTEND_<UPPERCASE_KEY>}` env override is set, treat it as a comma-separated list and emit one entry per line.
- Else resolve the config path via `prtend_config_resolve`. If absent, exit 0 with no output.
- Else parse: read lines from the first `<key>:` line up to the next non-indented key. For each indented line matching `^[[:space:]]+-[[:space:]]+(.+)$`, strip optional surrounding quotes and emit the value. Stop at the next top-level YAML key (a line matching `^[A-Za-z_].*:`).
- One line per item on stdout. No items → no output, exit 0.
- This is a naive parser, deliberately matching the scope choice of the existing scalar `prtend_config_get`. It does not understand flow-style lists (`[a, b]`); the writer (a future `config init`) will always emit block-style. Leave a code comment to that effect.

### Key decisions

- **Idempotency without a reviewer diff.** When `pr_existed_open` is true we still call `reviewer_add` for every configured reviewer. Both forge CLIs no-op when the login is already requested; the lib treats that as exit 0. We *do not* try to read the current reviewer list first and skip — that would require a second forge call per PR for every invocation, which is the wrong tradeoff in v0.
- **`--target-branch` resolution is best-effort.** If `prtend_forge_default_branch` fails (no remote HEAD, weird checkout), omit `--target-branch` from the underlying CLI call and let it use its own default. Refusing here would block PR creation for legitimate repos with unset remote HEADs.
- **Refusing on the default branch is a flag-validation error, not a workflow error.** Exit 2 is the right code: the caller's invocation was wrong. The skill's entry decision table already excludes this case, so hitting it means the skill called us in error.
- **No watch entry from this subcommand.** `pr-open` returns after the reviewer flow finishes. The skill composes `pr-open → watch` itself; making `pr-open` block on a watch session would conflate two cleanly separable concerns and break the one-event-per-call invariant of the watch subcommands.
- **`gh pr create --head "$branch"` is required, not optional.** `gh` defaults `--head` to the current branch, but only when there's a tracking remote configured. After our first push we do `--set-upstream`, but the same invocation often races against `gh`'s upstream-detection; passing `--head` explicitly removes the race entirely.
- **Exit 4 covers two distinct refusals.** Multiple open PRs (data ambiguous) and closed/merged PR (would-be silent duplicate) both map to exit 4 per `cli-contract.md`. The stderr message disambiguates for humans; the JSON shape on stdout is the standard contract object even on these refusals — except that we do *not* emit JSON on stderr-only failures here. Caller should ignore stdout when exit ≠ 0.

### Test shape

Match whatever harness step 07 landed (bats or plain bash with a `run_test` helper — same convention). Mock `prtend_forge_dispatch` (or shadow the `_prtend_forge_gh_*` privates) plus the git plumbing (`git push`, `git ls-remote`, `git rev-parse`, `git fetch`, `git merge-base`) via `PATH` shimming or function override.

Fixtures under `test/fixtures/pr_open/`:

- `pr_for_branch.none.txt` / `.open.txt` / `.ambiguous.txt` — same shape as step 07.
- `pr_state.open.json` / `.draft.json` / `.closed.json` / `.merged.json`.
- `pr_create.url.txt` → `https://github.com/owner/repo/pull/124\n`.
- `pr_url.json` → `{"url":"https://github.com/owner/repo/pull/124"}` (and a glab variant).
- `reviewer_add.ok.txt` → empty, exit 0.
- `reviewer_add.rejected.txt` → stderr `Could not request reviewer 'badname'`, exit 1.
- `config_with_system_reviewers.yml` — block-style list with two entries.

Cases to cover:

1. Happy path: no PR, branch not on remote → push + create + reviewer flow → `action: "created"`, `reviewers_requested` includes system + optional, `reviewers_skipped: []`.
2. Branch on remote, no PR → `action: "created_existing_branch"`; no `--set-upstream` in the push command.
3. Open PR exists, local matches remote → `action: "used_existing"`; no push command issued.
4. Open PR exists, local ahead of remote → `action: "pushed_existing_pr"`; `git push` issued without `--set-upstream`.
5. Closed PR exists → exit 4 with the documented stderr; no push, no create, no reviewer call.
6. Merged PR exists → exit 4 (same path).
7. Ambiguous (multiple open) → exit 4.
8. On default branch → exit 2; nothing else runs.
9. Forge CLI not installed → exit 3 (mock `prtend_forge_cli_ready` to 3).
10. Reviewer rejected → entry lands in `reviewers_skipped`; subcommand still exits 0.
11. `--draft` → `pr_state` returns `draft`; emitted `state` is `draft`.
12. Diverged branch (local has commits the remote doesn't, but remote tip is not an ancestor of HEAD) → exit 1 with the "diverges; push manually" stderr.
13. Missing `--title` → exit 2.
14. `--optional-reviewer` repeated three times → all three end up in `reviewers_requested` in declaration order.

## Verification

```bash
shellcheck bin/prtend lib/prtend/prtend-lib.bash lib/prtend/prtend-forge-lib.bash lib/prtend/prtend-subcommands/pr_open.bash
# → no output, exit 0

# Help still works and lists pr-open.
bin/prtend --help
# → exit 0, includes 'pr-open' in the subcommand list

# Happy path against a sandbox repo (branch with no PR, on remote or not).
bin/prtend pr-open --title "Sandbox PR" --draft --optional-reviewer "$some_login" | jq .
# → JSON: pr (integer), action ∈ {created, created_existing_branch},
#    url, state == "draft", reviewers_requested non-empty, reviewers_skipped == []

# Idempotent re-invocation.
bin/prtend pr-open --title "Sandbox PR" --draft --optional-reviewer "$some_login" | jq .action
# → "used_existing"

# Closed-PR refusal (close the PR manually first, then re-invoke).
bin/prtend pr-open --title "Sandbox PR"; echo "exit=$?"
# → "prtend: branch '<branch>' has a closed/merged PR (#N); ..." on stderr; exit=4

# Default-branch refusal.
git checkout main && bin/prtend pr-open --title "x"; echo "exit=$?"
# → "prtend: refusing to open a PR from the default branch ('main')"; exit=2

# Missing --title.
bin/prtend pr-open; echo "exit=$?"
# → usage error on stderr; exit=2

# Mocked tests pass.
make test    # or `bats test/pr_open.bats`, whichever harness landed
# → all cases green
```

## Done

- [ ] `lib/prtend/prtend-subcommands/pr_open.bash` defines `prtend_cmd_pr_open` and emits the contract JSON
- [ ] `prtend_forge_pr_create`, `prtend_forge_pr_url`, `prtend_forge_reviewer_add` (with `_gh`/`_gl` privates) added to `prtend-forge-lib.bash`
- [ ] `prtend_config_list_get` added to `prtend-lib.bash` and used to read `system_reviewers`
- [ ] All six contract fields (`pr`, `action`, `url`, `state`, `reviewers_requested`, `reviewers_skipped`) populated per declared type; arrays are arrays even when empty
- [ ] All four `action` values reachable per the decision table; idempotent re-invocation reports `used_existing`
- [ ] Exit codes 0/2/3/4 behave per `cli-contract.md` § "`prtend pr-open`"; exit 1 reserved for git/forge runtime failures (push, create)
- [ ] Default-branch invocation refused with exit 2
- [ ] Diverged-branch invocation refused with exit 1 and a clear "push manually" stderr message
- [ ] GitLab `reviewer_add` is additive across `glab` versions (reads current reviewers, appends, replays the full list)
- [ ] `shellcheck` clean on the new file and the modified libs
- [ ] Test cases for: created / created_existing_branch / used_existing / pushed_existing_pr / closed / merged / ambiguous / default-branch / not-authed / reviewer-rejected / draft / diverged / missing-title / multiple-optional-reviewers
- [ ] One commit on a feature branch: `feat(pr-open): add pr-open subcommand (step 08)`
