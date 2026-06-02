#!/usr/bin/env bash
# watch.bash — `prtend watch` subcommand. Multiplexes ci-watch and
# reviews-poll, plus a periodic pr_state re-check that fires `pr_closed`
# when the PR transitions to closed/merged mid-watch. Per iteration:
# call `prtend_cmd_ci_watch --once`, then `prtend_cmd_reviews_poll --once
# --cursor "$cursor"`, then `prtend_forge_pr_state`. Emits exactly one
# JSON event of one of three types (ci | review_batch | pr_closed) and
# returns 0, or sleeps and re-iterates, or returns 0 with no output on
# --once / on --timeout expiry. Children are invoked as Bash functions —
# never as subprocesses, never with --block.

set -uo pipefail

_prtend_watch_load_libs() {
  if [[ -z "${PRTEND_STATE_LIB_LOADED:-}" ]]; then
    # shellcheck source=lib/prtend/prtend-state-lib.bash
    # shellcheck disable=SC1091
    source "${PRTEND_LIB:-$(dirname "${BASH_SOURCE[0]}")/..}/prtend-state-lib.bash"
  fi
  if [[ -z "${PRTEND_CI_WATCH_LOADED:-}" ]]; then
    # shellcheck source=lib/prtend/prtend-subcommands/ci_watch.bash
    # shellcheck disable=SC1091
    source "${PRTEND_LIB:-$(dirname "${BASH_SOURCE[0]}")/..}/prtend-subcommands/ci_watch.bash"
    PRTEND_CI_WATCH_LOADED=1
  fi
  if [[ -z "${PRTEND_REVIEWS_POLL_LOADED:-}" ]]; then
    # shellcheck source=lib/prtend/prtend-subcommands/reviews_poll.bash
    # shellcheck disable=SC1091
    source "${PRTEND_LIB:-$(dirname "${BASH_SOURCE[0]}")/..}/prtend-subcommands/reviews_poll.bash"
    PRTEND_REVIEWS_POLL_LOADED=1
  fi
}

_prtend_watch_check_value() {
  local flag="$1" val="${2:-__MISSING__}"
  if [[ "$val" == "__MISSING__" || -z "$val" || "$val" == -* ]]; then
    prtend_log_error "watch: $flag requires a non-empty argument"
    return 2
  fi
}

prtend_cmd_watch() {
  local pr=""
  local mode=""
  local timeout_s=""
  local saw_block=0 saw_once=0 saw_timeout=0

  while (( $# > 0 )); do
    case "$1" in
      --pr)
        _prtend_watch_check_value --pr "${2:-}" || return $?
        pr="$2"; shift 2 ;;
      --block)
        saw_block=1; shift ;;
      --once)
        saw_once=1; shift ;;
      --timeout)
        _prtend_watch_check_value --timeout "${2:-}" || return $?
        timeout_s="$2"; saw_timeout=1; shift 2 ;;
      *)
        prtend_log_error "watch: unknown argument '$1'"; return 2 ;;
    esac
  done

  if [[ -z "$pr" ]]; then
    prtend_log_error "watch: --pr is required"; return 2
  fi
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    prtend_log_error "watch: --pr must be a positive integer"; return 2
  fi
  if (( saw_once == 1 && saw_block == 1 )); then
    prtend_log_error "watch: --once and --block are mutually exclusive"; return 2
  fi
  if (( saw_once == 1 && saw_timeout == 1 )); then
    prtend_log_error "watch: --once and --timeout are mutually exclusive"; return 2
  fi
  if (( saw_timeout == 1 )) && [[ ! "$timeout_s" =~ ^[1-9][0-9]*$ ]]; then
    prtend_log_error "watch: --timeout must be a positive integer"; return 2
  fi
  if (( saw_once == 1 )); then mode="once"; else mode="block"; fi

  _prtend_watch_load_libs

  # 1. Git repo + forge readiness.
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    printf 'prtend: not in a git repository\n' >&2
    return 1
  fi
  local rc=0
  prtend_forge_cli_ready || rc=$?
  if (( rc != 0 )); then return "$rc"; fi

  # 2. Pre-flight PR existence + open state.
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

  # 3. Resolve initial review cursor. watch owns the cursor write.
  local cursor
  cursor="$(prtend_state_get_cursor "$pr" || true)"

  local start="$SECONDS" first=1 nap remaining
  local ci_out ci_rc rev_out rev_rc first_event next_cursor pr_rc

  while :; do
    if (( first == 0 )) && (( saw_timeout == 1 )); then
      if (( SECONDS - start >= timeout_s )); then
        return 0
      fi
    fi

    # (b) CI sample.
    set +e
    ci_out="$(prtend_cmd_ci_watch --pr "$pr" --once)"
    ci_rc=$?
    set -e
    case "$ci_rc" in
      0)
        if [[ -n "$ci_out" ]]; then
          printf '%s\n' "$ci_out"
          return 0
        fi
        ;;
      4)
        _prtend_watch_emit_pr_closed "$pr" "$pr_state_json" || true
        return 0
        ;;
      *)
        return "$ci_rc" ;;
    esac

    # (c) Reviews sample. We always own the cursor write — but reviews-poll
    # rejects `--cursor ""` so when our cursor is empty we omit the flag and
    # overwrite whatever reviews-poll persisted with our chosen value below.
    set +e
    if [[ -n "$cursor" ]]; then
      rev_out="$(prtend_cmd_reviews_poll --pr "$pr" --once --cursor "$cursor")"
    else
      rev_out="$(prtend_cmd_reviews_poll --pr "$pr" --once)"
    fi
    rev_rc=$?
    set -e
    case "$rev_rc" in
      0)
        if [[ -n "$rev_out" ]]; then
          first_event="$(printf '%s' "$rev_out" | head -n 1)"
          printf '%s\n' "$first_event"
          next_cursor="$(printf '%s' "$first_event" | jq -r '.next_cursor // ""')"
          prtend_state_set_cursor "$pr" "$next_cursor" >/dev/null || return 1
          return 0
        fi
        ;;
      4)
        _prtend_watch_emit_pr_closed "$pr" "$pr_state_json" || true
        return 0
        ;;
      *)
        return "$rev_rc" ;;
    esac

    # (d) PR-state re-check.
    pr_rc=0
    local fresh_state_json fresh_state
    fresh_state_json="$(prtend_forge_pr_state "$pr" 2>/dev/null)" || pr_rc=$?
    if (( pr_rc == 0 )) && [[ -n "$fresh_state_json" ]]; then
      pr_state_json="$fresh_state_json"
      fresh_state="$(printf '%s' "$fresh_state_json" | jq -r '.state // ""')"
      if [[ "$fresh_state" == "closed" || "$fresh_state" == "merged" ]]; then
        _prtend_watch_emit_pr_closed "$pr" "$pr_state_json" || true
        return 0
      fi
    fi

    # (f) --once mode: one iteration and out.
    if [[ "$mode" == "once" ]]; then
      return 0
    fi

    # (g) --block mode: sleep, then loop.
    if (( saw_timeout == 1 )) && (( SECONDS - start >= timeout_s )); then
      return 0
    fi
    nap="${PRTEND_POLL_INTERVAL:-15}"
    if (( saw_timeout == 1 )); then
      remaining=$(( timeout_s - (SECONDS - start) ))
      if (( remaining < nap )); then nap="$remaining"; fi
      if (( nap < 0 )); then nap=0; fi
    fi
    sleep "$nap"
    first=0
  done
}

# _prtend_watch_emit_pr_closed <pr> <pr_state_json>
#   Writes the pr_closed event to stdout and clears the PR's state file.
#   Returns 0 on success; a state_clear failure is logged as a warning
#   but does not change the return code — the event is already on the
#   wire and the skill needs it.
_prtend_watch_emit_pr_closed() {
  local pr="$1" pr_state_json="$2"
  local final_state closed_at
  final_state="$(printf '%s' "$pr_state_json" | jq -r '.state // ""')"
  closed_at="$(printf '%s' "$pr_state_json" | jq -r '.closed_at // ""')"
  jq -cn \
    --argjson pr "$pr" \
    --arg final_state "$final_state" \
    --arg closed_at "$closed_at" \
    '{type:"pr_closed", pr:$pr, final_state:$final_state, closed_at:$closed_at}'
  if ! prtend_state_clear "$pr" 2>/dev/null; then
    prtend_log_warn "watch: failed to clear state for PR $pr"
  fi
  return 0
}

export PRTEND_WATCH_LOADED=1
