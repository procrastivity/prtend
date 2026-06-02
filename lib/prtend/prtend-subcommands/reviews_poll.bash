#!/usr/bin/env bash
# reviews_poll.bash — `prtend reviews-poll` subcommand. Fetches review batches
# pending since the recorded cursor, emits one canonical
# {type:"review_batch", ...} JSON event per batch on stdout, persists the new
# cursor, and exits. Composes the read-only review surface in
# prtend-forge-lib.bash (reviews_since, review_comments, comment_body, pr_state)
# with the per-PR cursor helpers in prtend-state-lib.bash and the marker check
# in prtend-notes-lib.bash. Anchor staleness (path/line still exists at HEAD)
# is computed locally — the forge lib has no view of the checkout.

set -uo pipefail

_prtend_reviews_poll_load_libs() {
  if [[ -z "${PRTEND_STATE_LIB_LOADED:-}" ]]; then
    # shellcheck source=lib/prtend/prtend-state-lib.bash
    # shellcheck disable=SC1091
    source "${PRTEND_LIB:-$(dirname "${BASH_SOURCE[0]}")/..}/prtend-state-lib.bash"
  fi
  if [[ -z "${PRTEND_NOTES_LIB_LOADED:-}" ]]; then
    # shellcheck source=lib/prtend/prtend-notes-lib.bash
    # shellcheck disable=SC1091
    source "${PRTEND_LIB:-$(dirname "${BASH_SOURCE[0]}")/..}/prtend-notes-lib.bash"
  fi
}

_prtend_reviews_poll_check_value() {
  local flag="$1" val="${2:-__MISSING__}"
  if [[ "$val" == "__MISSING__" || -z "$val" || "$val" == -* ]]; then
    prtend_log_error "reviews-poll: $flag requires a non-empty argument"
    return 2
  fi
}

# Used by the helper to signal emission count back to the caller without
# bleeding bytes into the stdout stream that carries the JSON events.
_PRTEND_REVIEWS_POLL_EMITTED=0

prtend_cmd_reviews_poll() {
  local pr=""
  local mode=""
  local timeout_s=""
  local flag_cursor=""
  local saw_block=0 saw_once=0 saw_timeout=0 saw_cursor=0

  while (( $# > 0 )); do
    case "$1" in
      --pr)
        _prtend_reviews_poll_check_value --pr "${2:-}" || return $?
        pr="$2"; shift 2 ;;
      --block)
        saw_block=1; shift ;;
      --once)
        saw_once=1; shift ;;
      --timeout)
        _prtend_reviews_poll_check_value --timeout "${2:-}" || return $?
        timeout_s="$2"; saw_timeout=1; shift 2 ;;
      --cursor)
        # --cursor may legitimately be an empty string in --once mode; allow it.
        if [[ "${2:-__MISSING__}" == "__MISSING__" ]]; then
          prtend_log_error "reviews-poll: --cursor requires an argument"; return 2
        fi
        flag_cursor="$2"; saw_cursor=1; shift 2 ;;
      *)
        prtend_log_error "reviews-poll: unknown argument '$1'"; return 2 ;;
    esac
  done

  if [[ -z "$pr" ]]; then
    prtend_log_error "reviews-poll: --pr is required"; return 2
  fi
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    prtend_log_error "reviews-poll: --pr must be a positive integer"; return 2
  fi
  if (( saw_once == 1 && saw_block == 1 )); then
    prtend_log_error "reviews-poll: --once and --block are mutually exclusive"; return 2
  fi
  if (( saw_once == 1 && saw_timeout == 1 )); then
    prtend_log_error "reviews-poll: --once and --timeout are mutually exclusive"; return 2
  fi
  if (( saw_timeout == 1 )) && [[ ! "$timeout_s" =~ ^[1-9][0-9]*$ ]]; then
    prtend_log_error "reviews-poll: --timeout must be a positive integer"; return 2
  fi
  if (( saw_once == 1 )); then mode="once"; else mode="block"; fi

  _prtend_reviews_poll_load_libs

  # 1. Git repo + forge readiness.
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    printf 'prtend: not in a git repository\n' >&2
    return 1
  fi
  local rc=0
  prtend_forge_cli_ready || rc=$?
  if (( rc != 0 )); then return "$rc"; fi

  # 2. Pre-flight PR existence + state.
  local pr_state_json pr_state
  rc=0
  pr_state_json="$(prtend_forge_pr_state "$pr" 2>/dev/null)" || rc=$?
  if (( rc != 0 )) || [[ -z "$pr_state_json" ]]; then
    printf 'prtend: PR %s not found\n' "$pr" >&2
    return 4
  fi
  pr_state="$(printf '%s' "$pr_state_json" | jq -r '.state // ""')"
  if [[ "$pr_state" == "closed" || "$pr_state" == "merged" ]]; then
    printf 'prtend: PR %s is %s\n' "$pr" "$pr_state" >&2
    return 4
  fi

  # 3. Resolve cursor.
  local cursor write_cursor
  if (( saw_cursor == 1 )); then
    cursor="$flag_cursor"; write_cursor=0
  else
    cursor="$(prtend_state_get_cursor "$pr" || true)"; write_cursor=1
  fi

  # 4. Branch on mode.
  case "$mode" in
    once)
      _PRTEND_REVIEWS_POLL_EMITTED=0
      _reviews_poll_emit_pending "$pr" "$cursor" "$write_cursor" || return $?
      return 0
      ;;
    block)
      local start="$SECONDS" elapsed remaining nap
      while :; do
        _PRTEND_REVIEWS_POLL_EMITTED=0
        _reviews_poll_emit_pending "$pr" "$cursor" "$write_cursor" || return $?
        if (( _PRTEND_REVIEWS_POLL_EMITTED > 0 )); then
          return 0
        fi
        # Re-check PR state — catches PR-closed-mid-watch.
        rc=0
        pr_state_json="$(prtend_forge_pr_state "$pr" 2>/dev/null)" || rc=$?
        if (( rc == 0 )) && [[ -n "$pr_state_json" ]]; then
          pr_state="$(printf '%s' "$pr_state_json" | jq -r '.state // ""')"
          if [[ "$pr_state" == "closed" || "$pr_state" == "merged" ]]; then
            printf 'prtend: PR %s closed during poll\n' "$pr" >&2
            return 4
          fi
        fi
        # Elapsed-time short-circuit on --timeout (clean exit 0, no output).
        if (( saw_timeout == 1 )); then
          elapsed=$(( SECONDS - start ))
          if (( elapsed >= timeout_s )); then
            return 0
          fi
        fi
        nap="${PRTEND_POLL_INTERVAL:-15}"
        if (( saw_timeout == 1 )); then
          remaining=$(( timeout_s - (SECONDS - start) ))
          if (( remaining < nap )); then nap="$remaining"; fi
          if (( nap < 0 )); then nap=0; fi
        fi
        sleep "$nap"
      done
      ;;
  esac
}

# _reviews_poll_emit_pending <pr> <cursor> <write_cursor>
#   - One reviews_since call → zero or more {type:"review_batch", ...} on stdout.
#   - Sets _PRTEND_REVIEWS_POLL_EMITTED to the number of batches emitted.
#   - Writes cursor to state iff write_cursor == 1 AND at least one batch
#     was emitted. (A zero-batch call must not advance the cursor — the next
#     call needs to retry from the same point.)
_reviews_poll_emit_pending() {
  local pr="$1" cursor="$2" write_cursor="$3"
  local reviews_json batches next_cursor count i
  local batch_id submitted_at author review_state comment_ids
  local comments_json comments_count j
  local comment_id c_author c_body c_path c_line c_created
  local anchor_stale already_handled
  local event_comments_json comment_obj
  local -A path_exists_cache=()
  local -A path_lines_cache=()
  local -A body_cache=()

  reviews_json="$(prtend_forge_reviews_since "$pr" "$cursor")" || return $?
  batches="$(printf '%s' "$reviews_json" | jq -c '.batches // []')"
  next_cursor="$(printf '%s' "$reviews_json" | jq -r '.next_cursor // ""')"
  count="$(printf '%s' "$batches" | jq 'length')"
  if (( count == 0 )); then
    return 0
  fi

  for ((i=0; i<count; i++)); do
    batch_id="$(printf '%s' "$batches" | jq -r ".[$i].batch_id")"
    submitted_at="$(printf '%s' "$batches" | jq -r ".[$i].submitted_at // \"\"")"
    author="$(printf '%s' "$batches" | jq -r ".[$i].author // \"\"")"
    review_state="$(printf '%s' "$batches" | jq -r ".[$i].state // \"commented\"")"
    comment_ids="$(printf '%s' "$batches" | jq -c ".[$i].comment_ids // []")"

    comments_json="$(prtend_forge_review_comments "$pr" "$batch_id")" || return $?
    comments_count="$(printf '%s' "$comments_json" | jq '.comments | length')"

    event_comments_json='[]'
    for ((j=0; j<comments_count; j++)); do
      comment_id="$(printf '%s' "$comments_json" | jq -r ".comments[$j].comment_id")"
      c_author="$(printf '%s' "$comments_json" | jq -r ".comments[$j].author // \"\"")"
      c_body="$(printf '%s' "$comments_json" | jq -r ".comments[$j].body // \"\"")"
      c_path="$(printf '%s' "$comments_json" | jq -r ".comments[$j].path // \"\"")"
      c_line="$(printf '%s' "$comments_json" | jq -r ".comments[$j].line")"
      c_created="$(printf '%s' "$comments_json" | jq -r ".comments[$j].created_at // \"\"")"

      _reviews_poll_anchor_stale "$c_path" "$c_line"
      anchor_stale="$_PRTEND_REVIEWS_POLL_RET"
      _reviews_poll_already_handled "$pr" "$comment_id" "$comment_ids"
      already_handled="$_PRTEND_REVIEWS_POLL_RET"

      if [[ "$c_line" == "null" || -z "$c_line" ]]; then
        comment_obj="$(jq -nc \
          --arg id "$comment_id" --arg au "$c_author" --arg bd "$c_body" \
          --arg pa "$c_path" --arg cr "$c_created" \
          --argjson stale "$anchor_stale" --argjson handled "$already_handled" \
          '{comment_id:$id, author:$au, body:$bd, path:$pa, line:null,
            anchor_stale:$stale, already_handled:$handled, created_at:$cr}')"
      else
        comment_obj="$(jq -nc \
          --arg id "$comment_id" --arg au "$c_author" --arg bd "$c_body" \
          --arg pa "$c_path" --argjson ln "$c_line" --arg cr "$c_created" \
          --argjson stale "$anchor_stale" --argjson handled "$already_handled" \
          '{comment_id:$id, author:$au, body:$bd, path:$pa, line:$ln,
            anchor_stale:$stale, already_handled:$handled, created_at:$cr}')"
      fi
      event_comments_json="$(printf '%s' "$event_comments_json" \
        | jq -c --argjson c "$comment_obj" '. + [$c]')"
    done

    jq -cn \
      --argjson pr "$pr" \
      --arg batch_id "$batch_id" \
      --arg submitted_at "$submitted_at" \
      --arg author "$author" \
      --arg review_state "$review_state" \
      --argjson comments "$event_comments_json" \
      --arg next_cursor "$next_cursor" \
      '{type:"review_batch", pr:$pr, batch_id:$batch_id,
        submitted_at:$submitted_at, author:$author,
        review_state:$review_state, comments:$comments,
        next_cursor:$next_cursor}'

    _PRTEND_REVIEWS_POLL_EMITTED=$(( _PRTEND_REVIEWS_POLL_EMITTED + 1 ))
  done

  if (( write_cursor == 1 )); then
    prtend_state_set_cursor "$pr" "$next_cursor" >/dev/null || return 1
  fi
  return 0
}

# Helpers return their result via `_PRTEND_REVIEWS_POLL_RET` rather than
# stdout — command substitution would spawn a subshell and destroy the
# per-batch caches declared in `_reviews_poll_emit_pending`. The caches
# (`path_exists_cache`, `path_lines_cache`, `body_cache`) are reached via
# dynamic scoping; assignments here mutate the caller's locals.
_PRTEND_REVIEWS_POLL_RET=""

_reviews_poll_anchor_stale() {
  local path="$1" line="$2"
  if [[ -z "$path" || "$line" == "null" || -z "$line" ]]; then
    _PRTEND_REVIEWS_POLL_RET=false; return 0
  fi
  local exists lines
  if [[ -n "${path_exists_cache[$path]:-}" ]]; then
    exists="${path_exists_cache[$path]}"
  else
    if git rev-parse --verify -q "HEAD:$path" >/dev/null 2>&1; then
      exists=1
    else
      exists=0
    fi
    path_exists_cache[$path]="$exists"
  fi
  if (( exists == 0 )); then
    _PRTEND_REVIEWS_POLL_RET=true; return 0
  fi
  if [[ -n "${path_lines_cache[$path]:-}" ]]; then
    lines="${path_lines_cache[$path]}"
  else
    lines="$(git show "HEAD:$path" 2>/dev/null | wc -l | tr -d ' ')"
    path_lines_cache[$path]="$lines"
  fi
  if (( line > lines )); then
    _PRTEND_REVIEWS_POLL_RET=true
  else
    _PRTEND_REVIEWS_POLL_RET=false
  fi
}

# Walks every *other* comment id in this batch and sets RET=true the moment
# one carries a prtend marker; false otherwise. Body fetches are memoized in
# `body_cache` (caller's local) so a thread with N comments pays the fetch
# cost once per reply id, not N×.
_reviews_poll_already_handled() {
  local pr="$1" self_id="$2" ids_json="$3"
  local n k other body
  n="$(printf '%s' "$ids_json" | jq 'length')"
  for ((k=0; k<n; k++)); do
    other="$(printf '%s' "$ids_json" | jq -r ".[$k]")"
    if [[ "$other" == "$self_id" ]]; then continue; fi
    if [[ -n "${body_cache[$other]+set}" ]]; then
      body="${body_cache[$other]}"
    else
      body="$(prtend_forge_comment_body "$pr" "$other" 2>/dev/null || true)"
      body_cache[$other]="$body"
    fi
    if prtend_note_is_handled "$body"; then
      _PRTEND_REVIEWS_POLL_RET=true; return 0
    fi
  done
  _PRTEND_REVIEWS_POLL_RET=false
}
