#!/usr/bin/env bash
# test-watch.sh — covers prtend watch (multiplexer). Same harness style as
# test-ci-watch.sh / test-reviews-poll.sh: subshell isolation, forge primitives
# shadowed via function override, no real network, PRTEND_POLL_INTERVAL=0 (or
# 1 for the block-with-timeout cases).
#
# shellcheck disable=SC2030,SC2031,SC2329

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_ROOT/test/fixtures/watch"

RESULTS="$(mktemp -t prtend-watch-results.XXXXXX)"
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
  SANDBOX="$(mktemp -d -t prtend-watch.XXXXXX)"
  (
    cd "$SANDBOX" || exit
    git init -q
    git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  )
  export XDG_STATE_HOME="$SANDBOX/state"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
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
  source "$REPO_ROOT/lib/prtend/prtend-notes-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-subcommands/watch.bash"
  set +e
  export PRTEND_FORGE=github
  export PRTEND_POLL_INTERVAL=0
  _prtend_forge_gh_cli_ready() { return 0; }
}

# ----------------------------------------------------------------------------
# Case 1 — no git repo → exit 1.
# ----------------------------------------------------------------------------
case_no_git_repo() {
  echo "case: no git repo"
  (
    SANDBOX="$(mktemp -d -t prtend-watch-nogit.XXXXXX)"
    export XDG_STATE_HOME="$SANDBOX/state"
    export HOME="$SANDBOX/home"; mkdir -p "$HOME"
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/prtend/prtend-lib.bash"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/prtend/prtend-forge-lib.bash"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/prtend/prtend-subcommands/watch.bash"
    set +e
    export PRTEND_FORGE=github
    err="$(prtend_cmd_watch --pr 7 --once 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 1 "$rc"
    assert_contains "stderr" "not in a git repository" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 2 — forge unauthed → exit 3.
# ----------------------------------------------------------------------------
case_forge_unauthed() {
  echo "case: forge unauthed"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_cli_ready() { return 3; }
    prtend_cmd_watch --pr 7 --once >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 3 "$rc"
  )
}

# ----------------------------------------------------------------------------
# Case 3 — PR not found → exit 4.
# ----------------------------------------------------------------------------
case_pr_not_found() {
  echo "case: PR not found"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { return 1; }
    out="$(prtend_cmd_watch --pr 123 --once 2>/dev/null)"
    rc=$?
    err="$(prtend_cmd_watch --pr 123 --once 2>&1 1>/dev/null)"
    assert_eq "exit code" 4 "$rc"
    assert_eq "no stdout" "" "$out"
    assert_contains "stderr" "PR 123 not found" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 4 — PR already closed on entry → exit 4, no pr_closed event.
# ----------------------------------------------------------------------------
case_pr_closed_on_entry() {
  echo "case: PR closed on entry"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.closed.json"; }
    out="$(prtend_cmd_watch --pr 123 --once 2>/dev/null)"
    rc=$?
    err="$(prtend_cmd_watch --pr 123 --once 2>&1 1>/dev/null)"
    assert_eq "exit code" 4 "$rc"
    assert_eq "no stdout" "" "$out"
    assert_contains "stderr" "PR 123 is closed" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 5 — --once nothing pending → exit 0, no stdout, state unchanged.
# ----------------------------------------------------------------------------
case_once_nothing_pending() {
  echo "case: --once nothing pending"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.success.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.empty.json"; }
    # Pre-seed CI cursor so ci-watch --once sees no change.
    prtend_state_set_ci_last_state 7 success
    out="$(prtend_cmd_watch --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "no stdout" "" "$out"
    assert_eq "ci cursor unchanged" 'success' "$(prtend_state_get_ci_last_state 7)"
    assert_eq "review cursor empty" '' "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 6 — --once CI has a pending event → emit ci event, state ci.last_state advances.
# ----------------------------------------------------------------------------
case_once_ci_event() {
  echo "case: --once CI event"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.failure.json"; }
    _prtend_forge_gh_ci_failures() { cat "$FIXTURES/ci_failures.jest.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.empty.json"; }
    prtend_state_set_ci_last_state 7 running
    out="$(prtend_cmd_watch --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "type" '"ci"' "$(jq -c .type <<<"$out")"
    assert_eq "state" '"failure"' "$(jq -c .state <<<"$out")"
    assert_eq "previous_state" '"running"' "$(jq -c .previous_state <<<"$out")"
    assert_eq "ci cursor advanced" 'failure' "$(prtend_state_get_ci_last_state 7)"
    assert_eq "review cursor untouched" '' "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 7 — --once one review batch → emit, cursor advanced.
# ----------------------------------------------------------------------------
case_once_one_review() {
  echo "case: --once one review batch"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.success.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.one_batch.json"; }
    _prtend_forge_gh_review_comments() { cat "$FIXTURES/review_comments.empty.json"; }
    prtend_state_set_ci_last_state 7 success
    out="$(prtend_cmd_watch --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "type" '"review_batch"' "$(jq -c .type <<<"$out")"
    assert_eq "batch_id" '"100"' "$(jq -c .batch_id <<<"$out")"
    assert_eq "next_cursor" '"c100"' "$(jq -c .next_cursor <<<"$out")"
    assert_eq "review cursor advanced" 'c100' "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 8 — --once three review batches → first only, cursor=c100.
#          Then a second call (cursor=c100) yields batch 200 with cursor=c200.
# ----------------------------------------------------------------------------
case_once_three_reviews() {
  echo "case: --once three review batches (first only, then resume)"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.success.json"; }
    # Return three batches when cursor is empty, one batch when cursor is c100.
    _prtend_forge_gh_reviews_since() {
      local cursor="${2:-}"
      if [[ "$cursor" == "c100" ]]; then
        cat "$FIXTURES/reviews_since.from_c100.json"
      else
        cat "$FIXTURES/reviews_since.three_batches.json"
      fi
    }
    _prtend_forge_gh_review_comments() { cat "$FIXTURES/review_comments.empty.json"; }
    prtend_state_set_ci_last_state 7 success

    out="$(prtend_cmd_watch --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "first call exit" 0 "$rc"
    # Exactly one JSON line on stdout.
    line_count="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
    assert_eq "first call: one line" '1' "$line_count"
    assert_eq "first call batch_id" '"100"' "$(jq -c .batch_id <<<"$out")"
    assert_eq "first call cursor" 'c100' "$(prtend_state_get_cursor 7)"

    out="$(prtend_cmd_watch --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "second call exit" 0 "$rc"
    assert_eq "second call batch_id" '"200"' "$(jq -c .batch_id <<<"$out")"
    assert_eq "second call cursor" 'c200' "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 9 — --once both CI and review pending → CI wins (precedence).
#          Then a second call yields the review batch.
# ----------------------------------------------------------------------------
case_once_ci_precedence() {
  echo "case: --once CI precedence over review"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.failure.json"; }
    _prtend_forge_gh_ci_failures() { cat "$FIXTURES/ci_failures.jest.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.one_batch.json"; }
    _prtend_forge_gh_review_comments() { cat "$FIXTURES/review_comments.empty.json"; }
    prtend_state_set_ci_last_state 7 running

    out="$(prtend_cmd_watch --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "first call exit" 0 "$rc"
    assert_eq "first call: ci" '"ci"' "$(jq -c .type <<<"$out")"
    assert_eq "review cursor still empty" '' "$(prtend_state_get_cursor 7)"
    assert_eq "ci cursor advanced" 'failure' "$(prtend_state_get_ci_last_state 7)"

    out="$(prtend_cmd_watch --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "second call exit" 0 "$rc"
    assert_eq "second call: review" '"review_batch"' "$(jq -c .type <<<"$out")"
    assert_eq "review cursor now" 'c100' "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 10 — --once both silent, but a fresh pr_state probe shows closed.
#           Watch's mid-loop re-check fires pr_closed; state is removed.
# ----------------------------------------------------------------------------
case_once_pr_closed_during_recheck() {
  echo "case: --once pr_closed via mid-loop re-check"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    # pr_state probes in iteration 1: watch preflight (n=0), ci-watch
    # preflight (n=1), reviews-poll preflight (n=2) all return open. The
    # watch mid-loop re-check (n=3) returns closed.
    counter="$SANDBOX/pr-state-counter"; printf '0' > "$counter"
    _prtend_forge_gh_pr_state() {
      local n; n=$(cat "$counter"); printf '%d' $(( n + 1 )) > "$counter"
      if (( n < 3 )); then cat "$FIXTURES/pr_state.open.json"
      else cat "$FIXTURES/pr_state.closed.json"; fi
    }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.success.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.empty.json"; }
    prtend_state_set_ci_last_state 7 success

    out="$(prtend_cmd_watch --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "type" '"pr_closed"' "$(jq -c .type <<<"$out")"
    assert_eq "pr" '7' "$(jq -c .pr <<<"$out")"
    assert_eq "final_state" '"closed"' "$(jq -c .final_state <<<"$out")"
    assert_eq "closed_at" '"2026-05-31T20:14:02Z"' "$(jq -c .closed_at <<<"$out")"
    state_path="$(prtend_state_path 7)"
    if [[ -f "$state_path" ]]; then
      assert_eq "state file removed" "absent" "present"
    else
      assert_eq "state file removed" "absent" "absent"
    fi
  )
}

# ----------------------------------------------------------------------------
# Case 11 — --once: ci-watch child returns 4 (PR closed between our preflight
#           and the child's). Watch synthesizes pr_closed and clears state.
# ----------------------------------------------------------------------------
case_once_ci_child_rc4() {
  echo "case: --once ci-watch child rc=4 → pr_closed"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    # Watch's preflight (call 1) → open; ci-watch's preflight (call 2) → merged.
    counter="$SANDBOX/pr-state-counter"; printf '0' > "$counter"
    _prtend_forge_gh_pr_state() {
      local n; n=$(cat "$counter"); printf '%d' $(( n + 1 )) > "$counter"
      if (( n == 0 )); then cat "$FIXTURES/pr_state.open.json"
      else cat "$FIXTURES/pr_state.merged.json"; fi
    }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.success.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.empty.json"; }

    out="$(prtend_cmd_watch --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "type" '"pr_closed"' "$(jq -c .type <<<"$out")"
    assert_eq "final_state" '"open"' "$(jq -c .final_state <<<"$out")"
    # final_state is from the watch preflight's snapshot (last good probe)
    # — we synthesize the event from the most recent pr_state_json, which in
    # this path is still the preflight one. This matches the implementation's
    # contract: it doesn't re-probe inside the child-rc=4 branch.
  )
}

# ----------------------------------------------------------------------------
# Case 12 — --block --timeout 2, nothing ever happens → exits ~2s, no output.
# ----------------------------------------------------------------------------
case_block_timeout_clean() {
  echo "case: --block --timeout clean timeout"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    export PRTEND_POLL_INTERVAL=1
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.success.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.empty.json"; }
    prtend_state_set_ci_last_state 7 success
    t0="$SECONDS"
    out="$(prtend_cmd_watch --pr 7 --block --timeout 2 2>/dev/null)"
    rc=$?
    t1="$SECONDS"
    elapsed=$(( t1 - t0 ))
    assert_eq "exit code" 0 "$rc"
    assert_eq "no stdout" "" "$out"
    if (( elapsed >= 1 && elapsed <= 4 )); then
      assert_eq "elapsed in range" "1..4" "1..4"
    else
      assert_eq "elapsed in range" "1..4" "$elapsed"
    fi
  )
}

# ----------------------------------------------------------------------------
# Case 13 — --block --timeout 5, review batch appears on iteration 2.
# ----------------------------------------------------------------------------
case_block_review_on_iter_2() {
  echo "case: --block review batch appears on iter 2"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    export PRTEND_POLL_INTERVAL=1
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.success.json"; }
    counter="$SANDBOX/reviews-counter"; printf '0' > "$counter"
    _prtend_forge_gh_reviews_since() {
      local n; n=$(cat "$counter"); printf '%d' $(( n + 1 )) > "$counter"
      if (( n == 0 )); then cat "$FIXTURES/reviews_since.empty.json"
      else cat "$FIXTURES/reviews_since.one_batch.json"; fi
    }
    _prtend_forge_gh_review_comments() { cat "$FIXTURES/review_comments.empty.json"; }
    prtend_state_set_ci_last_state 7 success

    out="$(prtend_cmd_watch --pr 7 --block --timeout 5 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "type" '"review_batch"' "$(jq -c .type <<<"$out")"
    assert_eq "cursor advanced" 'c100' "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 14 — --block, PR closes after iteration 1 → pr_closed event.
# ----------------------------------------------------------------------------
case_block_pr_closes() {
  echo "case: --block PR closes after iter 1"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    export PRTEND_POLL_INTERVAL=1
    # Watch preflight (1), ci-watch iter1 preflight (2), watch re-check iter1 (3)
    # all return open. From call 4 on, return closed (ci-watch iter2 preflight).
    counter="$SANDBOX/pr-state-counter"; printf '0' > "$counter"
    _prtend_forge_gh_pr_state() {
      local n; n=$(cat "$counter"); printf '%d' $(( n + 1 )) > "$counter"
      if (( n < 3 )); then cat "$FIXTURES/pr_state.open.json"
      else cat "$FIXTURES/pr_state.closed.json"; fi
    }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.success.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.empty.json"; }
    prtend_state_set_ci_last_state 7 success

    out="$(prtend_cmd_watch --pr 7 --block --timeout 10 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "type" '"pr_closed"' "$(jq -c .type <<<"$out")"
    state_path="$(prtend_state_path 7)"
    if [[ -f "$state_path" ]]; then
      assert_eq "state file removed" "absent" "present"
    else
      assert_eq "state file removed" "absent" "absent"
    fi
  )
}

# ----------------------------------------------------------------------------
# Case 15 — --once, prtend_state_clear fails (read-only state dir). The
#           pr_closed event still reaches stdout; a warning lands on stderr.
# ----------------------------------------------------------------------------
case_state_clear_failure() {
  echo "case: state_clear failure still emits event"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    counter="$SANDBOX/pr-state-counter"; printf '0' > "$counter"
    _prtend_forge_gh_pr_state() {
      local n; n=$(cat "$counter"); printf '%d' $(( n + 1 )) > "$counter"
      if (( n < 2 )); then cat "$FIXTURES/pr_state.open.json"
      else cat "$FIXTURES/pr_state.closed.json"; fi
    }
    _prtend_forge_gh_ci_status() { cat "$FIXTURES/ci_status.success.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.empty.json"; }
    prtend_state_set_ci_last_state 7 success

    # Override prtend_state_clear to simulate failure.
    prtend_state_clear() { return 1; }

    err_file="$(mktemp -t prtend-watch-err.XXXXXX)"
    out="$(prtend_cmd_watch --pr 7 --once 2>"$err_file")"
    rc=$?
    err="$(cat "$err_file")"
    rm -f "$err_file"
    assert_eq "exit code" 0 "$rc"
    assert_eq "type" '"pr_closed"' "$(jq -c .type <<<"$out")"
    assert_contains "warning on stderr" "failed to clear state for PR 7" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 16 — flag parsing rejections (smoke).
# ----------------------------------------------------------------------------
case_flag_rejections() {
  echo "case: flag parsing rejections"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    err="$(prtend_cmd_watch 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "missing --pr exit" 2 "$rc"
    assert_contains "missing --pr msg" "--pr is required" "$err"

    err="$(prtend_cmd_watch --pr abc --once 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "non-numeric --pr exit" 2 "$rc"
    assert_contains "non-numeric --pr msg" "positive integer" "$err"

    err="$(prtend_cmd_watch --pr 1 --once --block 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "--once --block exit" 2 "$rc"
    assert_contains "--once --block msg" "mutually exclusive" "$err"

    err="$(prtend_cmd_watch --pr 1 --once --timeout 30 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "--once --timeout exit" 2 "$rc"
    assert_contains "--once --timeout msg" "mutually exclusive" "$err"

    err="$(prtend_cmd_watch --pr 1 --timeout 0 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "--timeout 0 exit" 2 "$rc"
    assert_contains "--timeout 0 msg" "positive integer" "$err"

    err="$(prtend_cmd_watch --pr 1 --bogus 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "unknown flag exit" 2 "$rc"
  )
}

case_no_git_repo
case_forge_unauthed
case_pr_not_found
case_pr_closed_on_entry
case_once_nothing_pending
case_once_ci_event
case_once_one_review
case_once_three_reviews
case_once_ci_precedence
case_once_pr_closed_during_recheck
case_once_ci_child_rc4
case_block_timeout_clean
case_block_review_on_iter_2
case_block_pr_closes
case_state_clear_failure
case_flag_rejections

PASS="$(grep -c '^P' "$RESULTS" || true)"
FAIL="$(grep -c '^F' "$RESULTS" || true)"
echo
echo "passed: ${PASS:-0}    failed: ${FAIL:-0}"
if (( FAIL > 0 )); then exit 1; fi
