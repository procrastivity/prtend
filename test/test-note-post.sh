#!/usr/bin/env bash
# test-note-post.sh — covers prtend note-post. Same harness style as
# test-pr-open.sh: subshell isolation, forge primitives shadowed via function
# override, no real network.
#
# shellcheck disable=SC2030,SC2031,SC2329

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_ROOT/test/fixtures/note_post"

RESULTS="$(mktemp -t prtend-results.XXXXXX)"
export RESULTS
trap 'rm -f "$RESULTS"' EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'P\n' >>"$RESULTS"
    printf '  ok    %s\n' "$label"
  else
    printf 'F\n' >>"$RESULTS"
    printf '  FAIL  %s\n        expected: %q\n        actual:   %q\n' "$label" "$expected" "$actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'P\n' >>"$RESULTS"
    printf '  ok    %s\n' "$label"
  else
    printf 'F\n' >>"$RESULTS"
    printf '  FAIL  %s\n        needle:   %q\n        haystack: %q\n' "$label" "$needle" "$haystack"
  fi
}

new_sandbox() {
  SANDBOX="$(mktemp -d -t prtend-test.XXXXXX)"
  (
    cd "$SANDBOX"
    git init -q
    git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  )
}

load_libs() {
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-forge-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-notes-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-subcommands/note_post.bash"
  set +e
  export PRTEND_FORGE=github
  _prtend_forge_gh_cli_ready() { return 0; }
  # Default: thread exists, no marker anywhere in it (original + replies).
  _prtend_forge_gh_review_thread_bodies() { cat "$FIXTURES/comment_body.plain.txt"; }
  # Default: reply posts successfully with id 456810.
  _prtend_forge_gh_post_review_reply() {
    cat >/dev/null
    printf '456810\n'
  }
}

# ----------------------------------------------------------------------------
# Case 1 — happy path: reject
# ----------------------------------------------------------------------------
case_reject() {
  echo "case: happy path reject"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    out="$(prtend_cmd_note_post --pr 123 --comment 456789 \
      --kind reject --reason "stylistic disagreement" 2>/dev/null)"
    rc=$?
    assert_eq "exit code"      0       "$rc"
    assert_eq "posted"         'true'  "$(jq -c .posted <<<"$out")"
    assert_eq "comment_id str" '"456789"' "$(jq -c .comment_id <<<"$out")"
    assert_eq "reply_id str"   '"456810"' "$(jq -c .reply_id <<<"$out")"
    assert_eq "kind"           '"reject"' "$(jq -c .kind <<<"$out")"
    assert_eq "marker_version" '"v1"'  "$(jq -c .marker_version <<<"$out")"
    body="$(jq -r .body <<<"$out")"
    assert_contains "body has marker"  "<!-- prtend: handled v1 -->" "$body"
    assert_contains "body has reason"  "stylistic disagreement"       "$body"
    assert_contains "body says Reject" "Resolution: Reject"            "$body"
  )
}

# ----------------------------------------------------------------------------
# Case 2 — happy path: accept
# ----------------------------------------------------------------------------
case_accept() {
  echo "case: happy path accept"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    out="$(prtend_cmd_note_post --pr 123 --comment 456789 \
      --kind accept --commit 4f7a2c1 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "kind"      '"accept"' "$(jq -c .kind <<<"$out")"
    body="$(jq -r .body <<<"$out")"
    assert_contains "body says Accept"     "Resolution: Accept" "$body"
    assert_contains "body has commit hash" "fixed in 4f7a2c1"   "$body"
  )
}

# ----------------------------------------------------------------------------
# Case 3 — happy path: halt
# ----------------------------------------------------------------------------
case_halt() {
  echo "case: happy path halt"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    out="$(prtend_cmd_note_post --pr 123 --comment 456789 \
      --kind halt --reason "needs design review" 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "kind"      '"halt"' "$(jq -c .kind <<<"$out")"
    body="$(jq -r .body <<<"$out")"
    assert_contains "body says Halt"           "Resolution: Halt"           "$body"
    assert_contains "body has reason"          "needs design review"        "$body"
    assert_contains "body has pending phrase"  "pending research"           "$body"
  )
}

# ----------------------------------------------------------------------------
# Case 4 — happy path: defer
# ----------------------------------------------------------------------------
case_defer() {
  echo "case: happy path defer"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    out="$(prtend_cmd_note_post --pr 123 --comment 456789 \
      --kind defer --doc /tmp/123-456789.md 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "kind"      '"defer"' "$(jq -c .kind <<<"$out")"
    body="$(jq -r .body <<<"$out")"
    assert_contains "body says Defer"   "Resolution: Defer"     "$body"
    assert_contains "body has doc path" "/tmp/123-456789.md"    "$body"
  )
}

# ----------------------------------------------------------------------------
# Case 5 — idempotency refusal: comment already has marker
# ----------------------------------------------------------------------------
case_idempotent_refusal() {
  echo "case: idempotency refusal"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    _prtend_forge_gh_review_thread_bodies() { cat "$FIXTURES/comment_body.handled.txt"; }
    posted_called="$(mktemp)"
    _prtend_forge_gh_post_review_reply() {
      cat >/dev/null
      printf 'called\n' >"$posted_called"
      printf '999\n'
    }
    err="$(prtend_cmd_note_post --pr 123 --comment 456789 \
      --kind accept --commit abc 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 4 "$rc"
    assert_contains "stderr message" "already has a prtend marker" "$err"
    assert_eq "post not invoked" "" "$(cat "$posted_called")"
  )
}

# ----------------------------------------------------------------------------
# Case 5b — idempotency refusal: marker lives in a REPLY, not the original
# comment. This is the realistic scenario: prtend's reply (containing the
# marker) is a separate node in the thread; the reviewer's original comment
# never gets edited. Probing only the original body would miss this and
# double-post.
# ----------------------------------------------------------------------------
case_idempotent_refusal_reply() {
  echo "case: idempotency refusal (marker in reply, not original)"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    _prtend_forge_gh_review_thread_bodies() { cat "$FIXTURES/thread.handled-in-reply.txt"; }
    posted_called="$(mktemp)"
    _prtend_forge_gh_post_review_reply() {
      cat >/dev/null
      printf 'called\n' >"$posted_called"
      printf '999\n'
    }
    err="$(prtend_cmd_note_post --pr 123 --comment 456789 \
      --kind accept --commit abc 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 4 "$rc"
    assert_contains "stderr message" "already has a prtend marker" "$err"
    assert_eq "post not invoked" "" "$(cat "$posted_called")"
  )
}

# ----------------------------------------------------------------------------
# Case 6 — comment not found
# ----------------------------------------------------------------------------
case_comment_not_found() {
  echo "case: comment not found"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    _prtend_forge_gh_review_thread_bodies() { return 1; }
    err="$(prtend_cmd_note_post --pr 123 --comment 456789 \
      --kind accept --commit abc 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 4 "$rc"
    assert_contains "stderr message" "not found" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 7 — forge CLI not authed
# ----------------------------------------------------------------------------
case_not_authed() {
  echo "case: forge CLI not authed"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    _prtend_forge_gh_cli_ready() { return 3; }
    prtend_cmd_note_post --pr 123 --comment 456789 \
      --kind accept --commit abc >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 3 "$rc"
  )
}

# ----------------------------------------------------------------------------
# Case 8 — --kind ignore: targeted message
# ----------------------------------------------------------------------------
case_kind_ignore() {
  echo "case: --kind ignore rejected"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    err="$(prtend_cmd_note_post --pr 123 --comment 456789 --kind ignore 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 2 "$rc"
    assert_contains "stderr targeted" "Ignore posts nothing" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 9 — --kind whatever: generic message
# ----------------------------------------------------------------------------
case_kind_invalid() {
  echo "case: --kind whatever rejected"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    err="$(prtend_cmd_note_post --pr 123 --comment 456789 --kind whatever 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 2 "$rc"
    assert_contains "stderr generic" "expected reject|accept|halt|defer" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 10 — pairing mismatch: accept + reason
# ----------------------------------------------------------------------------
case_pair_accept_reason() {
  echo "case: pairing mismatch (accept + reason)"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    err="$(prtend_cmd_note_post --pr 123 --comment 456789 \
      --kind accept --reason "x" 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 2 "$rc"
    assert_contains "stderr pairing" "requires --commit and forbids" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 11 — pairing mismatch: reject + commit
# ----------------------------------------------------------------------------
case_pair_reject_commit() {
  echo "case: pairing mismatch (reject + commit)"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    err="$(prtend_cmd_note_post --pr 123 --comment 456789 \
      --kind reject --commit abc 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 2 "$rc"
    assert_contains "stderr pairing" "requires --reason and forbids" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 12 — pairing mismatch: defer with no --doc
# ----------------------------------------------------------------------------
case_pair_defer_no_doc() {
  echo "case: pairing mismatch (defer without --doc)"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    err="$(prtend_cmd_note_post --pr 123 --comment 456789 --kind defer 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 2 "$rc"
    assert_contains "stderr pairing" "requires --doc and forbids" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 13 — missing --pr
# ----------------------------------------------------------------------------
case_missing_pr() {
  echo "case: missing --pr"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    prtend_cmd_note_post --comment 456789 --kind accept --commit abc >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 2 "$rc"
  )
}

# ----------------------------------------------------------------------------
# Case 14 — missing --comment
# ----------------------------------------------------------------------------
case_missing_comment() {
  echo "case: missing --comment"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    prtend_cmd_note_post --pr 123 --kind accept --commit abc >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 2 "$rc"
  )
}

# ----------------------------------------------------------------------------
# Case 15 — dash-leading value
# ----------------------------------------------------------------------------
case_dash_leading_value() {
  echo "case: dash-leading value rejected"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    prtend_cmd_note_post --pr 123 --comment 456789 \
      --kind reject --reason -bogus >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 2 "$rc"
  )
}

# ----------------------------------------------------------------------------
# Case 16 — GitLab discussion-lookup miss
# ----------------------------------------------------------------------------
case_gl_discussion_miss() {
  echo "case: GitLab discussion-lookup miss"
  (
    new_sandbox
    cd "$SANDBOX"
    # Use the GitLab dispatch path and shadow private helpers directly.
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/prtend/prtend-lib.bash"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/prtend/prtend-forge-lib.bash"
    set +e
    export PRTEND_FORGE=gitlab
    _prtend_forge_gl_project_id() { printf '42\n'; }
    # Stub `glab api` to return an empty discussions list (no match).
    glab() {
      if [[ "${1:-}" == "api" ]]; then
        printf '[]\n'
        return 0
      fi
      command glab "$@"
    }
    err="$(printf 'hello' | prtend_forge_post_review_reply 7 999999 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 1 "$rc"
    assert_contains "stderr message" "no discussion contains note" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 17 — empty body refused at lib boundary
# ----------------------------------------------------------------------------
case_empty_body_refused() {
  echo "case: empty rendered body refused at lib boundary"
  (
    new_sandbox
    cd "$SANDBOX"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/prtend/prtend-lib.bash"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/prtend/prtend-forge-lib.bash"
    set +e
    export PRTEND_FORGE=github
    _prtend_forge_gh_repo_slug() { printf 'owner/repo\n'; }
    err="$(printf '' | prtend_forge_post_review_reply 7 99 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 2 "$rc"
    assert_contains "stderr message" "refusing to post empty body" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 18 — JSON shape invariants (one happy path)
# ----------------------------------------------------------------------------
case_json_shape() {
  echo "case: JSON shape invariants"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    out="$(prtend_cmd_note_post --pr 123 --comment 456789 \
      --kind accept --commit abc1234 2>/dev/null)"
    rc=$?
    assert_eq "exit code"                      0           "$rc"
    assert_eq "posted == true"                 'true'      "$(jq -c .posted <<<"$out")"
    assert_eq "kind matches input"             '"accept"'  "$(jq -c .kind <<<"$out")"
    assert_eq "marker_version is v1"           '"v1"'      "$(jq -c .marker_version <<<"$out")"
    assert_eq "comment_id is string"           '"string"'  "$(jq -c '.comment_id | type' <<<"$out")"
    assert_eq "reply_id is string"             '"string"'  "$(jq -c '.reply_id | type' <<<"$out")"
    assert_eq "body is string"                 '"string"'  "$(jq -c '.body | type' <<<"$out")"
    # Body starts with the marker line, then newline, then resolution line.
    body="$(jq -r .body <<<"$out")"
    first_line="${body%%$'\n'*}"
    assert_eq "first body line is marker" "<!-- prtend: handled v1 -->" "$first_line"
    assert_contains "body contains \\n separator" $'\n' "$body"
  )
}

case_reject
case_accept
case_halt
case_defer
case_idempotent_refusal
case_idempotent_refusal_reply
case_comment_not_found
case_not_authed
case_kind_ignore
case_kind_invalid
case_pair_accept_reason
case_pair_reject_commit
case_pair_defer_no_doc
case_missing_pr
case_missing_comment
case_dash_leading_value
case_gl_discussion_miss
case_empty_body_refused
case_json_shape

PASS="$(grep -c '^P' "$RESULTS" || true)"
FAIL="$(grep -c '^F' "$RESULTS" || true)"
echo
echo "passed: ${PASS:-0}    failed: ${FAIL:-0}"
if (( FAIL > 0 )); then exit 1; fi
