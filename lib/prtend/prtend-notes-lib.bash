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

PRTEND_NOTE_MARKER_VERSION="v1"
PRTEND_NOTE_MARKER="<!-- prtend: handled ${PRTEND_NOTE_MARKER_VERSION} -->"

# Recognition set for `prtend_note_is_handled`. New versions append here.
# Keep newest first as a convention.
PRTEND_NOTE_MARKER_PATTERNS=(
  "<!-- prtend: handled v1 -->"
)

prtend_note_marker() {
  printf '%s\n' "$PRTEND_NOTE_MARKER"
}

prtend_note_marker_version() {
  printf '%s\n' "$PRTEND_NOTE_MARKER_VERSION"
}

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
