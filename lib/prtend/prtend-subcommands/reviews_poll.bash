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
      # max_batches=0 → unlimited: --once emits everything pending in one call.
      _PRTEND_REVIEWS_POLL_EMITTED=0
      _reviews_poll_emit_pending "$pr" "$cursor" "$write_cursor" 0 || return $?
      return 0
      ;;
    block)
      local start="$SECONDS" elapsed remaining nap first=1
      while :; do
        # Deadline check fires at the top of every iteration after the first
        # so a batch that arrives during sleep — at or past the budget — is
        # NOT emitted (the contract is exit 0 / no output / no cursor write
        # on timeout, with no peek at one more poll).
        if (( first == 0 )) && (( saw_timeout == 1 )); then
          if (( SECONDS - start >= timeout_s )); then
            return 0
          fi
        fi
        first=0

        # max_batches=1 → blocking mode emits exactly one document per call
        # (cli-contract.md § "Output discipline" → "Streamed commands").
        _PRTEND_REVIEWS_POLL_EMITTED=0
        _reviews_poll_emit_pending "$pr" "$cursor" "$write_cursor" 1 || return $?
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
        # Pre-sleep deadline short-circuit so we never sleep past the budget.
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

# _reviews_poll_emit_pending <pr> <cursor> <write_cursor> <max_batches>
#   - One reviews_since call → up to max_batches {type:"review_batch", ...}
#     events on stdout (max_batches == 0 means "all pending").
#   - Sets _PRTEND_REVIEWS_POLL_EMITTED to the number of batches emitted.
#   - Writes cursor to state iff write_cursor == 1 AND at least one batch
#     was emitted. The cursor written is the per-batch `resume_cursor` of
#     the LAST emitted batch — so the next call resumes after that batch
#     even if `max_batches` truncated the response. (A zero-batch call must
#     not advance the cursor.)
_reviews_poll_emit_pending() {
  local pr="$1" cursor="$2" write_cursor="$3" max_batches="${4:-0}"
  local reviews_json batches total emit_count next_cursor last_resume_cursor i
  local batch_id submitted_at author review_state batch_resume_cursor
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
  total="$(printf '%s' "$batches" | jq 'length')"
  if (( total == 0 )); then
    return 0
  fi
  if (( max_batches > 0 && max_batches < total )); then
    emit_count="$max_batches"
  else
    emit_count="$total"
  fi

  last_resume_cursor=""
  for ((i=0; i<emit_count; i++)); do
    batch_id="$(printf '%s' "$batches" | jq -r ".[$i].batch_id")"
    submitted_at="$(printf '%s' "$batches" | jq -r ".[$i].submitted_at // \"\"")"
    author="$(printf '%s' "$batches" | jq -r ".[$i].author // \"\"")"
    review_state="$(printf '%s' "$batches" | jq -r ".[$i].state // \"commented\"")"
    # Per-batch resume token. Forge guarantees the field; fall back to the
    # across-call next_cursor only if a forge ever stops emitting it.
    batch_resume_cursor="$(printf '%s' "$batches" | jq -r ".[$i].resume_cursor // \"\"")"
    if [[ -z "$batch_resume_cursor" ]]; then
      batch_resume_cursor="$next_cursor"
    fi

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
      _reviews_poll_already_handled "$pr" "$comment_id" || return $?
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

    # Per-event `next_cursor` is *this* batch's resume token. A consumer
    # that picks one event and drops the rest can still resume correctly:
    # passing the chosen event's next_cursor on the next call yields the
    # batches strictly after it.
    jq -cn \
      --argjson pr "$pr" \
      --arg batch_id "$batch_id" \
      --arg submitted_at "$submitted_at" \
      --arg author "$author" \
      --arg review_state "$review_state" \
      --argjson comments "$event_comments_json" \
      --arg next_cursor "$batch_resume_cursor" \
      '{type:"review_batch", pr:$pr, batch_id:$batch_id,
        submitted_at:$submitted_at, author:$author,
        review_state:$review_state, comments:$comments,
        next_cursor:$next_cursor}'

    last_resume_cursor="$batch_resume_cursor"
    _PRTEND_REVIEWS_POLL_EMITTED=$(( _PRTEND_REVIEWS_POLL_EMITTED + 1 ))
  done

  if (( write_cursor == 1 )); then
    # Advance state past exactly the batches we emitted. When max_batches
    # truncated the response, this leaves the unemitted ones for the next
    # call.
    prtend_state_set_cursor "$pr" "$last_resume_cursor" >/dev/null || return 1
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

# Fetches the comment's thread (root + replies for GitHub review comments;
# all notes in the discussion for GitLab) via `prtend_forge_review_thread_bodies`
# and sets RET=true if any body in that thread carries a prtend marker.
# The marker lives in the *reply* posted by `note-post`, not in the
# reviewer's original anchored comment — so walking the batch's sibling
# `comment_ids` would miss it. Mirrors note-post's idempotency probe.
# Per-batch cache (`body_cache` in caller, keyed by comment_id) dedupes
# fetches when two projected comments resolve to the same thread.
_reviews_poll_already_handled() {
  local pr="$1" comment_id="$2"
  local thread_bodies probe_rc
  if [[ -n "${body_cache[$comment_id]+set}" ]]; then
    thread_bodies="${body_cache[$comment_id]}"
  else
    probe_rc=0
    thread_bodies="$(prtend_forge_review_thread_bodies "$pr" "$comment_id" 2>/dev/null)" \
      || probe_rc=$?
    case "$probe_rc" in
      0)
        : ;;
      1)
        # Documented "id unknown" — shouldn't happen for an id we just got
        # from `review_comments`, but if it does, treat the thread as empty
        # and let the downstream rubric escalate.
        thread_bodies="" ;;
      *)
        # Network, auth, or other API failure. Do NOT downgrade to "not
        # handled" — that would let a watch loop double-post on a thread
        # that's already been replied to. Propagate so the caller aborts
        # this poll cycle (no partial cursor advance per Key decisions).
        return "$probe_rc" ;;
    esac
    body_cache[$comment_id]="$thread_bodies"
  fi
  if prtend_note_is_handled "$thread_bodies"; then
    _PRTEND_REVIEWS_POLL_RET=true
  else
    _PRTEND_REVIEWS_POLL_RET=false
  fi
}
