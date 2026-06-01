# Step 06 — Notes lib

## Context

Build `prtend-notes-lib.bash` — the resolution-note marker, the four kind-specific body renderers, and the marker-detection helper. This is the second of the two independent libs (state was the first); together they cover all per-PR state and all outgoing comment formatting that later subcommands compose. No subcommand is wired up yet — `note-post` lands in step 10 once forge mutations exist. See `../repo-bootstrap.md` § "Notes & marker" and `../overview.md` § "Note templates".

The lib is deliberately small. Its whole job is to make the marker string a single source of truth so a future format bump (v1 → v2) is one edit, not a grep across the codebase, and to keep `prtend note-post`'s body composition off the subcommand layer.

## Prerequisites

- Step 02 (`dispatcher`) complete — provides `prtend_log_error` in `lib/prtend/prtend-lib.bash` and the lib-load guard idiom.
- No dependency on step 03 (forge) or step 05 (state). Notes lib stands alone — it knows nothing about forges, files, or HTTP. Its inputs are strings; its outputs are strings.

Required on the host for verification: `bash` 4.4+. No `jq`, no forge CLI — this lib is plain string assembly.

## Goal

After this step, `lib/prtend/prtend-notes-lib.bash` defines the marker constants and six public functions from `../repo-bootstrap.md` § "Notes & marker", each emitting the canonical body shape from `../overview.md` § "Note templates":

- `prtend_note_marker` — print the literal marker line `<!-- prtend: handled v1 -->`. No newline-only argument forms; the marker is fixed.
- `prtend_note_marker_version` — print `v1`. The version string is consumed by `note-post`'s JSON output (`marker_version` field, see `../cli-contract.md` § "note-post").
- `prtend_note_reject <reason>` — print marker + `\n` + `Resolution: Reject — <reason>`.
- `prtend_note_accept <commit-hash>` — print marker + `\n` + `Resolution: Accept — fixed in <commit-hash>`.
- `prtend_note_halt <reason>` — print marker + `\n` + `Resolution: Halt — <reason>; no further work pending research`.
- `prtend_note_defer <doc-path>` — print marker + `\n` + `Resolution: Defer — tracked at <doc-path>`.
- `prtend_note_is_handled <comment-body>` — exit 0 if the body contains any recognized marker, 1 otherwise. No stdout output.

There is deliberately no `prtend_note_ignore` — Ignore posts nothing by definition (see `../overview.md` § "Note templates" and `../cli-contract.md` § "note-post" flag table). A renderer for it would invite the wrong subcommand to call it.

No subcommand consumes the lib yet; step 10's `note-post` composes `prtend_note_<kind>` with `prtend_forge_post_review_reply` (step 09).

## Files to create or modify

- `lib/prtend/prtend-notes-lib.bash` (NEW)

## Implementation

### File header

Mirror the load-guard idiom from `prtend-forge-lib.bash` and `prtend-state-lib.bash` (step 05): dep check before the load guard, before `set -euo pipefail`. The reasoning is the same one documented in step 05 — `set -e` leaks into the caller, and a poisoned guard makes a later correct source silently no-op.

```bash
#!/usr/bin/env bash
# prtend-notes-lib.bash — resolution-note marker, body renderers, and the
# idempotency-detection helper. Pure string assembly; no I/O, no forge calls.

if [[ -n "${PRTEND_NOTES_LIB_LOADED:-}" ]]; then
  return 0
fi

if [[ -z "${PRTEND_LIB_LOADED:-}" ]]; then
  printf 'error: prtend-notes-lib.bash requires prtend-lib.bash to be sourced first\n' >&2
  return 1
fi

set -euo pipefail
PRTEND_NOTES_LIB_LOADED=1
```

### Marker constants

The marker version lives in exactly one place. Future versions extend the recognition set without changing the emit string for old code.

```bash
PRTEND_NOTE_MARKER_VERSION="v1"
PRTEND_NOTE_MARKER="<!-- prtend: handled ${PRTEND_NOTE_MARKER_VERSION} -->"

# Recognition set for `prtend_note_is_handled`. New versions append here.
# Order matters only for grep speed (longest-match first is irrelevant for
# fixed strings — keep newest first as a convention).
PRTEND_NOTE_MARKER_PATTERNS=(
  "<!-- prtend: handled v1 -->"
)
```

Two important details:

- **`PRTEND_NOTE_MARKER` is the *only* string emitted by the renderers.** Every renderer below interpolates `$PRTEND_NOTE_MARKER`, never a literal `<!-- prtend: handled v1 -->`. When step 14-or-later bumps to v2, this one line changes and every new note picks up the new marker; the recognition list keeps old notes idempotent.
- **`PRTEND_NOTE_MARKER_PATTERNS` is a literal-string array, not a regex.** `prtend_note_is_handled` uses `grep -F -q` (fixed strings) so the angle brackets, dashes, and exclamation marks need no escaping. If a future marker format wants real pattern matching, change the helper, not the format.

### `prtend_note_marker` / `prtend_note_marker_version`

```bash
prtend_note_marker() {
  printf '%s\n' "$PRTEND_NOTE_MARKER"
}

prtend_note_marker_version() {
  printf '%s\n' "$PRTEND_NOTE_MARKER_VERSION"
}
```

These exist so `note-post` (step 10) can populate the `marker_version` field of its JSON output without re-deriving the constant. Trivial wrappers, but the indirection means `note-post.bash` never reads `PRTEND_NOTE_MARKER_VERSION` directly — the constant stays an internal detail of this lib.

### Renderer pattern

Every renderer follows the same shape: validate the single argument is non-empty, emit marker + newline + body line. No multi-line bodies, no trailing newline beyond the implicit `printf '%s\n'`.

```bash
prtend_note_reject() {
  local reason="${1:-}"
  if [[ -z "$reason" ]]; then
    prtend_log_error "prtend_note_reject: missing reason argument"
    return 2
  fi
  printf '%s\n%s\n' "$PRTEND_NOTE_MARKER" "Resolution: Reject — $reason"
}

prtend_note_accept() {
  local commit="${1:-}"
  if [[ -z "$commit" ]]; then
    prtend_log_error "prtend_note_accept: missing commit-hash argument"
    return 2
  fi
  printf '%s\n%s\n' "$PRTEND_NOTE_MARKER" "Resolution: Accept — fixed in $commit"
}

prtend_note_halt() {
  local reason="${1:-}"
  if [[ -z "$reason" ]]; then
    prtend_log_error "prtend_note_halt: missing reason argument"
    return 2
  fi
  printf '%s\n%s\n' "$PRTEND_NOTE_MARKER" "Resolution: Halt — $reason; no further work pending research"
}

prtend_note_defer() {
  local doc="${1:-}"
  if [[ -z "$doc" ]]; then
    prtend_log_error "prtend_note_defer: missing doc-path argument"
    return 2
  fi
  printf '%s\n%s\n' "$PRTEND_NOTE_MARKER" "Resolution: Defer — tracked at $doc"
}
```

A few decisions baked in:

- **Em-dash, not hyphen.** The body strings use `—` (U+2014) verbatim per `../overview.md` § "Note templates". Save the file UTF-8; the `.editorconfig` from step 01 already enforces that.
- **No `commit` format validation.** `prtend_note_accept` doesn't check that `<commit-hash>` looks like a SHA. The skill should pass `git rev-parse HEAD`'s output; if it passes garbage, the resulting note reads "fixed in garbage" and the human reviewing the PR catches it. Validating here would mean re-deciding what counts as a commit (short SHA? prefix? tag?), which is the caller's choice.
- **No `doc` existence check.** `prtend_note_defer` doesn't `[[ -f "$doc" ]]` — the path is what `defer-write` (step 11) returns, and that subcommand is responsible for writing the file before the note is posted. Notes lib has no business touching the filesystem.
- **Exit 2 for missing argument** matches the convention from `prtend_atomic_write`, `prtend_state_write`, and `prtend_config_get`: 2 = caller-provided bad input.
- **No `prtend_note_ignore`.** Don't add one "for symmetry" — it would only ever be wrong to call. The renderer set is exactly the four kinds that produce notes.

### Multi-line reasons

`<reason>` may legitimately contain newlines (a reviewer's comment quoted back, a multi-sentence explanation). The renderers pass `$reason` straight to `printf '%s'`, which preserves embedded newlines. The resulting body is still valid Markdown — the marker is an HTML comment on its own line, then the resolution paragraph follows. Test fixture in Verification covers this.

What the renderers do *not* do is escape the body for the forge API. `prtend_forge_post_review_reply` (step 09) handles that. The notes lib's contract is "produce the body string"; transport encoding is downstream.

### `prtend_note_is_handled`

```bash
prtend_note_is_handled() {
  local body="${1:-}"
  if [[ -z "$body" ]]; then
    # An empty body trivially does not contain a marker. Exit 1 (not handled)
    # rather than 2 — the caller is `reviews-poll` checking every comment,
    # and an empty body is a legitimate observation, not a usage error.
    return 1
  fi
  local pattern
  for pattern in "${PRTEND_NOTE_MARKER_PATTERNS[@]}"; do
    if printf '%s' "$body" | grep -F -q -- "$pattern"; then
      return 0
    fi
  done
  return 1
}
```

Three decisions:

- **`grep -F` (fixed strings), not `grep -E`.** The marker contains `<`, `>`, `!`, `-`, none of which are regex metacharacters in BRE/ERE, but `-F` makes the intent explicit and skips the regex compile.
- **`-q` suppresses stdout.** This function returns a status, not a body. Callers do `if prtend_note_is_handled "$body"; then ...`.
- **Empty body returns 1, not 2.** Rationale in the comment above — the caller is iterating over every review comment and may legitimately encounter an empty `body` field from the forge (e.g., a thread-resolution event). Treating that as a usage error would crash `reviews-poll`. The "missing argument" guard from the renderers doesn't apply here because the argument isn't *missing*; it's *empty*, which is a real shape the forge can return.

The recognition loop iterates `PRTEND_NOTE_MARKER_PATTERNS`. With one entry today it's a single grep; with v2 added later it's two. Don't optimize this — the bodies are short and the loop runs once per comment, not in a hot path.

### No `bin/prtend` change

The dispatcher does not need to source `prtend-notes-lib.bash` yet — no subcommand uses it. Step 10's `note-post` adds the source line at the top of `lib/prtend/prtend-subcommands/note_post.bash`. Confirm step 02's dispatcher doesn't accidentally already source it (it shouldn't — the dispatcher sources only `prtend-lib.bash`).

### Key decisions

- **Renderers are the *only* path to the marker.** Subcommands and the skill must never assemble note bodies by hand — that's the rule from `../skill-prompts.md` § "Never bypass note-post". The lib enforces that by making `PRTEND_NOTE_MARKER` an internal constant (not a documented env var) and exposing renderers that prepend it.
- **The marker version is internal, not configurable.** No `PRTEND_NOTE_MARKER_VERSION` env override. Bumping to v2 is a coordinated change across the lib, the skill, and any in-flight notes — it deserves a code edit, not a flag.
- **No newline-only output.** Every renderer's output is exactly two lines (marker, resolution), terminated with a single `\n`. Callers (post-review-reply) can re-wrap as needed.
- **`grep -F` over `bash ==` matching.** A `[[ "$body" == *"$PRTEND_NOTE_MARKER"* ]]` would work for one pattern but doesn't generalize to the version-recognition loop. Grep is the path that scales when v2 lands.
- **No JSON anywhere.** This lib produces plain text. JSON wrapping happens in `note-post`'s subcommand layer (step 10) when it assembles the canonical output shape from `../cli-contract.md` § "note-post".
- **No `.editorconfig` exception needed.** Em-dash is UTF-8; the file's `.bash` extension matches the existing `bash` block in `.editorconfig` from step 01 (LF line endings, UTF-8, trim trailing whitespace).

## Verification

```bash
shellcheck bin/prtend lib/prtend/prtend-lib.bash lib/prtend/prtend-notes-lib.bash
# → no output, exit 0

# Functions and constants are defined.
bash -c '
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-notes-lib.bash
  for f in prtend_note_marker prtend_note_marker_version \
           prtend_note_reject prtend_note_accept \
           prtend_note_halt prtend_note_defer prtend_note_is_handled; do
    declare -F "$f" >/dev/null || { echo "missing: $f" >&2; exit 1; }
  done
  [[ "$PRTEND_NOTE_MARKER_VERSION" == "v1" ]] || { echo "wrong marker version" >&2; exit 1; }
  [[ "$PRTEND_NOTE_MARKER" == "<!-- prtend: handled v1 -->" ]] || { echo "wrong marker string" >&2; exit 1; }
  echo ok
'
# → "ok"; exit 0

# Renderer output matches the canonical shape from docs/overview.md.
bash -c '
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-notes-lib.bash
  expected="<!-- prtend: handled v1 -->
Resolution: Accept — fixed in 4f7a2c1"
  actual="$(prtend_note_accept 4f7a2c1)"
  [[ "$actual" == "$expected" ]] || { printf "mismatch:\nexpected:\n%s\nactual:\n%s\n" "$expected" "$actual" >&2; exit 1; }
  echo ok
'
# → "ok"; exit 0

# All four renderers refuse missing arguments with exit 2.
bash -c '
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-notes-lib.bash
  for fn in prtend_note_reject prtend_note_accept prtend_note_halt prtend_note_defer; do
    if "$fn" 2>/dev/null; then echo "$fn accepted empty input" >&2; exit 1; fi
    "$fn" 2>/dev/null; rc=$?
    [[ $rc -eq 2 ]] || { echo "$fn exit code $rc, expected 2" >&2; exit 1; }
  done
  echo ok
'
# → "ok"; exit 0

# Multi-line reason survives intact.
bash -c '
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-notes-lib.bash
  body="$(prtend_note_reject "first line
second line")"
  printf "%s" "$body" | grep -q "second line" || { echo "newline reason lost" >&2; exit 1; }
  echo ok
'
# → "ok"; exit 0

# Detection: handled body returns 0, plain body returns 1, empty returns 1.
bash -c '
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-notes-lib.bash
  handled="$(prtend_note_accept abc1234)"
  prtend_note_is_handled "$handled"   || { echo "handled body not detected" >&2; exit 1; }
  prtend_note_is_handled "looks fine" && { echo "plain body falsely detected" >&2; exit 1; }
  prtend_note_is_handled ""           && { echo "empty body falsely detected" >&2; exit 1; }
  echo ok
'
# → "ok"; exit 0

# Lib sources cleanly under minimal PATH (regression check from step 02).
env -i PATH=/usr/bin:/bin HOME="$HOME" bash -c \
  'source lib/prtend/prtend-lib.bash && source lib/prtend/prtend-notes-lib.bash && declare -F prtend_note_is_handled'
# → "prtend_note_is_handled"; exit 0

# Load guard: sourcing twice is a no-op.
bash -c '
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-notes-lib.bash
  PRTEND_NOTE_MARKER="MUTATED"
  source lib/prtend/prtend-notes-lib.bash
  [[ "$PRTEND_NOTE_MARKER" == "MUTATED" ]] || { echo "load guard failed — constant reset" >&2; exit 1; }
  echo ok
'
# → "ok"; exit 0

# Load order guard: sourcing notes-lib without prtend-lib first fails cleanly.
bash -c '
  source lib/prtend/prtend-notes-lib.bash 2>&1 | grep -q "requires prtend-lib.bash" || { echo "guard message missing" >&2; exit 1; }
  echo ok
'
# → "ok"; exit 0

# Dispatcher still healthy and does NOT source notes-lib yet.
bin/prtend --help
bin/prtend --version
bash -c '
  source bin/prtend  # don'\''t run, just inspect
' 2>/dev/null || true
grep -q "prtend-notes-lib" bin/prtend && { echo "dispatcher sources notes-lib prematurely" >&2; exit 1; }
# → silent; exit 0
```

## Done

- [ ] `lib/prtend/prtend-notes-lib.bash` defines `PRTEND_NOTE_MARKER`, `PRTEND_NOTE_MARKER_VERSION`, `PRTEND_NOTE_MARKER_PATTERNS`, and the seven public functions (`prtend_note_marker`, `prtend_note_marker_version`, `prtend_note_reject`, `prtend_note_accept`, `prtend_note_halt`, `prtend_note_defer`, `prtend_note_is_handled`)
- [ ] Every renderer emits exactly two lines: the marker, then `Resolution: <Kind> — …`, terminated with `\n`
- [ ] Renderers exit 2 on missing/empty argument; `prtend_note_is_handled` exits 1 (not 2) on empty body
- [ ] `prtend_note_is_handled` recognizes the v1 marker via the `PRTEND_NOTE_MARKER_PATTERNS` array (`grep -F -q`), leaving room for future versions to append
- [ ] No `prtend_note_ignore` exists — Ignore posts nothing by design
- [ ] `shellcheck` clean on the new lib and unchanged dispatcher
- [ ] Lib sources cleanly under minimal `PATH` and is idempotent under double-source (load-guard regression check from step 02 still holds)
- [ ] Load-order guard: sourcing `prtend-notes-lib.bash` before `prtend-lib.bash` prints the documented error and returns non-zero without poisoning the load guard
- [ ] `bin/prtend` is unchanged — no subcommand consumes the notes lib yet
- [ ] One commit on a feature branch: `feat(notes): add notes lib with marker and renderers`
