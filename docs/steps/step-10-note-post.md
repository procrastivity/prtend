# Step 10 — `prtend note-post` subcommand

## Context

Wire the resolution-note writer. `prtend note-post` is what the skill calls after deciding how to handle a single review comment: it composes the appropriate body via `prtend-notes-lib.bash`, posts it as a reply through the forge, and emits a contract JSON with the new reply's id. It never resolves the thread — only the human does that.

This step closes the loop between the notes lib (built in step 06) and the forge mutation surface (started in step 08). Step 06 gave us marker assembly and the `prtend_note_is_handled` detector; step 08 introduced `_prtend_forge_<gh|gl>_*` mutation privates and the dispatch pattern for them. This step adds the last missing mutation — `post_review_reply` — and the subcommand that drives the whole sequence.

The inventory in `../build-steps.md` listed this work alongside `pr-open` under "step 10 — note-post-and-pr-open"; `pr-open` shipped early as its own step 08, so this step is the remaining half. Numbering stays monotonic (per the inventory's "numbers don't have to be contiguous" note); no step 09 file exists or is planned.

See `../cli-contract.md` § "`prtend note-post`" for the output contract and exit-code table, `../forge-mapping.md` § "Post reply to a review comment" for the per-forge command map, and `../overview.md` § "Resolution note" for the marker and decision-tree context.

## Prerequisites

- Step 02 (`dispatcher`) complete — `bin/prtend` already routes `note-post` to `lib/prtend/prtend-subcommands/note_post.bash` and calls `prtend_cmd_note_post`.
- Step 04 (`forge-read`) complete — `prtend_forge_comment_body` exists and is reused to detect an existing marker before posting.
- Step 06 (`notes`) complete — `prtend_note_marker`, `prtend_note_marker_version`, `prtend_note_reject`, `prtend_note_accept`, `prtend_note_halt`, `prtend_note_defer`, and `prtend_note_is_handled` exist.
- Step 08 (`pr-open`) complete — establishes the bundled "subcommand + new forge mutations" pattern this step follows, and the `prtend_forge_dispatch`-based mutation private convention.

Required on the host for smoke tests: the forge CLI matching the checkout (`gh` or `glab`), authenticated, and a sandbox PR with at least one review comment whose id you can pass to `--comment`. For idempotency testing you need a comment that has *already* been replied to by a `prtend` note (run the subcommand once, then again, to exercise exit 4 on the second invocation).

## Goal

After this step:

- `bin/prtend note-post --pr N --comment C --kind KIND <kind-specific flags>` posts a reply through the forge, emits the canonical JSON from `../cli-contract.md` § "`prtend note-post`" on stdout, and exits 0.
- All four kinds (`reject`, `accept`, `halt`, `defer`) are reachable; the kind/flag pairing rules from the contract are enforced at parse time with exit 2 on any mismatch.
- A second invocation against the same `(pr, comment)` after a `prtend` reply already exists returns exit 4 without posting again — the existing marker is detected via `prtend_forge_comment_body` + `prtend_note_is_handled`. (This is the contract's "Comment not found, or comment already has a `prtend` marker" branch.)
- `prtend-forge-lib.bash` exposes `prtend_forge_post_review_reply <pr> <comment_id>` reading the body from stdin and echoing the new reply id on stdout — wired to `_prtend_forge_gh_post_review_reply` and `_prtend_forge_gl_post_review_reply` via `prtend_forge_dispatch`.

## Files to create or modify

- `lib/prtend/prtend-subcommands/note_post.bash` (NEW)
- `lib/prtend/prtend-forge-lib.bash` (MODIFY) — add `prtend_forge_post_review_reply` and its two privates
- `test/fixtures/note_post/` (NEW) — fixture directory; specific files listed below
- `test/note_post.bats` (NEW) — or whichever test harness step 07/08 landed; match that style exactly

## Implementation

### `lib/prtend/prtend-subcommands/note_post.bash`

Public surface:

```bash
prtend_cmd_note_post "$@"   # parses flags, posts the reply, emits JSON, returns documented exit codes
```

Flag parsing (every value-bearing flag must reject empty and dash-leading values, same convention as `detect --branch` and `pr-open --title`):

- `--pr N` — required; must match `^[0-9]+$`. Exit 2 otherwise.
- `--comment C` — required; non-empty. Both forges accept opaque ids, so do not regex-constrain the format — just reject empty / dash-leading.
- `--kind KIND` — required; must be one of `reject` / `accept` / `halt` / `defer`. Anything else (including `ignore`) exits 2 with `prtend: invalid --kind '<value>' (expected reject|accept|halt|defer)` on stderr. `ignore` gets a slightly more specific message: `prtend: --kind 'ignore' is not valid for note-post (Ignore posts nothing)` — this is a common skill-side mistake worth catching loudly.
- `--reason TEXT` — required iff `--kind reject` or `--kind halt`; rejected otherwise (exit 2). Non-empty.
- `--commit HASH` — required iff `--kind accept`; rejected otherwise (exit 2). Non-empty; do not constrain to `^[0-9a-f]+$` (short hashes, signed-tag identifiers, and Mercurial-style refs are all things the skill might legitimately pass through; the notes lib treats it as opaque).
- `--doc PATH` — required iff `--kind defer`; rejected otherwise (exit 2). Non-empty.
- Anything else → exit 2 with a usage error on stderr.

Pairing enforcement is mandatory and lives entirely in the parser, not the dispatch. Build the validation as a single table-driven check after argument parsing: for each kind, define `(required_flag, forbidden_flags)` and assert each side. Mismatched pairings exit 2 with `prtend: --kind <k> requires <flag> and forbids <other-flags>` so the skill author gets one clear message instead of a chain of staged checks.

Composition (in this order):

1. **Git repo + readiness gate.** `git rev-parse --git-dir` or exit 1 with `prtend: not in a git repository`. Then `prtend_forge_cli_ready`: propagate exit 1/3 verbatim. `note-post` is a pure mutation against the forge; there is no offline path.
2. **Idempotency probe.** Call `prtend_forge_comment_body "$pr" "$comment"` and capture stdout into a variable. Handle exit codes:
   - exit 0 → run `prtend_note_is_handled "$body"`. If it returns 0 (marker present), exit 4 with `prtend: comment <id> already has a prtend marker; refusing to double-post` on stderr. Do not emit JSON.
   - exit 1 → propagate (comment not found / generic forge failure); surface the stderr from the forge unmodified, exit 4 with `prtend: comment <id> not found on PR <pr>`.
   - exit 3 → propagate (CLI broken / not authed).
   - exit ≥2 → propagate as exit 1.
3. **Render the note body.** Switch on `--kind` and call the matching renderer from `prtend-notes-lib.bash` (`prtend_note_reject "$reason"` / `prtend_note_accept "$commit"` / `prtend_note_halt "$reason"` / `prtend_note_defer "$doc"`). Each renderer already prepends the marker and emits the two-line body on stdout. Capture into a variable; do *not* re-prepend the marker.
4. **Post the reply.** Pipe the rendered body to `prtend_forge_post_review_reply "$pr" "$comment"`. Capture stdout (the new reply id). On exit ≥1 from the forge call, surface the forge stderr unmodified and exit 1 — the comment exists (we just read it) and the body validated client-side, so a failure here is genuinely a forge runtime issue (network, rate-limit, transient 5xx). Do not retry.
5. **Emit JSON on stdout** via `jq -c -n`, matching the field order from `cli-contract.md`:

   ```json
   {
     "posted": true,
     "comment_id": "<from --comment, as a string>",
     "reply_id": "<from forge>",
     "kind": "<from --kind>",
     "marker_version": "<from prtend_note_marker_version>",
     "body": "<full rendered body, including the marker line and trailing newline stripped>"
   }
   ```

   `comment_id` and `reply_id` are always strings even if numeric — the forges differ on type (GitHub returns ints for review-comment ids, GitLab returns ints for notes but uses string discussion ids that show up adjacent in the same payload). Coercing here keeps the contract consistent and matches the `cli-contract.md` example exactly.

### `prtend-forge-lib.bash` additions

One public function plus two privates. Same one-liner dispatch pattern as the existing comment_body / pr_create / reviewer_add additions.

`prtend_forge_post_review_reply <pr> <comment_id>` reads the reply body from stdin (NOT from an argument — the body may contain newlines, quotes, and shell metacharacters that are awkward to pass via argv). Echoes the new reply id on stdout (just the id, as a string). Exit 0 on success, exit 1 on forge rejection, exit ≥2 on argument/usage errors.

- `_prtend_forge_gh_post_review_reply <pr> <comment_id>`:
  - Validate `pr` matches `^[0-9]+$` and `comment_id` is non-empty.
  - Resolve `slug="$(_prtend_forge_gh_repo_slug)"`.
  - Read the body via `body="$(cat)"`. Reject empty bodies (exit 2 with `post_review_reply: refusing to post empty body`).
  - Invoke `gh api -X POST "repos/${slug}/pulls/${pr}/comments/${comment_id}/replies" -f "body=${body}" --jq .id`. `gh api` echoes the parsed `id` (a JSON number) on stdout; coerce to string by passing through `printf '%s\n'`. Exit 1 if `gh` exits non-zero; surface stderr unmodified.
- `_prtend_forge_gl_post_review_reply <pr> <comment_id>`:
  - Validate `pr` matches `^[0-9]+$` and `comment_id` is non-empty.
  - Resolve `project_id="$(_prtend_forge_gl_project_id)"`.
  - Read the body via `body="$(cat)"`. Reject empty bodies (same message as the gh path).
  - GitLab requires the *discussion id*, not the note id, to append a reply. Look it up: `discussion_id="$(glab api "projects/${project_id}/merge_requests/${pr}/discussions" --jq ".[] | select(.notes[].id == ${comment_id}) | .id" | head -n1)"`. If empty, exit 1 with `post_review_reply: no discussion contains note <comment_id> on MR <pr>` on stderr.
  - Invoke `glab api -X POST "projects/${project_id}/merge_requests/${pr}/discussions/${discussion_id}/notes" -f "body=${body}" --jq .id`. Same coercion-to-string as the gh path.

A code comment near the GitLab private should explicitly point at `../docs/forge-mapping.md` § "What doesn't map cleanly" item 2 — the discussion lookup is the entire reason `post_review_reply` is more than a one-liner on the GitLab side, and that's the canonical explanation.

### Key decisions

- **Body via stdin, not argv.** The notes-lib renderers emit two lines with a literal newline between marker and body. Passing this through argv works but invites shell-quoting bugs and breaks if the body ever grows (defer-doc paths with spaces, multiline halt reasons in a future revision). Stdin is the natural shape for "post this text"; both forge CLIs accept stdin-fed `-f body=@-`-style inputs too, but `-f body="$body"` after `body="$(cat)"` is simpler and matches the existing forge-lib idiom (single shell-escaped value).
- **Idempotency detection before body rendering.** The probe in step 2 of the composition runs *before* we compose any body, so the comment-not-found and already-handled refusals do not waste a renderer call or any stdin pipe setup. This is small but matches step 08's "compute decisions first, mutate last" structure.
- **Exit 4 is overloaded — that's the contract.** `cli-contract.md` § "`prtend note-post`" maps exit 4 to "comment not found, or comment already has a prtend marker". The two stderr messages disambiguate for the skill author; the JSON shape is omitted on both (no stdout). Do not invent a new exit code.
- **No "force re-post" flag.** The skill should never want to double-post; if it does, that's a bug in the skill's pre-call check. Adding `--force` would normalize the bug. If a future need emerges (e.g., correcting a malformed initial post), the user deletes the bad reply manually and re-runs.
- **`comment_id` and `reply_id` are strings.** The JSON contract uses string types (the example shows `"456789"` quoted). Coerce server-returned numbers via `printf '%s\n'` before stuffing into the JSON via `jq -c -n --arg`.
- **`gh api … -f body=…` is the right shape.** It properly URL-form-encodes the body so embedded backticks, newlines, and `%` signs survive the round trip. Do NOT use `--raw-field` (which skips type inference but still treats the value the same way for strings) or shell out via `gh pr comment` (which posts a top-level PR comment, NOT a review-comment reply — wrong endpoint).
- **No marker version negotiation here.** `note-post` always uses the current `PRTEND_NOTE_MARKER` constant from the notes lib (currently v1). If we ever ship v2, `prtend_note_marker_version` flips and the JSON `marker_version` field auto-tracks; older markers continue to count as "handled" via the `PRTEND_NOTE_MARKER_PATTERNS` array in the notes lib. The subcommand does not expose a `--marker-version` flag.

### Test shape

Match whatever harness step 07/08 landed (bats with shared helpers, or plain bash with `run_test`). Mock `prtend_forge_dispatch` plus the privates by shadowing the `_prtend_forge_gh_*` and `_prtend_forge_gl_*` functions; do not exercise real network in unit tests.

Fixtures under `test/fixtures/note_post/`:

- `comment_body.plain.txt` — a body with no marker; idempotency probe returns 0/exit-0 and we proceed to post.
- `comment_body.handled.txt` — body starting with `<!-- prtend: handled v1 -->`; idempotency probe must detect and refuse.
- `comment_body.handled-future.txt` — body starting with a hypothetical `<!-- prtend: handled v2 -->`; current test confirms v1-only detection (this fixture is exercised by the notes-lib test, but mirrored here so future test runs against a v2 build remain meaningful).
- `post_review_reply.gh.id.txt` → `"456810"` (the `--jq .id` output for a successful gh post — gh prints the bare value).
- `post_review_reply.gl.id.txt` → `"7891011"` (the equivalent for glab).
- `discussions.gl.json` — a small array shaped like `[{"id":"abc123","notes":[{"id":456789}, …]}, …]` used to verify the discussion-id lookup path on the GitLab private.

Cases to cover (one bats `@test` block each, matching step 08's granularity):

1. Happy path `reject`: `--kind reject --reason "stylistic disagreement"`; emits JSON with `kind: "reject"`, body starts with marker, `reply_id` matches fixture.
2. Happy path `accept`: `--kind accept --commit 4f7a2c1`; body contains `fixed in 4f7a2c1`.
3. Happy path `halt`: `--kind halt --reason "needs design review"`; body contains the halt-pattern phrasing from `prtend_note_halt`.
4. Happy path `defer`: `--kind defer --doc /tmp/123-456789.md`; body references the path.
5. Idempotency refusal: comment body already contains the marker → exit 4 with the "already has a prtend marker" stderr; no `post_review_reply` mock invoked.
6. Comment not found: `prtend_forge_comment_body` exit 1 → exit 4 with the "not found" stderr.
7. Forge CLI not authed: mock `prtend_forge_cli_ready` to exit 3 → propagate exit 3.
8. Bad `--kind ignore` → exit 2 with the targeted stderr message.
9. Bad `--kind whatever` → exit 2 with the generic stderr message.
10. Pairing mismatch: `--kind accept --reason X` → exit 2 with the pairing-table message.
11. Pairing mismatch: `--kind reject --commit abc` → exit 2.
12. Pairing mismatch: `--kind defer` with no `--doc` → exit 2.
13. Missing `--pr` → exit 2.
14. Missing `--comment` → exit 2.
15. Dash-leading value (`--reason -bogus`) → exit 2.
16. GitLab discussion-lookup miss: fixture `discussions.gl.json` does not contain the requested comment id → exit 1 with the documented stderr.
17. Empty body sent to `prtend_forge_post_review_reply` (mock the renderer to emit empty) → exit 2 with the "refusing to post empty body" stderr. This is a defensive belt-and-suspenders test; in practice the renderers never emit empty (they exit 2 themselves on missing args), but the lib boundary should still refuse.
18. JSON shape: every happy-path case asserts `posted == true`, `kind` matches input, `marker_version == "v1"`, `comment_id` and `reply_id` are strings, `body` is a string with `\n` between marker and resolution line.

## Verification

```bash
shellcheck bin/prtend lib/prtend/prtend-lib.bash lib/prtend/prtend-forge-lib.bash lib/prtend/prtend-notes-lib.bash lib/prtend/prtend-subcommands/note_post.bash
# → no output, exit 0

# Help still works and lists note-post.
bin/prtend --help
# → exit 0, includes 'note-post' in the subcommand list

# Happy path against a sandbox PR. Replace 123 / 456789 with real ids.
bin/prtend note-post --pr 123 --comment 456789 --kind accept --commit "$(git rev-parse --short HEAD)" | jq .
# → JSON: posted=true, comment_id="456789", reply_id non-empty string,
#    kind="accept", marker_version="v1", body begins with the marker.

# Idempotent re-invocation refuses.
bin/prtend note-post --pr 123 --comment 456789 --kind accept --commit "$(git rev-parse --short HEAD)"; echo "exit=$?"
# → "prtend: comment 456789 already has a prtend marker; refusing to double-post" on stderr; exit=4

# Defer kind with a path that exists.
echo "stub" > /tmp/defer-test.md
bin/prtend note-post --pr 123 --comment 456790 --kind defer --doc /tmp/defer-test.md | jq -r .body
# → two lines: marker, then "Resolution: Defer — tracked at /tmp/defer-test.md"

# Pairing-rule rejection.
bin/prtend note-post --pr 123 --comment 456790 --kind accept --reason "x"; echo "exit=$?"
# → "prtend: --kind accept requires --commit and forbids --reason, --doc" on stderr; exit=2

# Ignore-kind is loudly rejected.
bin/prtend note-post --pr 123 --comment 456790 --kind ignore; echo "exit=$?"
# → the targeted Ignore-specific stderr; exit=2

# Mocked tests pass.
make test    # or `bats test/note_post.bats`, whichever harness landed
# → all cases green
```

## Done

- [ ] `lib/prtend/prtend-subcommands/note_post.bash` defines `prtend_cmd_note_post` and emits the contract JSON
- [ ] `prtend_forge_post_review_reply` (with `_gh`/`_gl` privates) added to `prtend-forge-lib.bash`, dispatching via `prtend_forge_dispatch`
- [ ] Body is read from stdin into the forge private; argv carries only `<pr> <comment_id>`
- [ ] All four kinds (`reject`, `accept`, `halt`, `defer`) reachable end-to-end with their declared flag pairings
- [ ] Kind/flag pairing rules are enforced at parse time; every mismatch case exits 2 with a single clear stderr message
- [ ] `--kind ignore` is rejected with the targeted "Ignore posts nothing" message
- [ ] Idempotency probe via `prtend_forge_comment_body` + `prtend_note_is_handled` refuses to double-post; exit 4 on already-handled
- [ ] Comment-not-found path returns exit 4 with the documented stderr; comment-existence is verified before any body rendering
- [ ] `comment_id` and `reply_id` in the emitted JSON are always strings, even when the forge returns numeric ids
- [ ] `marker_version` in the emitted JSON is sourced from `prtend_note_marker_version` (no string literal duplication)
- [ ] GitLab private looks up the parent discussion id from the note id before posting; miss yields exit 1 with the documented stderr
- [ ] Empty rendered body is refused at the lib boundary (exit 2 with `refusing to post empty body`)
- [ ] `shellcheck` clean on the new file and the modified forge lib
- [ ] Test cases for: each happy-path kind / idempotency refusal / comment-not-found / not-authed / each pairing mismatch / `--kind ignore` / missing required flag / dash-leading value / GL discussion-lookup miss / empty-body refusal / JSON shape invariants
- [ ] One commit on a feature branch: `feat(note-post): add note-post subcommand (step 10)`
