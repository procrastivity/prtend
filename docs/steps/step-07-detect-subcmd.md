# Step 07 — `prtend detect` subcommand

## Context

Wire the first user-facing subcommand. `prtend detect` is the skill's mandatory first call on every invocation: it tells the skill which forge, which branch, whether a PR exists, what state it's in, whether the user is on the default branch (skip the watch flow), and which remote to push to. All of the underlying observations already exist in `prtend-forge-lib.bash` after step 04; this step composes them into the canonical JSON shape and adds the two small primitives the lib is still missing (default-branch + active-remote). See `../cli-contract.md` § "`prtend detect`" for the exact output contract.

This is also the step that establishes how subcommands are structured under `lib/prtend/prtend-subcommands/`: a single `detect.bash` file defining `prtend_cmd_detect`, sourced on demand by `bin/prtend` (the dispatcher case already lists `detect`). Later subcommand steps follow the same pattern.

## Prerequisites

- Step 03 (`forge-detect`) complete — `prtend_forge_detect`, `prtend_forge_cli_ready`, `prtend_forge_current_branch` exist.
- Step 04 (`forge-read`) complete — `prtend_forge_pr_for_branch` and `prtend_forge_pr_state` exist and emit the documented shapes.
- Step 02 (`dispatcher`) complete — `bin/prtend` routes `detect` to `lib/prtend/prtend-subcommands/detect.bash` and calls `prtend_cmd_detect`.

Required on the host for smoke tests: the forge CLI matching the checkout (`gh` or `glab`), authenticated, against a repo that has at least one branch with an open PR. The "no PR" path can be exercised on any branch without a PR; the "default branch" path on `main` (or wherever `refs/remotes/<remote>/HEAD` points).

## Goal

After this step:

- `lib/prtend/prtend-subcommands/detect.bash` exists and defines `prtend_cmd_detect`.
- `prtend detect` prints the JSON object documented in `cli-contract.md` § "`prtend detect`" (single line, compact) with every field populated per its declared type.
- `prtend detect --branch BRANCH` overrides the branch lookup; `--no-cache` forces re-detection (unsets `$PRTEND_FORGE` for the call).
- `prtend detect` exits 0 on success (including `forge: null` and `pr: null`), 1 if not in a git repo, 2 on bad flags, 4 if `prtend_forge_pr_for_branch` returns "ambiguous" (multiple open PRs match).
- `prtend-forge-lib.bash` gains two small helpers needed by `detect` and reused later: `prtend_forge_default_branch` and `prtend_forge_active_remote`. Both follow the existing `_prtend_forge_<gh|gl>_<suffix>` dispatch pattern.
- A focused test fixture + script under `test/` exercises the subcommand against a mocked forge dispatch. No real network calls in tests.

## Files to create or modify

- `lib/prtend/prtend-subcommands/detect.bash` (NEW)
- `lib/prtend/prtend-forge-lib.bash` (MODIFY — add `prtend_forge_default_branch`, `prtend_forge_active_remote`, and their `_gh`/`_gl` privates)
- `test/detect.bats` or `test/detect.sh` (NEW — see Verification for shape; pick whichever harness style matches what later steps will reuse)
- `test/fixtures/detect/` (NEW — small JSON fixtures used by the mocked dispatch)

## Implementation

### `lib/prtend/prtend-subcommands/detect.bash`

Public surface:

```bash
prtend_cmd_detect "$@"   # parses flags, emits JSON, returns documented exit codes
```

Flag parsing:

- `--no-cache` — clear `PRTEND_FORGE` for the call (do not `unset` the caller's environment beyond the function scope; use a local `PRTEND_FORGE=""` before dispatching).
- `--branch BRANCH` — use `BRANCH` instead of `prtend_forge_current_branch`. Validate the value is non-empty and does not start with `-` (catches `--branch --no-cache` style mistakes); exit 2 with a usage error otherwise.
- Anything else → exit 2 with a usage error on stderr.

Composition (in this order, so error mapping stays obvious):

1. Verify git repo: `git rev-parse --git-dir >/dev/null 2>&1` or exit 1 with `prtend: not in a git repository` on stderr. Do this before any forge probing so the error is precise.
2. Resolve branch: `--branch` value if given, else `prtend_forge_current_branch`.
3. Resolve forge: call `prtend_forge_detect`. Capture stdout. If it exits 1 (no forge), set `forge=null` and skip PR lookups; if it exits 2 (bad `$PRTEND_FORGE` override), propagate exit 2.
4. Resolve remote: `prtend_forge_active_remote`. Always returns a name (defaults to `origin` when no upstream is set).
5. Resolve default-branch flag: compare `branch` to `prtend_forge_default_branch` output. If `default_branch` lookup fails (no remote HEAD, detached checkout under test), set `is_default_branch=false` — don't fail the command; the skill needs the rest of the answer.
6. Resolve PR + state (only if `forge != null`):
   - `pr=$(prtend_forge_pr_for_branch "$branch")`. Map exit 1 → `pr=null`, `pr_state=null`. Map exit 2 → exit the subcommand with code 4 (ambiguous; skill must refuse). Map exit 0 → continue.
   - `pr_state=$(prtend_forge_pr_state "$pr" | jq -r .state)` (or however the rest of the codebase extracts a field — match existing style). Treat any non-zero from `pr_state` as a hard error (exit 3, "forge call failed") — by the time we're here the CLI is authed and the PR exists; failing here is real.
7. Emit JSON on stdout via `jq -c -n --arg ... '{...}'` (compact, single line). The contract field order is suggestive only; `jq -n` will produce stable ordering by key — match the documented example by constructing the object with explicit keys in the contract's order.

### `prtend-forge-lib.bash` additions

`prtend_forge_default_branch` — prints the repo's default branch name (e.g. `main`), exit 0. Empty + exit 1 if the forge can't tell us.

- `_prtend_forge_gh_default_branch`: `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.
- `_prtend_forge_gl_default_branch`: `glab repo view --output json | jq -r .default_branch` (verify exact field name against the `glab` version in `flake.nix` before committing; `forge-mapping.md` § "Repo metadata" is the source of truth).

`prtend_forge_active_remote` — prints the active remote name (the one PRs/MRs go to), exit 0. Algorithm:

1. If the current branch has an upstream (`git rev-parse --abbrev-ref --symbolic-full-name @{u}` succeeds), take its remote prefix (everything before the first `/`).
2. Otherwise, if `origin` exists (`git remote get-url origin` succeeds), use `origin`.
3. Otherwise, print the first remote from `git remote` (deterministic via `sort`).
4. If no remotes at all, empty + exit 1.

This one is forge-agnostic — no per-CLI privates needed. Define it next to the others for discoverability, not as a dispatched function.

### Key decisions

- **`is_default_branch` is best-effort.** A non-cloned checkout (or one without `refs/remotes/<remote>/HEAD` set) shouldn't make `detect` fail; the skill treats unknown as "not default" which is the safer assumption (it will still run the watch flow).
- **`--no-cache` is scoped to the call.** Detect is the one place that re-probes, but we don't want to clobber the caller's env. A local `PRTEND_FORGE=""` (or `unset -v PRTEND_FORGE` inside the function body) is enough.
- **No JSON assembly by string concatenation.** Use `jq -n` — `branch` names can contain characters that need escaping (`feature/foo "bar"` is uncommon but legal).
- **Exit code 4 is reserved for ambiguous PRs.** Don't repurpose it for other ambiguities; the skill keys off it specifically (see `skill-prompts.md` § "Detect → ambiguous PR").
- **No call to `prtend_forge_cli_ready` here.** `detect` is called *before* readiness gating in the skill flow; if `gh`/`glab` is missing, the forge probe will fall through to URL sniffing (step 03) and PR lookup will emit `pr=null`. `doctor` is where readiness is reported.

### Test shape

Mock `prtend_forge_dispatch` (or shadow the `_prtend_forge_gh_*` privates) with fixtures under `test/fixtures/detect/`:

- `pr_for_branch.open.txt` → `123\n`, exit 0
- `pr_for_branch.none.txt` → empty, exit 1
- `pr_for_branch.ambiguous.txt` → empty, exit 2
- `pr_state.open.json` → `{"state":"open"}`
- `pr_state.draft.json` → `{"state":"draft"}`
- `default_branch.main.txt` → `main\n`

Cases to cover:

1. Happy path: open PR on a feature branch → `pr` and `pr_state` populated, `is_default_branch=false`.
2. No PR: branch without a PR → `pr=null`, `pr_state=null`, exit 0.
3. Default branch: branch equals `prtend_forge_default_branch` → `is_default_branch=true`.
4. Ambiguous: dispatch returns exit 2 → subcommand exits 4.
5. No forge: `prtend_forge_detect` exit 1 → `forge=null`, `pr=null`, `pr_state=null`, exit 0.
6. Not a git repo: run from `/tmp` → exit 1 with the documented stderr message.
7. Bad flag: `--branch` with no value → exit 2.

Pick a harness style (bats vs plain bash with a `run_test` helper) that the next subcommand step (08 `watch-primitives`) will reuse — whichever lands here sets the convention.

## Verification

```bash
shellcheck bin/prtend lib/prtend/prtend-lib.bash lib/prtend/prtend-forge-lib.bash lib/prtend/prtend-subcommands/detect.bash
# → no output, exit 0

# Help still works.
bin/prtend --help
# → exit 0, includes 'detect' in the subcommand list

# Happy path against a real PR (substitute a branch that has an open PR in this repo).
bin/prtend detect --branch <branch-with-pr> | jq .
# → JSON with forge, branch, pr (integer), pr_state ("open"/"draft"/...), is_default_branch (false), remote

# No PR path.
bin/prtend detect --branch <branch-without-pr> | jq .
# → pr: null, pr_state: null, exit 0

# Default branch path.
bin/prtend detect --branch "$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's|origin/||')" | jq .
# → is_default_branch: true

# Not in a git repo.
( cd /tmp && bin/prtend detect ) ; echo "exit=$?"
# → "prtend: not in a git repository" on stderr; exit=1

# Bad flag.
bin/prtend detect --branch ; echo "exit=$?"
# → usage error on stderr; exit=2

# Mocked tests pass.
make test    # or `bats test/detect.bats`, whichever harness landed
# → all cases green
```

## Done

- [ ] `lib/prtend/prtend-subcommands/detect.bash` defines `prtend_cmd_detect` and emits the contract JSON
- [ ] `prtend_forge_default_branch` (with `_gh`/`_gl` privates) and `prtend_forge_active_remote` added to `prtend-forge-lib.bash`
- [ ] All six contract fields (`forge`, `branch`, `pr`, `pr_state`, `is_default_branch`, `remote`) populated per declared type, with `null`s where documented
- [ ] Exit codes 0/1/2/4 behave per `cli-contract.md` § "`prtend detect`"
- [ ] `--no-cache` and `--branch BRANCH` flags work; bad flags exit 2 with a usage error
- [ ] `shellcheck` clean on the new file and the modified forge lib
- [ ] Test cases for: happy path, no PR, default branch, ambiguous, no forge, not-a-git-repo, bad flag
- [ ] One commit on a feature branch: `feat(detect): add detect subcommand (step 07)`
