# Step 04 — Forge lib (read-only ops)

## Context

Extend `prtend-forge-lib.bash` with the read-only operations every later subcommand will compose on: find the PR for a branch, look up PR state, snapshot CI, list new review batches, list the comments in a batch, fetch a single comment body. Still no subcommands wired in — this step just grows the lib surface. See `../forge-mapping.md` § "Operation mapping" and `../repo-bootstrap.md` § "Forge abstraction".

These six operations cover everything the skill needs to *observe* a PR; mutations (push, create, post reply, add reviewer) land in step 09.

## Prerequisites

- Step 03 (`forge-detect`) complete — `prtend_forge_detect`, `prtend_forge_cli_ready`, `prtend_forge_dispatch`, `prtend_forge_current_branch` exist; the `_prtend_forge_<gh|gl>_<suffix>` naming + dispatch pattern is established.

Required on the host for smoke tests: the forge CLI matching the checkout you're testing against (`gh` or `glab`), authenticated, plus a real PR/MR you can hit for `pr_for_branch` / `pr_state`. CI and review reads can be exercised against any PR that has at least one check and one submitted review batch; if no such PR is handy, use fixtures (see Verification).

## Goal

After this step, `prtend-forge-lib.bash` defines six new public functions, each dispatched through `prtend_forge_dispatch`, each with a `_prtend_forge_gh_<suffix>` and `_prtend_forge_gl_<suffix>` private. Every public function emits the canonical JSON shape from `../forge-mapping.md`; per-forge translation is contained inside the privates:

- `prtend_forge_pr_for_branch <branch>` — print PR number on stdout (exit 0), or empty + exit 1 (none), or empty + exit 2 (multiple).
- `prtend_forge_pr_state <pr>` — print `{"state": "..."}` JSON; normalised values `open` / `closed` / `merged` / `draft`.
- `prtend_forge_ci_status <pr>` — print `{"state": ..., "checks": [...]}` JSON (no `failures` — that detail belongs to a step-07 fetcher, not the snapshot).
- `prtend_forge_reviews_since <pr> <cursor>` — print `{"batches": [...], "next_cursor": ...}` JSON. Cursor is opaque per forge.
- `prtend_forge_review_comments <pr> <batch-id>` — print `{"comments": [...]}` JSON.
- `prtend_forge_comment_body <pr> <comment-id>` — print raw body text on stdout (no JSON wrapper — this one is plain text by design, used downstream by `prtend_note_is_handled`).

No subcommand consumes these yet; step 05+ start composing them.

## Files to create or modify

- `lib/prtend/prtend-forge-lib.bash` (MODIFY — add the six public functions and twelve privates)

## Implementation

### Public function pattern

Each public function is a one-liner wrapping `prtend_forge_dispatch`. Example:

```bash
prtend_forge_pr_for_branch() {
  prtend_forge_dispatch pr_for_branch "$@"
}
```

The dispatch helper already handles the "detect on demand + route to the right private" plumbing. Don't duplicate that logic in the public wrappers.

### `pr_for_branch`

Per `../forge-mapping.md` § "Find PR for branch":

- `_prtend_forge_gh_pr_for_branch <branch>`: `gh pr list --head "$branch" --state open --json number` → parse with `jq`. Zero results → exit 1. One result → echo `.number`, exit 0. Multiple results → exit 2 (skill must refuse and surface).
- `_prtend_forge_gl_pr_for_branch <branch>`: `glab mr list --source-branch "$branch" --state opened --output json` → parse with `jq`. Filter to entries where `target_project_id` matches the current project (avoid fork PRs being counted). Same 0/1/many exit semantics.

The "multiple PRs" case is exit 2 because it's data-shaped: there's nothing the lib can do — only the user can decide which PR is canonical. Step 11's `doctor` may eventually surface this as an explicit check; for now the exit code is enough.

### `pr_state`

Per `../forge-mapping.md` § "PR state":

- `_prtend_forge_gh_pr_state <pr>`: `gh pr view "$pr" --json state,isDraft` → jq normalisation:
  - `state == "OPEN" && isDraft` → `"draft"`
  - `state == "OPEN"` → `"open"`
  - `state == "MERGED"` → `"merged"`
  - `state == "CLOSED"` → `"closed"`
- `_prtend_forge_gl_pr_state <pr>`: `glab mr view "$pr" --output json` → jq normalisation:
  - `state == "opened" && draft` → `"draft"`
  - `state == "opened"` → `"open"`
  - `state == "merged"` → `"merged"`
  - `state == "closed"` or `"locked"` → `"closed"`

Emit a single-line JSON object `{"state":"open"}` etc.

### `ci_status`

Per `../forge-mapping.md` § "CI status snapshot":

- `_prtend_forge_gh_ci_status <pr>`: `gh pr checks "$pr" --json name,state,conclusion,link` → jq transform. Aggregate state: `failure` if any check failed, else `running` if any running, else `pending` if none started, else `success`. Per-check shape: `{name, state, conclusion, url}` (rename `link`→`url`).
- `_prtend_forge_gl_ci_status <pr>`: two-step — `glab mr view "$pr" --output json` to resolve `head_pipeline.id`, then `glab ci status --pipeline <id> --output json`. Map pipeline `status` directly: `failed`→`failure`, `success`→`success`, `running`→`running`, `pending`→`pending`, `canceled`→`cancelled`. Per-job shape: `{name, state, conclusion, url}`.

Both privates emit the canonical shape from `../forge-mapping.md`:

```json
{"state":"failure","checks":[{"name":"...","state":"...","conclusion":"...","url":"..."}]}
```

If the PR has no pipeline yet (push hasn't triggered CI), emit `{"state":"pending","checks":[]}` and exit 0 — "no CI yet" is a valid observation, not an error.

### `reviews_since`

Per `../forge-mapping.md` § "Reviews / discussions since cursor":

- `_prtend_forge_gh_reviews_since <pr> <cursor>`: `gh api repos/{owner}/{repo}/pulls/<pr>/reviews --paginate`. The `{owner}/{repo}` interpolation comes from `gh repo view --json nameWithOwner -q .nameWithOwner` (cache in a local var — one call per invocation). Filter to reviews with `id > cursor` (treat empty cursor as "all"). Sort by `submitted_at`. Emit batches with `batch_id` = review ID stringified.
- `_prtend_forge_gl_reviews_since <pr> <cursor>`: `glab api projects/:id/merge_requests/<pr>/discussions --paginate`. Project ID from `glab repo view --output json -F id` (or equivalent). Filter to discussions where every note's `created_at > cursor` AND the discussion has settled (no new notes within `PRTEND_QUIET_WINDOW` seconds, default 60). Sort by max note `created_at`. Emit batches with `batch_id` = discussion ID.

Canonical batch shape per forge:

```json
{
  "batch_id": "...",
  "submitted_at": "2026-05-31T19:48:13Z",
  "author": "alice",
  "state": "changes_requested" | "approved" | "commented",
  "comment_ids": ["..."]
}
```

`next_cursor` is the largest `id` (gh) or latest settled-note `created_at` (gl) seen in this call. If no new batches, `next_cursor` is the input cursor unchanged. Emit:

```json
{"batches":[...],"next_cursor":"..."}
```

The quiet-window logic is genuinely tricky — see `../forge-mapping.md` § "What doesn't map cleanly" item 1. Implement it but keep it isolated in a `_prtend_forge_gl_discussion_settled` helper; step 05's reviews-poll subcommand will lean on it.

### `review_comments`

Per `../forge-mapping.md` § "Comments in a review batch":

- `_prtend_forge_gh_review_comments <pr> <review-id>`: `gh api repos/{owner}/{repo}/pulls/<pr>/reviews/<review-id>/comments`. Transform each comment to canonical shape.
- `_prtend_forge_gl_review_comments <pr> <discussion-id>`: fetch the single discussion `glab api projects/:id/merge_requests/<pr>/discussions/<discussion-id>` and project its notes. Filter out system notes (`system: true`).

Canonical comment shape:

```json
{
  "comment_id": "...",
  "author": "...",
  "body": "...",
  "path": "...",
  "line": 42,
  "anchor_stale": false,
  "created_at": "..."
}
```

`anchor_stale` is computed downstream against current HEAD by the reviews-poll subcommand (step 07), not here — emit `false` from the lib and let the caller overwrite. Document the field in a comment so future-you doesn't try to compute it twice.

Emit:

```json
{"comments":[...]}
```

### `comment_body`

Per `../forge-mapping.md` § "Single comment body (for marker detection)":

- `_prtend_forge_gh_comment_body <pr> <comment-id>`: `gh api repos/{owner}/{repo}/pulls/comments/<comment-id> --jq .body`
- `_prtend_forge_gl_comment_body <pr> <note-id>`: `glab api projects/:id/merge_requests/<pr>/notes/<note-id> --jq .body`

Echo the raw body to stdout — **no JSON wrapper**. This function exists so `prtend_note_is_handled` can `grep` for the marker; wrapping it in JSON would force every caller to re-parse.

### Key decisions

- **Read-only only.** No `push_branch`, `pr_create`, `add_reviewer`, or `post_review_reply` here — those are step 09. Resist temptation; keep the diff focused.
- **Canonical JSON shapes are normative.** Per-forge translation lives entirely in the privates. If you find yourself reaching for a `jq` filter in a public wrapper, stop and push it down into the private.
- **`comment_body` is the deliberate exception.** Plain text, not JSON. Documented in `../forge-mapping.md` and `../cli-contract.md`; don't "fix" it by wrapping.
- **`anchor_stale` is not computed here.** The lib doesn't know about HEAD; the subcommand layer does. Emit `false` and let step 07 overwrite.
- **`{owner}/{repo}` and GitLab project ID lookups are per-call, not cached.** Caching across invocations means stashing in a global, which means another piece of state to invalidate. The cost of one `gh repo view` per call is negligible for the watch cadence. If profiling later shows it matters, revisit.
- **Exit codes on read errors.** Any forge API failure (network, 404, auth lapse) → propagate the CLI's exit code. Don't try to translate — `doctor` and the subcommand layer handle that.
- **`jq` is a hard dependency from this step forward.** It's already in `flake.nix` § buildInputs (step 01) and in the test matrix; no need to guard for absence. If `jq` is missing, the CLI is fundamentally broken and `doctor` should report it.

### No `bin/prtend` change

The dispatcher already sources `prtend-forge-lib.bash` (step 03). New functions are picked up automatically.

## Verification

```bash
shellcheck bin/prtend lib/prtend/prtend-lib.bash lib/prtend/prtend-forge-lib.bash
# → no output, exit 0

# Functions are defined.
bash -c '
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-forge-lib.bash
  for f in prtend_forge_pr_for_branch prtend_forge_pr_state \
           prtend_forge_ci_status prtend_forge_reviews_since \
           prtend_forge_review_comments prtend_forge_comment_body; do
    declare -F "$f" >/dev/null || { echo "missing: $f" >&2; exit 1; }
  done
  echo ok
'
# → "ok"; exit 0

# Lib still sources cleanly under a minimal PATH.
env -i PATH=/usr/bin:/bin HOME="$HOME" bash -c \
  'source lib/prtend/prtend-forge-lib.bash && declare -F prtend_forge_ci_status'
# → "prtend_forge_ci_status"; exit 0

# Smoke test against a real PR in this repo. Substitute a known-open PR number.
PR=2
bash -c "
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-forge-lib.bash
  prtend_forge_pr_for_branch step-03-forge-detect  # echoes a number or empty+exit 1
  prtend_forge_pr_state \$PR                       # {\"state\":\"merged\"} etc.
  prtend_forge_ci_status \$PR | jq -e '.state, .checks' >/dev/null
  prtend_forge_reviews_since \$PR '' | jq -e '.batches, .next_cursor' >/dev/null
"
# → JSON for each call; exit 0

# Comment body is plain text (NOT JSON).
bash -c '
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-forge-lib.bash
  body="$(prtend_forge_comment_body 2 SOME_COMMENT_ID)"
  [[ "$body" == \{* ]] && { echo "comment_body emitted JSON; expected raw text" >&2; exit 1; }
  echo "body length: ${#body}"
'
# → "body length: N"; exit 0

# Dispatcher still healthy.
bin/prtend --help
bin/prtend --version
```

If no GitLab repo is handy, the GitLab privates can be exercised by stubbing `glab` on `PATH` to read fixtures from `test/fixtures/` (the test harness lands in step 12, but ad-hoc stubs work fine for local verification — see `test/fixtures/glab-mr-list-one-open.json` once it exists). At minimum, source the lib with `PRTEND_FORGE=gitlab` set and confirm `prtend_forge_dispatch` routes to the `_gl_*` privates.

## Done

- [ ] `lib/prtend/prtend-forge-lib.bash` defines all six public functions (`pr_for_branch`, `pr_state`, `ci_status`, `reviews_since`, `review_comments`, `comment_body`) and their twelve `_prtend_forge_<gh|gl>_<suffix>` privates
- [ ] Each public function is a one-liner over `prtend_forge_dispatch` — no per-forge logic leaks out of the privates
- [ ] JSON outputs match the canonical shapes in `../forge-mapping.md` (verified by piping through `jq -e`)
- [ ] `comment_body` returns raw text, not JSON
- [ ] `pr_for_branch` exits 1 on no match, 2 on multiple matches
- [ ] `shellcheck` clean on the modified lib and unchanged dispatcher
- [ ] Lib sources without side effects under a minimal `PATH` (regression check from step 03 still holds)
- [ ] One commit on a feature branch: `feat(forge): add read-only forge operations`
