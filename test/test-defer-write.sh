#!/usr/bin/env bash
# test-defer-write.sh — covers prtend defer-write. Same harness style as
# test-note-post.sh / test-pr-open.sh: subshell isolation, forge primitives
# shadowed via function override, no real network.
#
# shellcheck disable=SC2030,SC2031,SC2329

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_ROOT/test/fixtures/defer_write"

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

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'P\n' >>"$RESULTS"
    printf '  ok    %s\n' "$label"
  else
    printf 'F\n' >>"$RESULTS"
    printf '  FAIL  %s\n        needle (should be absent): %q\n        haystack: %q\n' "$label" "$needle" "$haystack"
  fi
}

new_sandbox() {
  SANDBOX="$(mktemp -d -t prtend-test.XXXXXX)"
  (
    cd "$SANDBOX"
    git init -q
    git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
    mkdir -p src
    cp "$FIXTURES/snippet_target.txt" src/widget.ts
    # An on-disk config the resolver will find via PRTEND_CONFIG.
    : > "$SANDBOX/prtend.yml"
  )
  export PRTEND_CONFIG="$SANDBOX/prtend.yml"
}

load_libs() {
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-forge-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-subcommands/defer_write.bash"
  set +e
  export PRTEND_FORGE=github
  _prtend_forge_gh_cli_ready() { return 0; }
  _prtend_forge_gh_comment_info() { cat "$FIXTURES/comment_info.gh.inline.json"; }
}

# ----------------------------------------------------------------------------
# Case 1 — happy path GitHub inline
# ----------------------------------------------------------------------------
case_gh_inline() {
  echo "case: happy path GitHub inline"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    out="$(prtend_cmd_defer_write --pr 123 --comment 456789 \
      --reason "Pending design review" 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "pr is integer"      '123'              "$(jq -c .pr <<<"$out")"
    assert_eq "comment_id string"  '"456789"'         "$(jq -c .comment_id <<<"$out")"
    assert_eq "comment_id type"    '"string"'         "$(jq -c '.comment_id | type' <<<"$out")"
    assert_eq "pr type"            '"number"'         "$(jq -c '.pr | type' <<<"$out")"
    path="$(jq -r .path <<<"$out")"
    assert_eq "path is absolute"   '/'                "${path:0:1}"
    assert_contains "path ends with /deferred/123-456789.md" "/deferred/123-456789.md" "$path"
    url="$(jq -r .comment_url <<<"$out")"
    assert_contains "url is https" "https://" "$url"
    # File exists and matches expected modulo deferred_at.
    if [[ -f "$path" ]]; then assert_eq "file exists" 0 0; else assert_eq "file exists" 0 1; fi
    actual_norm="$(sed -E 's/^deferred_at: .*/deferred_at: PLACEHOLDER/' "$path")"
    expected="$(cat "$FIXTURES/expected_doc.gh.md")"
    assert_eq "doc body matches expected" "$expected" "$actual_norm"
  )
}

# ----------------------------------------------------------------------------
# Case 2 — happy path GitLab inline
# ----------------------------------------------------------------------------
case_gl_inline() {
  echo "case: happy path GitLab inline"
  (
    new_sandbox
    cd "$SANDBOX"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/prtend/prtend-lib.bash"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/prtend/prtend-forge-lib.bash"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/prtend/prtend-subcommands/defer_write.bash"
    set +e
    export PRTEND_FORGE=gitlab
    _prtend_forge_gl_cli_ready() { return 0; }
    _prtend_forge_gl_comment_info() { cat "$FIXTURES/comment_info.gl.inline.json"; }
    out="$(prtend_cmd_defer_write --pr 123 --comment 991 \
      --reason "Pending design review" 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    path="$(jq -r .path <<<"$out")"
    body="$(cat "$path")"
    assert_contains "frontmatter has forge: gitlab" "forge: gitlab" "$body"
    assert_contains "reviewer is @carol"            "@carol"        "$body"
    assert_contains "comment link is gitlab url"    "gitlab.com"    "$body"
  )
}

# ----------------------------------------------------------------------------
# Case 3 — non-inline comment (path empty, line null)
# ----------------------------------------------------------------------------
case_non_inline() {
  echo "case: non-inline comment"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    _prtend_forge_gh_comment_info() { cat "$FIXTURES/comment_info.gh.non_inline.json"; }
    out="$(prtend_cmd_defer_write --pr 123 --comment 456790 \
      --reason "later" 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    path="$(jq -r .path <<<"$out")"
    body="$(cat "$path")"
    assert_contains "snippet fallback present" "<no snippet available" "$body"
    assert_contains "location fallback"        "(non-inline)"          "$body"
  )
}

# ----------------------------------------------------------------------------
# Case 4 — idempotency: existing file is not overwritten; mock IS called
# ----------------------------------------------------------------------------
case_idempotent() {
  echo "case: idempotent re-invocation"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    mkdir -p "$SANDBOX/deferred"
    existing_path="$SANDBOX/deferred/123-456789.md"
    printf 'PRESERVED-CONTENT\n' > "$existing_path"
    before="$(cat "$existing_path")"
    invoked="$(mktemp)"
    _prtend_forge_gh_comment_info() {
      printf 'called\n' >"$invoked"
      cat "$FIXTURES/comment_info.gh.inline.json"
    }
    out="$(prtend_cmd_defer_write --pr 123 --comment 456789 \
      --reason "Pending design review" 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    after="$(cat "$existing_path")"
    assert_eq "file unchanged byte-for-byte" "$before" "$after"
    returned_path="$(jq -r .path <<<"$out")"
    # The resolver canonicalises symlinks via cd+pwd; compare basenames.
    assert_eq "path basename matches" "$(basename "$existing_path")" "$(basename "$returned_path")"
    assert_eq "comment_info was invoked" "called" "$(cat "$invoked")"
  )
}

# ----------------------------------------------------------------------------
# Case 5 — comment not found
# ----------------------------------------------------------------------------
case_comment_not_found() {
  echo "case: comment not found"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    _prtend_forge_gh_comment_info() { return 1; }
    err="$(prtend_cmd_defer_write --pr 123 --comment 999 \
      --reason "x" 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 4 "$rc"
    assert_contains "stderr message" "not found" "$err"
    if [[ ! -f "$SANDBOX/deferred/123-999.md" ]]; then
      assert_eq "no doc written" 0 0
    else
      assert_eq "no doc written" 0 1
    fi
  )
}

# ----------------------------------------------------------------------------
# Case 6 — no config resolved → exit 4
# ----------------------------------------------------------------------------
case_no_config() {
  echo "case: no config"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    unset PRTEND_CONFIG
    # Also point HOME somewhere empty so XDG resolution misses.
    export HOME="$SANDBOX/empty-home"
    unset XDG_CONFIG_HOME
    err="$(prtend_cmd_defer_write --pr 123 --comment 456789 \
      --reason "x" 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 4 "$rc"
    assert_contains "stderr message" "no active config" "$err"
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
    prtend_cmd_defer_write --pr 123 --comment 456789 --reason "x" >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 3 "$rc"
  )
}

# ----------------------------------------------------------------------------
# Case 8 — bad --pr
# ----------------------------------------------------------------------------
case_bad_pr() {
  echo "case: bad --pr"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    prtend_cmd_defer_write --pr abc --comment 456789 --reason "x" >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 2 "$rc"
  )
}

# ----------------------------------------------------------------------------
# Case 9 — missing --reason
# ----------------------------------------------------------------------------
case_missing_reason() {
  echo "case: missing --reason"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    prtend_cmd_defer_write --pr 123 --comment 456789 >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 2 "$rc"
  )
}

# ----------------------------------------------------------------------------
# Case 10 — dash-leading --reason
# ----------------------------------------------------------------------------
case_dash_reason() {
  echo "case: dash-leading --reason"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    prtend_cmd_defer_write --pr 123 --comment 456789 --reason -bogus >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 2 "$rc"
  )
}

# ----------------------------------------------------------------------------
# Case 11 — newline in --reason
# ----------------------------------------------------------------------------
case_newline_reason() {
  echo "case: newline in --reason"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    err="$(prtend_cmd_defer_write --pr 123 --comment 456789 \
      --reason "$(printf 'a\nb')" 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 2 "$rc"
    assert_contains "stderr message" "must not contain a newline" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 12 — snippet path missing in HEAD → fallback sentinel
# ----------------------------------------------------------------------------
case_missing_path_in_head() {
  echo "case: snippet path missing in HEAD"
  (
    new_sandbox
    cd "$SANDBOX"
    rm -f src/widget.ts
    load_libs
    out="$(prtend_cmd_defer_write --pr 123 --comment 456789 \
      --reason "x" 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    path="$(jq -r .path <<<"$out")"
    body="$(cat "$path")"
    assert_contains "snippet fallback present" "<no snippet available" "$body"
    # Comment location still renders with path:line — only the snippet falls back.
    # shellcheck disable=SC2016
    assert_contains "comment location renders" '`src/widget.ts:5`' "$body"
  )
}

# ----------------------------------------------------------------------------
# Case 13 — snippet line=1 (lower bound clipped)
# ----------------------------------------------------------------------------
case_snippet_line_1() {
  echo "case: snippet at line 1"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    _prtend_forge_gh_comment_info() {
      jq -c '.line = 1' "$FIXTURES/comment_info.gh.inline.json"
    }
    out="$(prtend_cmd_defer_write --pr 123 --comment 456789 \
      --reason "x" 2>/dev/null)"
    path="$(jq -r .path <<<"$out")"
    body="$(cat "$path")"
    # Snippet should start at line 1, not line -2.
    assert_contains "starts at line 1" $'\nline 1\n' "$body"
    # Should not contain any negative-numbered nonsense; just sanity-check
    # that line 4 is the last line emitted (1+3 = 4).
    assert_contains "ends at line 4"  $'\nline 4\n' "$body"
    assert_not_contains "no line 5 in snippet for line=1 case" $'\nline 5\n' "$body"
  )
}

# ----------------------------------------------------------------------------
# Case 14 — snippet line near EOF (upper bound clipped)
# ----------------------------------------------------------------------------
case_snippet_near_eof() {
  echo "case: snippet near EOF"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    _prtend_forge_gh_comment_info() {
      jq -c '.line = 10' "$FIXTURES/comment_info.gh.inline.json"
    }
    out="$(prtend_cmd_defer_write --pr 123 --comment 456789 \
      --reason "x" 2>/dev/null)"
    path="$(jq -r .path <<<"$out")"
    body="$(cat "$path")"
    assert_contains "snippet contains line 7"  $'\nline 7\n'  "$body"
    assert_contains "snippet contains line 10" $'\nline 10\n' "$body"
  )
}

# ----------------------------------------------------------------------------
# Case 15 — atomic-write failure → exit 1, no JSON
# ----------------------------------------------------------------------------
case_atomic_write_fail() {
  echo "case: atomic-write failure"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    prtend_atomic_write() { cat >/dev/null; return 1; }
    out="$(prtend_cmd_defer_write --pr 123 --comment 456789 \
      --reason "x" 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 1 "$rc"
    assert_eq "no JSON emitted" "" "$out"
  )
}

# ----------------------------------------------------------------------------
# Case 16 — JSON shape invariants (one happy path)
# ----------------------------------------------------------------------------
case_json_shape() {
  echo "case: JSON shape invariants"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    out="$(prtend_cmd_defer_write --pr 123 --comment 456789 \
      --reason "x" 2>/dev/null)"
    assert_eq "path is string"         '"string"' "$(jq -c '.path | type' <<<"$out")"
    assert_eq "pr is number"           '"number"' "$(jq -c '.pr | type' <<<"$out")"
    assert_eq "comment_id is string"   '"string"' "$(jq -c '.comment_id | type' <<<"$out")"
    assert_eq "comment_url is string"  '"string"' "$(jq -c '.comment_url | type' <<<"$out")"
    url="$(jq -r .comment_url <<<"$out")"
    if [[ -n "$url" ]]; then
      assert_eq "comment_url non-empty" 0 0
    else
      assert_eq "comment_url non-empty" 0 1
    fi
  )
}

case_gh_inline
case_gl_inline
case_non_inline
case_idempotent
case_comment_not_found
case_no_config
case_not_authed
case_bad_pr
case_missing_reason
case_dash_reason
case_newline_reason
case_missing_path_in_head
case_snippet_line_1
case_snippet_near_eof
case_atomic_write_fail
case_json_shape

PASS="$(grep -c '^P' "$RESULTS" || true)"
FAIL="$(grep -c '^F' "$RESULTS" || true)"
echo
echo "passed: ${PASS:-0}    failed: ${FAIL:-0}"
if (( FAIL > 0 )); then exit 1; fi
