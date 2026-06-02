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
    assert_eq "next_cursor"        '"2026-01-01T00:00:00Z|100"' "$(jq -c .next_cursor <<<"$out")"
    assert_eq "cursor written"     '2026-01-01T00:00:00Z|100'   "$(prtend_state_get_cursor 7)"
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
    # Per-event next_cursor is each batch's own resume_cursor, not the
    # across-call max — a consumer that drops the second event can still
    # resume from the first event's next_cursor and pick up batch 200 next.
    assert_eq "first next_cursor"  '"2026-01-01T00:00:00Z|100"' "$(printf '%s\n' "$out" | sed -n 1p | jq -c .next_cursor)"
    assert_eq "second next_cursor" '"2026-01-02T00:00:00Z|200"' "$(printf '%s\n' "$out" | sed -n 2p | jq -c .next_cursor)"
    assert_eq "cursor written" '2026-01-02T00:00:00Z|200' "$(prtend_state_get_cursor 7)"
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
    assert_eq "cursor written" '2026-01-01T00:00:00Z|100' "$(prtend_state_get_cursor 7)"
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

# ----------------------------------------------------------------------------
# Case 13 — review_thread_bodies fails with exit 2 (not exit 1 / id-unknown):
# the poll must abort, NOT downgrade the comment to already_handled=false
# (which would let a watch loop double-post on a thread that's actually
# already been replied to).
# ----------------------------------------------------------------------------
case_thread_bodies_hard_failure() {
  echo "case: thread_bodies hard failure aborts"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_reviews_since() { cat "$FIXTURES/reviews_since.one_batch.json"; }
    _prtend_forge_gh_review_comments() { cat "$FIXTURES/review_comments.batch_a.json"; }
    _prtend_forge_gh_review_thread_bodies() { return 2; }
    out="$(prtend_cmd_reviews_poll --pr 7 --once 2>/dev/null)"
    rc=$?
    assert_eq "exit code propagated" 2 "$rc"
    assert_eq "no event emitted" "" "$out"
    assert_eq "cursor not advanced" "" "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 14 — --block --timeout: a batch that arrives at-or-after the deadline
# must NOT be emitted (timeout contract is exit 0 / no output / no cursor
# write, with no one-more-peek). The mock returns empty for the first poll
# and a batch on the second; PRTEND_POLL_INTERVAL is large enough that the
# second poll happens past the timeout.
# ----------------------------------------------------------------------------
case_block_timeout_no_late_emit() {
  echo "case: --block --timeout no late emit"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    export PRTEND_POLL_INTERVAL=2
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    counter="$SANDBOX/rs-counter"; printf '0' > "$counter"
    _prtend_forge_gh_reviews_since() {
      local n; n=$(cat "$counter"); printf '%d' $(( n + 1 )) > "$counter"
      if (( n == 0 )); then cat "$FIXTURES/reviews_since.empty.json"
      else cat "$FIXTURES/reviews_since.one_batch.json"; fi
    }
    _prtend_forge_gh_review_comments() { cat "$FIXTURES/review_comments.batch_a.json"; }
    _prtend_forge_gh_review_thread_bodies() { cat "$FIXTURES/thread_bodies.unhandled.txt"; }
    out="$(prtend_cmd_reviews_poll --pr 7 --block --timeout 1 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "no late event" "" "$out"
    assert_eq "cursor not advanced" "" "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 15 — --block with multiple pending batches must emit exactly ONE
# event per cli-contract.md § "Output discipline" (streamed commands), and
# the state cursor must advance only past that one batch, leaving the
# remaining batches for the next call.
# ----------------------------------------------------------------------------
case_block_emits_one_of_many() {
  echo "case: --block emits one of many pending"
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
    out="$(prtend_cmd_reviews_poll --pr 7 --block 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "event count" 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
    assert_eq "emitted first batch" '"100"' "$(jq -c .batch_id <<<"$out")"
    assert_eq "event next_cursor"   '"2026-01-01T00:00:00Z|100"' "$(jq -c .next_cursor <<<"$out")"
    # Cursor advanced past batch 100 only — batch 200 is left for next call.
    assert_eq "state cursor"        '2026-01-01T00:00:00Z|100'   "$(prtend_state_get_cursor 7)"
  )
}

# ----------------------------------------------------------------------------
# Case 16 — GitHub forge: cursor is (submitted_at, id), NOT id alone.
# Emission order is by submitted_at then id; the across-call next_cursor is
# the last batch's compound resume_cursor. id-only cursoring would lose a
# late-submitted lower-id draft (see case 16b).
# ----------------------------------------------------------------------------
case_gh_reviews_since_id_order() {
  echo "case: gh reviews_since uses (submitted_at, id) cursor"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    # Two reviews: id=200 submitted Monday (earliest), id=100 submitted
    # Tuesday (lower id, later submission). The new compound cursor must
    # emit id=200 first (earliest submitted_at) and write a cursor that
    # still admits id=100 on the next call.
    _prtend_forge_gh_repo_slug() { echo "o/r"; }
    gh() {
      case "$*" in
        *"/reviews "*|*"/reviews"*)
          if [[ "$*" == *"/reviews/"*"/comments"* ]]; then
            echo '[]'
          else
            cat <<'JSON'
[
  {"id":200,"submitted_at":"2026-01-01T00:00:00Z","user":{"login":"alice"},"state":"COMMENTED"},
  {"id":100,"submitted_at":"2026-01-02T00:00:00Z","user":{"login":"bob"},"state":"APPROVED"}
]
JSON
          fi ;;
        *) echo "unexpected gh args: $*" >&2; return 1 ;;
      esac
    }
    out="$(_prtend_forge_gh_reviews_since 7 "")"
    # Emission order is submitted_at ascending: 200 (Mon) before 100 (Tue).
    assert_eq "first batch_id"     '"200"' "$(jq -c '.batches[0].batch_id' <<<"$out")"
    assert_eq "second batch_id"    '"100"' "$(jq -c '.batches[1].batch_id' <<<"$out")"
    assert_eq "first resume_cursor"  '"2026-01-01T00:00:00Z|200"' "$(jq -c '.batches[0].resume_cursor' <<<"$out")"
    assert_eq "second resume_cursor" '"2026-01-02T00:00:00Z|100"' "$(jq -c '.batches[1].resume_cursor' <<<"$out")"
    assert_eq "across-call next_cursor" '"2026-01-02T00:00:00Z|100"' "$(jq -c '.next_cursor' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 16b — GitHub late-submitted draft: id=100 was drafted before id=200
# but its `submitted_at` arrives AFTER prtend has already processed id=200.
# The id-only cursor model would skip id=100 forever (`.id > 200` filters
# it out). The compound cursor must include it on the next call.
# ----------------------------------------------------------------------------
case_gh_reviews_since_late_draft() {
  echo "case: gh late-submitted draft is not skipped"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_repo_slug() { echo "o/r"; }
    # First call: only id=200 exists in the API (the draft hasn't been
    # submitted yet, so the reviews endpoint doesn't surface it).
    state_file="$SANDBOX/gh-state"; printf '1' > "$state_file"
    gh() {
      local n; n="$(cat "$state_file")"
      case "$*" in
        *"/reviews/"*"/comments"*) echo '[]' ;;
        *"/reviews"*)
          if [[ "$n" == "1" ]]; then
            echo '[{"id":200,"submitted_at":"2026-01-01T00:00:00Z","user":{"login":"alice"},"state":"COMMENTED"}]'
          else
            cat <<'JSON'
[
  {"id":200,"submitted_at":"2026-01-01T00:00:00Z","user":{"login":"alice"},"state":"COMMENTED"},
  {"id":100,"submitted_at":"2026-01-02T00:00:00Z","user":{"login":"bob"},"state":"APPROVED"}
]
JSON
          fi ;;
        *) return 1 ;;
      esac
    }
    out1="$(_prtend_forge_gh_reviews_since 7 "")"
    first_cursor="$(jq -r .next_cursor <<<"$out1")"
    assert_eq "first call cursor" '2026-01-01T00:00:00Z|200' "$first_cursor"
    # Now the draft (id=100) gets submitted and appears in the API. Feed
    # the previous cursor back. With id-only cursoring, id=100 would be
    # filtered out (.id > 200). With (submitted_at, id), it must appear.
    printf '2' > "$state_file"
    out2="$(_prtend_forge_gh_reviews_since 7 "$first_cursor")"
    assert_eq "second call sees the late draft" 1 "$(jq -c '.batches | length' <<<"$out2")"
    assert_eq "late-draft batch_id" '"100"' "$(jq -c '.batches[0].batch_id' <<<"$out2")"
  )
}

# ----------------------------------------------------------------------------
# Case 16c — Backward-compat: a bare numeric GitHub cursor (the previously
# documented form, or any pre-existing state file written before the
# compound-cursor change) must be interpreted as a legacy id-only filter,
# NOT silently downgraded to "from the beginning" (which would re-emit
# every old review). The next emission upgrades the cursor to compound.
# ----------------------------------------------------------------------------
case_gh_reviews_since_legacy_numeric_cursor() {
  echo "case: gh legacy numeric cursor is honored"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    _prtend_forge_gh_repo_slug() { echo "o/r"; }
    gh() {
      case "$*" in
        *"/reviews/"*"/comments"*) echo '[]' ;;
        *"/reviews"*)
          cat <<'JSON'
[
  {"id":100,"submitted_at":"2025-12-31T00:00:00Z","user":{"login":"alice"},"state":"COMMENTED"},
  {"id":200,"submitted_at":"2026-01-01T00:00:00Z","user":{"login":"bob"},"state":"APPROVED"},
  {"id":300,"submitted_at":"2026-01-02T00:00:00Z","user":{"login":"carol"},"state":"COMMENTED"}
]
JSON
          ;;
        *) return 1 ;;
      esac
    }
    # Legacy cursor "200" means "id > 200" — only id=300 should emit.
    out="$(_prtend_forge_gh_reviews_since 7 "200")"
    assert_eq "legacy filter count" 1 "$(jq -c '.batches | length' <<<"$out")"
    assert_eq "legacy filter batch_id" '"300"' "$(jq -c '.batches[0].batch_id' <<<"$out")"
    # And the emission upgrades the cursor to the compound form.
    assert_eq "next_cursor upgraded" '"2026-01-02T00:00:00Z|300"' \
      "$(jq -c .next_cursor <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 17 — GitLab forge: cursor must keep fractional-second precision so
# `--block` emitting one of two same-second discussions leaves the other
# pending for the next call (instead of filtering it out via `> $cur`).
# ----------------------------------------------------------------------------
case_gl_reviews_since_fractional_cursor() {
  echo "case: gl reviews_since preserves fractional cursor"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    export PRTEND_FORGE=gitlab
    export PRTEND_QUIET_WINDOW=0
    _prtend_forge_gl_project_id() { echo "1"; }
    glab() {
      cat <<'JSON'
[
  {"id":"d1","notes":[{"id":11,"system":false,"created_at":"2026-01-01T00:00:00.176Z","author":{"username":"alice"},"body":"a"}]},
  {"id":"d2","notes":[{"id":21,"system":false,"created_at":"2026-01-01T00:00:00.500Z","author":{"username":"bob"},"body":"b"}]}
]
JSON
    }
    out="$(_prtend_forge_gl_reviews_since 7 "")"
    # Two batches; per-batch resume_cursor preserves the fractional ms.
    assert_eq "two batches" 2 "$(jq -c '.batches | length' <<<"$out")"
    assert_eq "first resume_cursor"  '"2026-01-01T00:00:00.176Z"' "$(jq -c '.batches[0].resume_cursor' <<<"$out")"
    assert_eq "second resume_cursor" '"2026-01-01T00:00:00.500Z"' "$(jq -c '.batches[1].resume_cursor' <<<"$out")"
    # Now feed back the FIRST batch's resume_cursor as the next cursor;
    # the .176Z discussion must drop out, the .500Z discussion must stay.
    out2="$(_prtend_forge_gl_reviews_since 7 "2026-01-01T00:00:00.176Z")"
    assert_eq "one batch after first cursor" 1 "$(jq -c '.batches | length' <<<"$out2")"
    assert_eq "remaining batch_id" '"d2"' "$(jq -c '.batches[0].batch_id' <<<"$out2")"
    # And: a backward-compat cursor with no fractional ("...:00Z") must
    # still let both batches through (norm_iso pads to .000Z which is < .176Z).
    out3="$(_prtend_forge_gl_reviews_since 7 "2026-01-01T00:00:00Z")"
    assert_eq "both batches with seconds-only cursor" 2 "$(jq -c '.batches | length' <<<"$out3")"
  )
}

# ----------------------------------------------------------------------------
# Case 17b — GitLab follow-up after cursor: a discussion that was already
# emitted (cursor advanced past its original max-note time) must be
# re-emitted when a human posts a new note in the same thread. The batch
# event must surface ONLY the new note in comment_ids (docs/overview.md
# edge case #11: "New comment on a thread after Accept — treated as a
# fresh comment in the next review batch").
# ----------------------------------------------------------------------------
case_gl_reviews_since_followup_after_cursor() {
  echo "case: gl follow-up after cursor re-emits new note only"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    export PRTEND_FORGE=gitlab
    export PRTEND_QUIET_WINDOW=0
    _prtend_forge_gl_project_id() { echo "1"; }
    glab() {
      cat <<'JSON'
[
  {"id":"d1","notes":[
    {"id":11,"system":false,"created_at":"2026-01-01T00:00:00.100Z","author":{"username":"alice"},"body":"original"},
    {"id":12,"system":false,"created_at":"2026-01-02T00:00:00.500Z","author":{"username":"alice"},"body":"follow-up"}
  ]}
]
JSON
    }
    out="$(_prtend_forge_gl_reviews_since 7 "2026-01-01T00:00:00.100Z")"
    assert_eq "one batch re-emitted" 1 "$(jq -c '.batches | length' <<<"$out")"
    # comment_ids contains ONLY the new note (id 12), not the old one (11).
    assert_eq "comment_ids count" 1 "$(jq -c '.batches[0].comment_ids | length' <<<"$out")"
    assert_eq "new note id"       '"12"' "$(jq -c '.batches[0].comment_ids[0]' <<<"$out")"
    # submitted_at is the new note's time (this batch represents the new
    # activity, not the original discussion submission).
    assert_eq "submitted_at = new" '"2026-01-02T00:00:00.500Z"' \
      "$(jq -c '.batches[0].submitted_at' <<<"$out")"
    # Cursor advances past the latest note so we don't re-emit next call.
    assert_eq "resume_cursor"      '"2026-01-02T00:00:00.500Z"' \
      "$(jq -c '.batches[0].resume_cursor' <<<"$out")"
  )
}

case_gh_reviews_since_id_order
case_gh_reviews_since_late_draft
case_gh_reviews_since_legacy_numeric_cursor
case_gl_reviews_since_fractional_cursor
case_gl_reviews_since_followup_after_cursor
case_block_emits_one_of_many
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
case_thread_bodies_hard_failure
case_block_timeout_no_late_emit

PASS="$(grep -c '^P' "$RESULTS" || true)"
FAIL="$(grep -c '^F' "$RESULTS" || true)"
echo
echo "passed: ${PASS:-0}    failed: ${FAIL:-0}"
if (( FAIL > 0 )); then exit 1; fi
