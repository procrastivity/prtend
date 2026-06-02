#!/usr/bin/env bash
# test-reviews-poll.sh — covers prtend reviews-poll. Mirrors test-ci-watch.sh:
# subshell isolation, forge primitives shadowed via function override, no real
# network, no real sleep loops (PRTEND_POLL_INTERVAL=0).
#
# shellcheck disable=SC2030,SC2031,SC2329

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_ROOT/test/fixtures/reviews_poll"

RESULTS="$(mktemp -t prtend-rp-results.XXXXXX)"
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
  SANDBOX="$(mktemp -d -t prtend-rp.XXXXXX)"
  (
    cd "$SANDBOX" || exit
    git init -q
    mkdir -p src
    # 20-line file so line=10 is valid and line=9999 is stale.
    seq 1 20 > src/widget.ts
    git -c user.email=t@example.com -c user.name=t add src/widget.ts
    git -c user.email=t@example.com -c user.name=t commit -q -m init
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
  source "$REPO_ROOT/lib/prtend/prtend-subcommands/reviews_poll.bash"
  set +e
  export PRTEND_FORGE=github
  export PRTEND_POLL_INTERVAL=0
  _prtend_forge_gh_cli_ready() { return 0; }
}

# ----------------------------------------------------------------------------
# Case 1 — --once empty: no output, no cursor write, exit 0.
# ----------------------------------------------------------------------------
case_once_empty() {
  echo "case: --once empty response"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.empty.json"; }
    out="$(prtend_cmd_reviews_poll --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "no output" "" "$out"
    assert_eq "no cursor written" "" "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 2 — --once one batch with stale anchor + handled reply.
# ----------------------------------------------------------------------------
case_once_one_batch() {
  echo "case: --once one batch (stale + handled)"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.one_batch.json"; }
    _prtend_forge_gh_review_comments() { cat "$FIXTURES/review_comments.batch_a.json"; }
    # 1002's thread has a marker-bearing reply (posted by a prior note-post);
    # 1001's thread is unhandled.
    _prtend_forge_gh_review_thread_bodies() {
      local id="$2"
      if [[ "$id" == "1002" ]]; then cat "$FIXTURES/thread_bodies.handled.txt"
      else cat "$FIXTURES/thread_bodies.unhandled.txt"; fi
    }
    prtend_state_set_cursor 7 "5" >/dev/null
    out="$(prtend_cmd_reviews_poll --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "type"               '"review_batch"'        "$(jq -c .type <<<"$out")"
    assert_eq "pr"                 '7'                     "$(jq -c .pr <<<"$out")"
    assert_eq "batch_id"           '"100"'                 "$(jq -c .batch_id <<<"$out")"
    assert_eq "review_state"       '"changes_requested"'   "$(jq -c .review_state <<<"$out")"
    assert_eq "comments count"     '2'                     "$(jq -c '.comments | length' <<<"$out")"
    assert_eq "comments[0].anchor_stale"    'true'         "$(jq -c '.comments[0].anchor_stale' <<<"$out")"
    assert_eq "comments[1].anchor_stale"    'false'        "$(jq -c '.comments[1].anchor_stale' <<<"$out")"
    assert_eq "comments[1].already_handled" 'true'         "$(jq -c '.comments[1].already_handled' <<<"$out")"
    assert_eq "next_cursor"        '"100"'                 "$(jq -c .next_cursor <<<"$out")"
    assert_eq "cursor written"     '100'                   "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 3 — --once two batches: two events, same next_cursor, one cursor write.
# ----------------------------------------------------------------------------
case_once_two_batches() {
  echo "case: --once two batches"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.two_batches.json"; }
    _prtend_forge_gh_review_comments() {
      local batch_id="$2"
      if [[ "$batch_id" == "100" ]]; then cat "$FIXTURES/review_comments.batch_a.json"
      else cat "$FIXTURES/review_comments.batch_b.json"; fi
    }
    _prtend_forge_gh_review_thread_bodies() { cat "$FIXTURES/thread_bodies.unhandled.txt"; }
    out="$(prtend_cmd_reviews_poll --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    # Two lines of JSON; both .type == review_batch; both .next_cursor == "200".
    assert_eq "event count" 2 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
    assert_eq "first batch_id"  '"100"' "$(printf '%s\n' "$out" | sed -n 1p | jq -c .batch_id)"
    assert_eq "second batch_id" '"200"' "$(printf '%s\n' "$out" | sed -n 2p | jq -c .batch_id)"
    assert_eq "first next_cursor"  '"200"' "$(printf '%s\n' "$out" | sed -n 1p | jq -c .next_cursor)"
    assert_eq "second next_cursor" '"200"' "$(printf '%s\n' "$out" | sed -n 2p | jq -c .next_cursor)"
    assert_eq "cursor written" '200' "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 4 — --once --cursor abc → emits, but NO cursor write to state.
# ----------------------------------------------------------------------------
case_once_explicit_cursor() {
  echo "case: --once --cursor (read-only)"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.one_batch.json"; }
    _prtend_forge_gh_review_comments() { cat "$FIXTURES/review_comments.batch_a.json"; }
    _prtend_forge_gh_review_thread_bodies() { cat "$FIXTURES/thread_bodies.unhandled.txt"; }
    out="$(prtend_cmd_reviews_poll --pr 7 --once --cursor abc 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "emitted one event" 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
    assert_eq "cursor NOT written" "" "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 5 — --block: first poll empty, second has a batch → emits, exits 0.
# ----------------------------------------------------------------------------
case_block_then_batch() {
  echo "case: --block then batch"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    counter="$SANDBOX/rs-counter"; printf '0' > "$counter"
    _prtend_forge_gh_reviews_since() {
      local n; n=$(cat "$counter"); printf '%d' $(( n + 1 )) > "$counter"
      if (( n == 0 )); then cat "$FIXTURES/reviews_since.empty.json"
      else cat "$FIXTURES/reviews_since.one_batch.json"; fi
    }
    _prtend_forge_gh_review_comments() { cat "$FIXTURES/review_comments.batch_a.json"; }
    _prtend_forge_gh_review_thread_bodies() { cat "$FIXTURES/thread_bodies.unhandled.txt"; }
    out="$(prtend_cmd_reviews_poll --pr 7 --block 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "batch_id" '"100"' "$(jq -c .batch_id <<<"$out")"
    assert_eq "cursor written" '100' "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 6 — --block --timeout 1: always empty → exit 0 with no output, no write.
# ----------------------------------------------------------------------------
case_block_timeout_clean() {
  echo "case: --block --timeout clean timeout"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    export PRTEND_POLL_INTERVAL=1
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.empty.json"; }
    out="$(prtend_cmd_reviews_poll --pr 7 --block --timeout 1 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "no output" "" "$out"
    assert_eq "cursor unwritten" "" "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 7 — --once against a closed PR → exit 4, no output.
# ----------------------------------------------------------------------------
case_pr_closed_on_entry() {
  echo "case: PR closed on entry"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.closed.json"; }
    err="$(prtend_cmd_reviews_poll --pr 7 --once 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 4 "$rc"
    assert_contains "stderr" "is closed" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 8 — --block: PR closes mid-loop → exit 4, no output.
# ----------------------------------------------------------------------------
case_pr_closed_mid_loop() {
  echo "case: PR closed mid-loop"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    counter="$SANDBOX/ps-counter"; printf '0' > "$counter"
    _prtend_forge_gh_pr_state() {
      local n; n=$(cat "$counter"); printf '%d' $(( n + 1 )) > "$counter"
      if (( n == 0 )); then cat "$FIXTURES/pr_state.open.json"
      else cat "$FIXTURES/pr_state.merged.json"; fi
    }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.empty.json"; }
    err="$(prtend_cmd_reviews_poll --pr 7 --block 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 4 "$rc"
    assert_contains "stderr" "closed during poll" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 9 — non-numeric --pr → exit 2.
# ----------------------------------------------------------------------------
case_bad_pr() {
  echo "case: bad --pr"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    prtend_cmd_reviews_poll --pr foo --once >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 2 "$rc"
  )
}

# ----------------------------------------------------------------------------
# Case 10 — --once --block → exit 2.
# ----------------------------------------------------------------------------
case_mutex() {
  echo "case: --once and --block conflict"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    err="$(prtend_cmd_reviews_poll --pr 1 --once --block 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 2 "$rc"
    assert_contains "stderr" "mutually exclusive" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 11 — anchor staleness against the sandbox HEAD.
# ----------------------------------------------------------------------------
case_anchor_stale_combinations() {
  echo "case: anchor stale combinations"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    # Caches must be declared in the dynamic-scope caller of the helper.
    # shellcheck disable=SC2034
    declare -A path_exists_cache=() path_lines_cache=()
    _reviews_poll_anchor_stale "" 10
    assert_eq "empty path"            'false' "$_PRTEND_REVIEWS_POLL_RET"
    _reviews_poll_anchor_stale src/widget.ts null
    assert_eq "null line"             'false' "$_PRTEND_REVIEWS_POLL_RET"
    _reviews_poll_anchor_stale src/widget.ts 10
    assert_eq "existing path/in-range" 'false' "$_PRTEND_REVIEWS_POLL_RET"
    _reviews_poll_anchor_stale src/widget.ts 9999
    assert_eq "existing path/out-of-range" 'true' "$_PRTEND_REVIEWS_POLL_RET"
    _reviews_poll_anchor_stale does/not/exist.ts 1
    assert_eq "missing path"          'true'  "$_PRTEND_REVIEWS_POLL_RET"
  )
}

# ----------------------------------------------------------------------------
# Case 12 — already_handled walks the *thread* (not the batch's sibling
# comment_ids) AND caches by comment_id. The marker lives on a reply that
# does NOT appear in `comment_ids` — a sibling walk would miss it. We also
# assert each projected comment id is fetched at most once.
# ----------------------------------------------------------------------------
case_already_handled_thread_walk() {
  echo "case: already_handled via thread walk"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.cache_batch.json"; }
    _prtend_forge_gh_review_comments() { cat "$FIXTURES/review_comments.cache_batch.json"; }
    # Both projected comment ids resolve to a thread with a marker-bearing
    # reply. Count calls per id to verify the per-batch cache.
    fetches="$SANDBOX/fetches"; : > "$fetches"
    _prtend_forge_gh_review_thread_bodies() {
      local id="$2"
      printf '%s\n' "$id" >> "$fetches"
      cat "$FIXTURES/thread_bodies.handled.txt"
    }
    out="$(prtend_cmd_reviews_poll --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "all projected handled" 'true' \
      "$(jq -c '[.comments[].already_handled] | all' <<<"$out")"
    # Each projected id fetched exactly once (no repeat lookups).
    assert_eq "3001 fetched once" 1 "$(grep -c '^3001$' "$fetches")"
    assert_eq "3002 fetched once" 1 "$(grep -c '^3002$' "$fetches")"
    assert_eq "3003 fetched once" 1 "$(grep -c '^3003$' "$fetches")"
    # 3999 is the reply id (lives inside the thread body); we never query it
    # directly, which is the whole point of using thread_bodies over a
    # sibling walk.
    assert_eq "3999 never queried directly" 0 "$(grep -c '^3999$' "$fetches")"
  )
}

case_once_empty
case_once_one_batch
case_once_two_batches
case_once_explicit_cursor
case_block_then_batch
case_block_timeout_clean
case_pr_closed_on_entry
case_pr_closed_mid_loop
case_bad_pr
case_mutex
case_anchor_stale_combinations
case_already_handled_thread_walk

PASS="$(grep -c '^P' "$RESULTS" || true)"
FAIL="$(grep -c '^F' "$RESULTS" || true)"
echo
echo "passed: ${PASS:-0}    failed: ${FAIL:-0}"
if (( FAIL > 0 )); then exit 1; fi
