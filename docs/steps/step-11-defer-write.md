# Step 11 — `prtend defer-write` subcommand

## Context

Wire the defer-document writer. `prtend defer-write` is what the skill calls when the user (via the Ask flow) chooses **Defer** on a review comment: it fetches the comment's full context from the forge, captures a code snippet from current HEAD, writes a Markdown doc with YAML frontmatter to `<config-dir>/deferred/<pr>-<comment-id>.md`, and emits a contract JSON pointing at the file. It does **not** post the resolution note — that's a separate `note-post --kind defer --doc PATH` call by the skill.

This step composes the read-only forge surface from step 04 (we need comment author, body, path, line) and the atomic-write + config-resolution helpers from step 02. It introduces one new forge operation — `comment_info` — because today's forge-lib has `comment_body` (body only) and `review_comments` (requires a review id), and neither produces the full single-comment context that the defer doc needs.

See `../cli-contract.md` § "`prtend defer-write`" for the output contract and exit-code table, `../overview.md` § "Defer documents" for the doc body shape and rationale, and `../forge-mapping.md` § "Single comment body (for marker detection)" for the per-forge endpoints we extend to return full metadata.

## Prerequisites

- Step 02 (`dispatcher`) complete — `bin/prtend` already routes `defer-write` to `lib/prtend/prtend-subcommands/defer_write.bash` and calls `prtend_cmd_defer_write`; `prtend_atomic_write`, `prtend_config_resolve`, and `prtend_repo_slug` are available.
- Step 04 (`forge-read`) complete — `prtend_forge_comment_body` exists and the per-forge `_prtend_forge_<gh|gl>_comment_body` privates serve as the pattern for `comment_info`.
- Step 08 (`pr-open`) complete — establishes the "subcommand + adjacent forge addition" bundling pattern and the `prtend_forge_pr_url` we reuse to build the comment permalink.
- Step 10 (`note-post`) complete — defines the dispatch / private / contract-JSON shape conventions we follow exactly here; `defer-write` will eventually be followed by a `note-post --kind defer --doc PATH` call, so the two stay shape-compatible.

Required on the host for smoke tests: the forge CLI matching the checkout (`gh` or `glab`), authenticated, a sandbox PR with at least one review comment (inline against a file path that exists at HEAD so the snippet extraction has something to chew on), and the comment id you can pass to `--comment`. For idempotency testing run the subcommand twice against the same `(pr, comment)`.

## Goal

After this step:

- `bin/prtend defer-write --pr N --comment C --reason "<text>"` fetches the comment, writes the Markdown doc, emits the canonical JSON from `../cli-contract.md` § "`prtend defer-write`" on stdout, and exits 0.
- The doc lives at `<config-dir>/deferred/<pr>-<comment-id>.md` where `<config-dir>` is `dirname` of `prtend_config_resolve`. If no config has been written yet (resolution chain returns empty), exit 4 with a clear stderr — `defer-write` is not the place to silently create a config dir.
- The doc body matches the structure in `../overview.md` § "Defer documents" exactly: YAML frontmatter (`pr`, `comment_id`, `forge`, `deferred_at`, `reason`), a heading, then **Comment location**, **Reviewer**, **Original comment**, **Code in question**, **Reason for deferral**, **Comment link** sections.
- A second invocation against the same `(pr, comment)` returns the existing path with exit 0 — no overwrite. The contract calls this out explicitly: "Existing files are not overwritten; re-calling for the same `(pr, comment)` returns the existing path with exit 0."
- `prtend-forge-lib.bash` exposes `prtend_forge_comment_info <pr> <comment_id>` returning a canonical JSON object on stdout — wired to `_prtend_forge_gh_comment_info` and `_prtend_forge_gl_comment_info` via `prtend_forge_dispatch`. Shape:

  ```json
  {
    "comment_id": "456789",
    "author": "alice",
    "body": "<raw markdown body>",
    "path": "src/widget.ts",
    "line": 42,
    "url": "https://github.com/owner/repo/pull/123#discussion_r456789",
    "created_at": "2026-05-31T19:48:13Z"
  }
  ```

  Fields are always strings except `line` (integer or `null` when the comment is non-inline).

## Files to create or modify

- `lib/prtend/prtend-subcommands/defer_write.bash` (NEW)
- `lib/prtend/prtend-forge-lib.bash` (MODIFY) — add `prtend_forge_comment_info` and its two privates
- `test/fixtures/defer_write/` (NEW) — fixture directory; specific files listed below
- `test/test-defer-write.sh` (NEW) — match the harness style step 08/10 landed (`test/test-note-post.sh`, `test/test-pr-open.sh`)

## Implementation

### `lib/prtend/prtend-subcommands/defer_write.bash`

Public surface:

```bash
prtend_cmd_defer_write "$@"   # parses flags, writes the doc, emits JSON, returns documented exit codes
```

Flag parsing (every value-bearing flag must reject empty and dash-leading values, same convention as `note-post --reason` and `pr-open --title`):

- `--pr N` — required; must match `^[0-9]+$`. Exit 2 otherwise.
- `--comment C` — required; non-empty; reject dash-leading. Opaque to both forges — do not regex-constrain the shape.
- `--reason TEXT` — required; non-empty; reject dash-leading. This is the user's free-text rationale for deferral and lands verbatim in the doc frontmatter and the **Reason for deferral** section.
- Anything else → exit 2 with a usage error on stderr.

Composition (in this order):

1. **Git repo + readiness gate.** `git rev-parse --git-dir` or exit 1 with `prtend: not in a git repository`. Then `prtend_forge_cli_ready`: propagate exit 1/3 verbatim. `defer-write` needs the forge online — there is no offline path because the comment metadata comes from the forge.

2. **Resolve the config dir.** Call `prtend_config_resolve` and capture stdout. If empty, exit 4 with `prtend: no active config; run 'prtend config init' before defer-write` on stderr. Compute `config_dir="$(dirname "$config_path")"` and `defer_dir="$config_dir/deferred"`. Compute the target path `doc_path="$defer_dir/${pr}-${comment_id}.md"`.

3. **Idempotency probe.** If `doc_path` already exists, skip composition entirely; jump to the JSON-emission step using the existing path. This matches the contract's "re-calling for the same `(pr, comment)` returns the existing path with exit 0." Re-fetching the comment to populate `comment_url` for the JSON is **still required** here — the file alone doesn't carry it in a form we can cheaply extract. (See "Key decisions" for why we don't re-parse the existing file.)

4. **Fetch comment info.** Call `prtend_forge_comment_info "$pr" "$comment_id"` and capture stdout (canonical JSON). Handle exits:
   - exit 0 → continue.
   - exit 1 → comment not found; exit 4 with `prtend: comment <id> not found on PR <pr>` on stderr; no JSON.
   - exit 3 → CLI broken / not authed; propagate.
   - exit ≥2 → propagate as exit 1.

5. **Extract a code snippet.** From the info JSON, read `path` and `line`. If `path` is non-empty AND `line` is non-null AND the file exists at `path` in the working tree, capture lines `max(1, line-3) .. line+3` from the file (so ~7 lines total, centered on the comment anchor). Otherwise the snippet section reads `<no snippet available — comment is not inline or path is not present in current HEAD>`. Do not run `git show` — use the working-tree file. This keeps the snippet matching what the agent sees in its editor; the comment-link URL covers the "what did the reviewer actually see" need.

6. **Assemble the doc.** Build the body in-memory (a single string) following the template in `../overview.md` § "Defer documents" exactly. Substitution points:
   - frontmatter `pr:` ← `--pr`
   - frontmatter `comment_id:` ← `--comment`
   - frontmatter `forge:` ← `prtend_forge_detect` (the same `github`/`gitlab` value used elsewhere)
   - frontmatter `deferred_at:` ← `date -u +%Y-%m-%dT%H:%M:%SZ` (ISO-8601 in UTC; matches the timestamp format already used by `prtend_state_lib`)
   - frontmatter `reason:` ← `--reason` (single-line — if the user passes multi-line text the embedded newlines break frontmatter; emit a clear exit-2 error if `--reason` contains a newline rather than silently flattening or escaping)
   - body `## Comment location` ← `\`<path>:<line>\`` or `\`<path>\`` if `line` is null
   - body `## Reviewer` ← `@<author>`
   - body `## Original comment` ← blockquote of every line of `body` (prepend `> ` to each line; preserve internal blank lines as `>`)
   - body `## Code in question` ← fenced block with no language tag (the file's actual language is unknown to the lib); inside, the captured snippet lines verbatim
   - body `## Reason for deferral` ← `--reason`
   - body `## Comment link` ← the `url` field from `prtend_forge_comment_info`

7. **Write the doc** via `prtend_atomic_write "$doc_path"`. The atomic-write helper creates the parent directory if missing, which handles the first-ever-`deferred/` case for free. Capture its exit code and propagate exit 1 on failure (with the helper's stderr surfaced unmodified).

8. **Emit JSON on stdout** via `jq -c -n`, matching the field order from `cli-contract.md`:

   ```json
   {
     "path": "<absolute path to the doc>",
     "pr": <integer pr>,
     "comment_id": "<from --comment, as a string>",
     "comment_url": "<from prtend_forge_comment_info>"
   }
   ```

   Yes, `pr` is an integer here per the contract example; `comment_id` is a string. Don't normalize one to match the other — the contract is explicit.

### `prtend-forge-lib.bash` additions

One public function plus two privates. Same one-liner dispatch pattern as `comment_body` / `pr_url` / `post_review_reply`.

`prtend_forge_comment_info <pr> <comment_id>` echoes the canonical JSON object (see Goal section for the shape) on stdout. Exit 0 on success, exit 1 if the comment doesn't exist on the PR/MR, exit ≥2 on argument/usage errors.

- `_prtend_forge_gh_comment_info <pr> <comment_id>`:
  - Validate `pr` matches `^[0-9]+$` and `comment_id` is non-empty.
  - Resolve `slug="$(_prtend_forge_gh_repo_slug)"`.
  - Invoke `gh api "repos/${slug}/pulls/comments/${comment_id}"` (the same endpoint `_prtend_forge_gh_comment_body` uses, but full payload, not `--jq .body`). On `gh` non-zero, exit 1 — the dominant cause is comment-not-found and the GitHub stderr already says so.
  - Pipe through `jq -c` projecting to the canonical shape:
    ```jq
    {
      comment_id:   (.id | tostring),
      author:       (.user.login // ""),
      body:         (.body // ""),
      path:         (.path // ""),
      line:         (.line // .original_line // .start_line // null),
      url:          (.html_url // ""),
      created_at:   (.created_at // "")
    }
    ```
  - Note: `pr` is unused on the GitHub side because the comments endpoint is PR-independent (the `comment_id` is globally unique within the repo). Accept it in the signature for parity with the GitLab path; document this with a `: "${pr:-}"` no-op consistent with `_prtend_forge_gh_comment_body`'s style.

- `_prtend_forge_gl_comment_info <pr> <comment_id>`:
  - Validate `pr` matches `^[0-9]+$` and `comment_id` is non-empty.
  - Resolve `project_id="$(_prtend_forge_gl_project_id)"`.
  - Invoke `glab api "projects/${project_id}/merge_requests/${pr}/notes/${comment_id}"`. On non-zero exit, return 1.
  - Pipe through `jq -c`:
    ```jq
    {
      comment_id:   (.id | tostring),
      author:       (.author.username // ""),
      body:         (.body // ""),
      path:         (.position.new_path // ""),
      line:         (.position.new_line // null),
      url:          (.web_url // ""),
      created_at:   (.created_at // "")
    }
    ```
  - The GitLab MR notes endpoint returns a single note with the inline position embedded under `position`. For non-inline notes the `position` field is `null` and the jq projection naturally degrades `path` to `""` and `line` to `null` — the subcommand's snippet step is already prepared for this.

A code comment near both privates should point at `../docs/forge-mapping.md` § "Single comment body (for marker detection)" — that's the canonical mapping; this function is the structured cousin of the body-only call.

### Key decisions

- **No re-parse of the existing defer doc on idempotent re-call.** Step 3 above bypasses the renderer when the file already exists, but step 4 still calls `prtend_forge_comment_info` to populate `comment_url` for the response JSON. The alternative — parse the existing file's `## Comment link` section — couples the parser to the renderer's exact heading and is fragile against future template edits. One forge round-trip on an idempotent call is cheap; a brittle parser is not.
- **`deferred_at` is the time of *this* write, not the time of the deferred-on event.** If the user re-runs `defer-write` against an existing doc, the timestamp on disk does not get bumped. The JSON response also reports the existing path — the deferred event is durably anchored to its first invocation.
- **The doc is the source of truth for the defer record, not state.** No state-lib mutation here. Defer is intentionally outside the per-PR state-file machinery — the docs survive PR close, branch deletion, machine moves (per `../overview.md` § "Defer documents"), and folding them into the JSON state file would tie their lifetime to the PR's. Don't be tempted to add a `prtend_state_record_defer` call.
- **No `--force` flag.** Idempotency is the contract. If the user needs to regenerate a doc (template change, code moved), they delete the file and re-run. Adding `--force` invites accidental overwrites and obscures the "I already deferred this" signal.
- **No `--out PATH` flag.** Path is derived from `<config-dir>/deferred/<pr>-<comment-id>.md` deterministically. Letting the caller override it splits the discovery contract (`ls <config-dir>/deferred/` no longer lists everything) for no real win.
- **Snippet is from working tree, not the comment's original SHA.** Reviewers comment against a specific SHA but the defer doc is forward-looking: what the human will see when they come back to address it later. If `path` has been deleted or refactored since the comment was posted, the snippet section says so rather than digging through git history to reconstruct dead context. The comment-link URL preserves the original context.
- **`reason` may not contain a newline.** Multi-line free text would break YAML frontmatter without quoting and complicate the **Reason for deferral** section's formatting. Reject at parse time with exit 2 and a clear stderr — pushes the constraint up to the skill author, where it belongs.
- **Forge attribution in frontmatter is `github` / `gitlab`, not the URL host.** Matches every other prtend artifact (state files, detect output). Self-hosted GHE / GitLab Enterprise instances still report as `github` / `gitlab`.
- **`config_dir` is `dirname(prtend_config_resolve)`, not `prtend_state_dir`.** State and defer docs live in different places by design — state is ephemeral and may be in `$XDG_STATE_HOME`; defer docs are alongside config and may be in `$XDG_CONFIG_HOME` or the repo. The two helpers exist for a reason; don't conflate them.
- **Empty resolution chain is exit 4, not exit 2.** "No config exists" is a data/state condition the skill should resolve by routing to `prtend config init`, not a usage error. Exit 4 matches `cli-contract.md`'s exit-code framing ("the data prevents me from acting safely; you decide").

### Test shape

Match `test/test-note-post.sh` / `test/test-pr-open.sh` exactly. Mock `prtend_forge_dispatch` by shadowing the `_prtend_forge_gh_*` / `_prtend_forge_gl_*` privates; do not exercise real network.

Fixtures under `test/fixtures/defer_write/`:

- `comment_info.gh.inline.json` — full GH `pulls/comments/{id}` payload with `path`, `line`, `body`, `user.login`, `html_url`.
- `comment_info.gh.non_inline.json` — payload with `path: null` and no `line` fields (the rare "PR-level review comment" case).
- `comment_info.gl.inline.json` — GL `notes/{id}` payload with `position.new_path`, `position.new_line`, `body`, `author.username`, `web_url`.
- `comment_info.gl.non_inline.json` — `position: null`.
- `snippet_target.txt` — a multi-line file the subcommand reads to extract the snippet (place at a path matching the fixture's `path` value under a tmp working tree).
- `expected_doc.gh.md` — the full rendered doc body for the inline GH case; the happy-path test diffs against this byte-for-byte (with `deferred_at` substituted via a regex).

Cases (one test block each, matching step 10's granularity):

1. **Happy path GitHub inline.** Mock `comment_info` → inline fixture; snippet target exists; assert JSON shape, assert `doc_path` exists, assert body matches `expected_doc.gh.md` modulo `deferred_at`.
2. **Happy path GitLab inline.** Symmetric, with the GitLab fixture and `forge: gitlab` in frontmatter.
3. **Non-inline comment.** Mock → `path: ""`, `line: null`; assert `## Code in question` falls back to the "no snippet available" sentinel; `## Comment location` is the path-only form (or fall back further if path is also empty — render `(non-inline)` in that case).
4. **Idempotency.** Pre-create the target doc with arbitrary content; run; assert (a) file is unchanged byte-for-byte, (b) JSON points at the same path, (c) `comment_info` mock *was* invoked (for `comment_url`).
5. **Comment not found.** Mock `comment_info` → exit 1; assert exit 4 with the documented stderr; no doc written; no JSON.
6. **No config.** Mock `prtend_config_resolve` → empty; assert exit 4 with the "run `prtend config init`" stderr; no doc written.
7. **Forge not authed.** Mock `prtend_forge_cli_ready` → exit 3; assert propagate exit 3.
8. **Bad `--pr`.** `--pr abc` → exit 2.
9. **Missing `--reason`.** → exit 2.
10. **Dash-leading `--reason`.** `--reason -bogus` → exit 2.
11. **Newline in `--reason`.** Pass `$'line1\nline2'` → exit 2 with the "must not contain a newline" stderr.
12. **Snippet path missing in HEAD.** `comment_info` returns a path that doesn't exist in the working tree; assert snippet section is the sentinel, but the rest of the doc renders normally.
13. **Snippet edge cases.** Line `1` (so `max(1, line-3) == 1`); line near EOF (so the upper bound naturally clips); a one-line file. All produce a sensible snippet.
14. **Atomic write failure.** Mock `prtend_atomic_write` → exit 1; assert subcommand exits 1, no JSON, no partial file.
15. **JSON shape invariants.** Every happy-path case asserts `path` is absolute, `pr` is an integer in JSON (no quotes), `comment_id` is a string, `comment_url` is a non-empty string.

## Verification

```bash
shellcheck bin/prtend lib/prtend/prtend-lib.bash lib/prtend/prtend-forge-lib.bash lib/prtend/prtend-notes-lib.bash lib/prtend/prtend-subcommands/defer_write.bash
# → no output, exit 0

# Help still works and lists defer-write.
bin/prtend --help
# → exit 0, includes 'defer-write' in the subcommand list

# Happy path against a sandbox PR. Replace 123 / 456789 with real ids; ensure
# the commented file path exists in the working tree.
bin/prtend defer-write --pr 123 --comment 456789 --reason "Pending design review" | jq .
# → JSON: path is absolute and ends with "/deferred/123-456789.md", pr=123 (number),
#    comment_id="456789" (string), comment_url is a non-empty string starting with https.

# The file exists, contains the expected sections.
ls "$(bin/prtend config path | xargs dirname)/deferred/"
# → 123-456789.md present
head -20 "$(bin/prtend config path | xargs dirname)/deferred/123-456789.md"
# → YAML frontmatter with pr/comment_id/forge/deferred_at/reason, then "# Deferred review feedback — PR #123, comment 456789"

# Idempotent re-invocation.
bin/prtend defer-write --pr 123 --comment 456789 --reason "Pending design review" | jq -r .path
# → same path; file mtime unchanged.
stat -c %Y "$(bin/prtend config path | xargs dirname)/deferred/123-456789.md"
# (Compare before and after re-run — value is identical.)

# No-config refusal.
PRTEND_CONFIG=/nonexistent bin/prtend defer-write --pr 123 --comment 456789 --reason "test"; echo "exit=$?"
# → "prtend: no active config; run 'prtend config init' before defer-write" on stderr; exit=4

# Newline-in-reason rejection.
bin/prtend defer-write --pr 123 --comment 456789 --reason "$(printf 'a\nb')"; echo "exit=$?"
# → "prtend: --reason must not contain a newline" on stderr; exit=2

# Composition with note-post (the intended skill flow).
P="$(bin/prtend defer-write --pr 123 --comment 456789 --reason "design review" | jq -r .path)"
bin/prtend note-post --pr 123 --comment 456789 --kind defer --doc "$P" | jq .
# → posts the resolution note referencing the doc path; exit 0.

# Mocked tests pass.
./test/test-defer-write.sh
# → all cases green
```

## Done

- [ ] `lib/prtend/prtend-subcommands/defer_write.bash` defines `prtend_cmd_defer_write` and emits the contract JSON
- [ ] `prtend_forge_comment_info` (with `_gh` / `_gl` privates) added to `prtend-forge-lib.bash`, dispatching via `prtend_forge_dispatch`
- [ ] Doc body matches `../overview.md` § "Defer documents" exactly (frontmatter + six body sections, in that order)
- [ ] Doc path is `<dirname(prtend_config_resolve)>/deferred/<pr>-<comment-id>.md`; empty config-resolution exits 4 with the documented stderr
- [ ] Idempotent re-invocation returns the existing path with exit 0 and does not overwrite the file
- [ ] Comment-not-found returns exit 4 with the documented stderr; no doc is written, no JSON emitted
- [ ] Snippet is from the working tree (`path` + `line ± 3`); falls back to a sentinel when path is missing, line is null, or path is non-existent in HEAD
- [ ] `--reason` rejects empty, dash-leading, and newline-containing values at parse time with exit 2
- [ ] JSON shape: `path` absolute string, `pr` integer, `comment_id` string, `comment_url` string — matches the `cli-contract.md` example verbatim
- [ ] `shellcheck` clean on the new file and the modified forge lib
- [ ] Test cases for: happy path (gh + gl), non-inline, idempotency, comment-not-found, no-config, not-authed, each parse-error mode, missing-path snippet fallback, snippet line-1 / near-EOF edges, atomic-write failure, JSON shape invariants
- [ ] One commit on a feature branch: `feat(defer-write): add defer-write subcommand (step 11)`
