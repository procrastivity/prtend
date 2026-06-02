#!/usr/bin/env bash
# test-ci-watch.sh — covers prtend ci-watch and prtend-signature-lib.
# Same harness style as test-defer-write.sh: subshell isolation, forge
# primitives shadowed via function override, no real network, no real sleep.
#
# shellcheck disable=SC2030,SC2031,SC2329

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_ROOT/test/fixtures/ci_watch"

RESULTS="$(mktemp -t prtend-ciw-results.XXXXXX)"
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
  SANDBOX="$(mktemp -d -t prtend-ciw.XXXXXX)"
  (
    cd "$SANDBOX" || exit
    git init -q
    git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  )
  # XDG_STATE_HOME drives prtend_state_dir → predictable on-disk location.
  export XDG_STATE_HOME="$SANDBOX/state"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  # Repo slug for state dir naming; resolves through git remote → none here.
  # prtend_state_dir falls back to "<repo>/.claude/prtend-state" if there's no
  # slug. Add a remote so slug resolution succeeds and state lands under
  # XDG_STATE_HOME/prtend/<slug>/.
  (cd "$SANDBOX" && git remote add origin "https://github.com/o/test-${RANDOM}.git")
  unset PRTEND_FORGE
}

load_libs() {
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-forge-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-state-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-subcommands/ci_watch.bash"
  set +e
  export PRTEND_FORGE=github
  export PRTEND_POLL_INTERVAL=0
  _prtend_forge_gh_cli_ready() { return 0; }
}

# ----------------------------------------------------------------------------
# Case 1 — --once with no prior state, sampled state success → emit one event.
# ----------------------------------------------------------------------------
case_once_no_prior_success() {
  echo "case: --once no prior state, success"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.success.json"; }
    out="$(prtend_cmd_ci_watch --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "type"           '"ci"'     "$(jq -c .type <<<"$out")"
    assert_eq "pr"             '7'        "$(jq -c .pr <<<"$out")"
    assert_eq "state"          '"success"' "$(jq -c .state <<<"$out")"
    assert_eq "previous_state" 'null'     "$(jq -c .previous_state <<<"$out")"
    assert_eq "no failures key" 'false'   "$(jq -c 'has("failures")' <<<"$out")"
    assert_eq "checks count"   '2'        "$(jq -c '.checks | length' <<<"$out")"
    # Cursor written.
    assert_eq "cursor persisted" 'success' "$(prtend_state_get_ci_last_state 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 2 — --once prior=sampled → no output, no cursor write, no counter bump.
# ----------------------------------------------------------------------------
case_once_no_change() {
  echo "case: --once no change"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.success.json"; }
    # Pre-seed cursor.
    prtend_state_set_ci_last_state 7 success
    out="$(prtend_cmd_ci_watch --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "no output" "" "$out"
    assert_eq "cursor unchanged" 'success' "$(prtend_state_get_ci_last_state 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 3 — --once prior=running, sampled=failure → emit, failures + counter.
# ----------------------------------------------------------------------------
case_once_running_to_failure() {
  echo "case: --once running → failure"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.failure.json"; }
    _prtend_forge_gh_ci_failures() { cat "$FIXTURES/ci_failures.jest.json"; }
    prtend_state_set_ci_last_state 7 running
    out="$(prtend_cmd_ci_watch --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "state"           '"failure"'    "$(jq -c .state <<<"$out")"
    assert_eq "previous_state"  '"running"'    "$(jq -c .previous_state <<<"$out")"
    assert_eq "failures count"  '1'            "$(jq -c '.failures | length' <<<"$out")"
    assert_eq "failure signature" '"jest:widget.test.ts:42-NaN"' "$(jq -c '.failures[0].signature' <<<"$out")"
    assert_eq "cursor persisted" 'failure'     "$(prtend_state_get_ci_last_state 7)"
    assert_eq "attempt counter"  '1'           "$(prtend_state_ci_attempts 7 'jest:widget.test.ts:42-NaN')"
  )
}

# ----------------------------------------------------------------------------
# Case 4 — --block: entry matches; next poll iteration flips to failure.
# ----------------------------------------------------------------------------
case_block_then_flip() {
  echo "case: --block flips on next poll"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    # First call (entry sample) returns running; subsequent calls (inside
    # the watch loop) return failure. We use a counter file to step through.
    counter="$SANDBOX/ci-status-counter"; printf '0' > "$counter"
    _prtend_forge_gh_ci_status() {
      local n; n=$(cat "$counter"); printf '%d' $(( n + 1 )) > "$counter"
      if (( n == 0 )); then cat "$FIXTURES/ci_status.running.json"
      else cat "$FIXTURES/ci_status.failure.json"; fi
    }
    _prtend_forge_gh_ci_failures() { cat "$FIXTURES/ci_failures.jest.json"; }
    prtend_state_set_ci_last_state 7 running
    out="$(prtend_cmd_ci_watch --pr 7 --block 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "state"           '"failure"' "$(jq -c .state <<<"$out")"
    assert_eq "previous_state"  '"running"' "$(jq -c .previous_state <<<"$out")"
    assert_eq "failure signature" '"jest:widget.test.ts:42-NaN"' "$(jq -c '.failures[0].signature' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 5 — --block --timeout 1: state never flips → clean timeout (exit 0, no out).
# ----------------------------------------------------------------------------
case_block_timeout_clean() {
  echo "case: --block --timeout clean timeout"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    export PRTEND_POLL_INTERVAL=1
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.running.json"; }
    prtend_state_set_ci_last_state 7 running
    out="$(prtend_cmd_ci_watch --pr 7 --block --timeout 1 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "no output" "" "$out"
    assert_eq "cursor unchanged" 'running' "$(prtend_state_get_ci_last_state 7)"
    assert_eq "no counter" '0' "$(prtend_state_ci_attempts 7 'jest:widget.test.ts:42-NaN')"
  )
}

# ----------------------------------------------------------------------------
# Case 6 — --once against an already-closed PR → exit 4, no output.
# ----------------------------------------------------------------------------
case_pr_closed_on_entry() {
  echo "case: PR closed on entry"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.closed.json"; }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.success.json"; }
    err="$(prtend_cmd_ci_watch --pr 7 --once 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 4 "$rc"
    assert_contains "stderr" "is closed" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 7 — --block: PR closes mid-watch → exit 4, no output.
# ----------------------------------------------------------------------------
case_pr_closed_mid_watch() {
  echo "case: PR closed mid-watch"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    # First pr_state call (entry pre-flight) → open; subsequent (inside
    # watch loop) → closed.
    counter="$SANDBOX/pr-state-counter"; printf '0' > "$counter"
    _prtend_forge_gh_pr_state() {
      local n; n=$(cat "$counter"); printf '%d' $(( n + 1 )) > "$counter"
      if (( n == 0 )); then cat "$FIXTURES/pr_state.open.json"
      else cat "$FIXTURES/pr_state.closed.json"; fi
    }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.running.json"; }
    prtend_state_set_ci_last_state 7 running
    err="$(prtend_cmd_ci_watch --pr 7 --block 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 4 "$rc"
    assert_contains "stderr" "closed during watch" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 8 — --pr foo → exit 2.
# ----------------------------------------------------------------------------
case_bad_pr() {
  echo "case: bad --pr"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    prtend_cmd_ci_watch --pr foo --once >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 2 "$rc"
  )
}

# ----------------------------------------------------------------------------
# Case 9 — --once --block → exit 2 with mutual-exclusion message.
# ----------------------------------------------------------------------------
case_once_and_block() {
  echo "case: --once and --block conflict"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    err="$(prtend_cmd_ci_watch --pr 1 --once --block 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 2 "$rc"
    assert_contains "stderr" "mutually exclusive" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 10 — signature-lib unit tests for every fixture.
# ----------------------------------------------------------------------------
case_signature_lib() {
  echo "case: signature lib heuristics"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    # Signature lib is sourced transitively via forge-lib, so just load_libs
    # and call the function directly.
    load_libs
    local tool actual expected
    for tool in jest vitest eslint tsc mypy pytest go cargo shellcheck unknown; do
      # Use a distinctive check name for the fallback heuristic.
      if [[ "$tool" == "unknown" ]]; then
        actual="$(prtend_signature_from_log custom-check "$FIXTURES/log.${tool}.txt")"
      else
        actual="$(prtend_signature_from_log custom-check "$FIXTURES/log.${tool}.txt")"
      fi
      expected="$(cat "$FIXTURES/log.${tool}.expected.sig")"
      assert_eq "signature: $tool" "$expected" "$actual"
    done
  )
}

case_once_no_prior_success
case_once_no_change
case_once_running_to_failure
case_block_then_flip
case_block_timeout_clean
case_pr_closed_on_entry
case_pr_closed_mid_watch
case_bad_pr
case_once_and_block
case_signature_lib

PASS="$(grep -c '^P' "$RESULTS" || true)"
FAIL="$(grep -c '^F' "$RESULTS" || true)"
echo
echo "passed: ${PASS:-0}    failed: ${FAIL:-0}"
if (( FAIL > 0 )); then exit 1; fi
