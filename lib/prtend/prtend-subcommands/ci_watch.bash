#!/usr/bin/env bash
# ci_watch.bash — `prtend ci-watch` subcommand. Samples CI on entry, then
# either emits any pending event (--once) or blocks until the aggregate state
# changes (--block / --block --timeout). Emits exactly one canonical
# {type:"ci", ...} JSON event on stdout per state change. Persists the
# observed state as the cursor for the next call and increments the
# per-signature retry counter for each distinct failure signature.

set -euo pipefail

# State-lib is loaded lazily — bin/prtend doesn't pre-source it.
_prtend_ci_watch_load_state_lib() {
  if [[ -z "${PRTEND_STATE_LIB_LOADED:-}" ]]; then
    # shellcheck source=lib/prtend/prtend-state-lib.bash
    # shellcheck disable=SC1091
    source "${PRTEND_LIB:-$(dirname "${BASH_SOURCE[0]}")/..}/prtend-state-lib.bash"
  fi
}

_prtend_ci_watch_check_value() {
  local flag="$1" val="${2:-__MISSING__}"
  if [[ "$val" == "__MISSING__" || -z "$val" || "$val" == -* ]]; then
    prtend_log_error "ci-watch: $flag requires a non-empty argument"
    return 2
  fi
}

prtend_cmd_ci_watch() {
  local pr=""
  local mode=""       # "block" | "once"
  local timeout_s=""
  local saw_block=0 saw_once=0 saw_timeout=0

  while (( $# > 0 )); do
    case "$1" in
      --pr)
        _prtend_ci_watch_check_value --pr "${2:-}" || return $?
        pr="$2"; shift 2 ;;
      --block)
        saw_block=1; shift ;;
      --once)
        saw_once=1; shift ;;
      --timeout)
        _prtend_ci_watch_check_value --timeout "${2:-}" || return $?
        timeout_s="$2"; saw_timeout=1; shift 2 ;;
      *)
        prtend_log_error "ci-watch: unknown argument '$1'"; return 2 ;;
    esac
  done

  if [[ -z "$pr" ]]; then
    prtend_log_error "ci-watch: --pr is required"; return 2
  fi
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    prtend_log_error "ci-watch: --pr must be a positive integer"; return 2
  fi
  if (( saw_once == 1 && saw_block == 1 )); then
    prtend_log_error "ci-watch: --once and --block are mutually exclusive"; return 2
  fi
  if (( saw_once == 1 && saw_timeout == 1 )); then
    prtend_log_error "ci-watch: --once and --timeout are mutually exclusive"; return 2
  fi
  if (( saw_timeout == 1 )) && [[ ! "$timeout_s" =~ ^[1-9][0-9]*$ ]]; then
    prtend_log_error "ci-watch: --timeout must be a positive integer"; return 2
  fi
  if (( saw_once == 1 )); then
    mode="once"
  else
    mode="block"
  fi

  _prtend_ci_watch_load_state_lib

  # 1. Git repo + readiness.
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    printf 'prtend: not in a git repository\n' >&2
    return 1
  fi
  local rc=0
  prtend_forge_cli_ready || rc=$?
  if (( rc != 0 )); then return "$rc"; fi

  # 2. Pre-flight PR existence / open state.
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

  # 3. Resolve previous_state from state file.
  local previous_state
  previous_state="$(prtend_state_get_ci_last_state "$pr" || true)"

  # 4. Sample current CI status.
  local status_json state
  status_json="$(prtend_forge_ci_status "$pr")" || return 1
  state="$(printf '%s' "$status_json" | jq -r '.state // ""')"

  # 5. Branch on mode.
  case "$mode" in
    once)
      if [[ -n "$previous_state" && "$state" == "$previous_state" ]]; then
        # Nothing pending; no cursor write, no counter increment.
        return 0
      fi
      ;;
    block)
      if [[ -z "$previous_state" || "$state" != "$previous_state" ]]; then
        : # entry-time mismatch: emit immediately
      else
        local watch_rc=0 watch_out=""
        set +e
        if (( saw_timeout == 1 )); then
          watch_out="$(prtend_forge_ci_watch_block "$pr" "$state" "$timeout_s")"
        else
          watch_out="$(prtend_forge_ci_watch_block "$pr" "$state")"
        fi
        watch_rc=$?
        set -e
        if (( watch_rc == 124 )); then
          # Clean timeout — no output, exit 0 per contract.
          return 0
        fi
        if (( watch_rc == 4 )); then
          printf 'prtend: PR %s closed during watch\n' "$pr" >&2
          return 4
        fi
        if (( watch_rc != 0 )); then
          return 1
        fi
        status_json="$watch_out"
        state="$(printf '%s' "$status_json" | jq -r '.state // ""')"
      fi
      ;;
  esac

  # 6. Materialize failures[] when state is failure.
  local failures_json="[]"
  if [[ "$state" == "failure" ]]; then
    local failures_obj
    failures_obj="$(prtend_forge_ci_failures "$pr")" || return 1
    failures_json="$(printf '%s' "$failures_obj" | jq -c '.failures // []')"
  fi

  # 7. Emit one event on stdout.
  local checks_json
  checks_json="$(printf '%s' "$status_json" | jq -c '.checks // []')"
  local prev_arg
  if [[ -z "$previous_state" ]]; then
    prev_arg="null"
  else
    prev_arg="$(jq -nr --arg p "$previous_state" '$p | @json')"
  fi
  if [[ "$state" == "failure" ]]; then
    jq -cn \
      --argjson pr "$pr" \
      --arg state "$state" \
      --argjson checks "$checks_json" \
      --argjson failures "$failures_json" \
      --argjson prev "$prev_arg" \
      '{type:"ci", pr:$pr, state:$state, checks:$checks, failures:$failures, previous_state:$prev}'
  else
    jq -cn \
      --argjson pr "$pr" \
      --arg state "$state" \
      --argjson checks "$checks_json" \
      --argjson prev "$prev_arg" \
      '{type:"ci", pr:$pr, state:$state, checks:$checks, previous_state:$prev}'
  fi

  # 8. Persist cursor + per-signature attempt counters.
  prtend_state_set_ci_last_state "$pr" "$state" >/dev/null || return 1
  if [[ "$state" == "failure" ]]; then
    local sigs sig
    sigs="$(printf '%s' "$failures_json" | jq -r '[ .[].signature ] | unique | .[]')"
    while IFS= read -r sig; do
      [[ -z "$sig" ]] && continue
      prtend_state_increment_ci_attempt "$pr" "$sig" >/dev/null || return 1
    done <<<"$sigs"
  fi
  return 0
}
