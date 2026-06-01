#!/usr/bin/env bash
# prtend-state-lib.bash — per-PR state file: subscription marker, CI retry
# counters, review-batch cursor. All I/O through prtend_atomic_write.

if [[ -n "${PRTEND_STATE_LIB_LOADED:-}" ]]; then
  return 0
fi
PRTEND_STATE_LIB_LOADED=1

set -euo pipefail

# Depends on prtend-lib.bash being sourced first (atomic_write, state_dir, log_*).
if [[ -z "${PRTEND_LIB_LOADED:-}" ]]; then
  printf 'error: prtend-state-lib.bash requires prtend-lib.bash to be sourced first\n' >&2
  return 1
fi

# -- private helpers -------------------------------------------------------

_prtend_state_now() {
  local ts
  ts="$(date -u -Iseconds 2>/dev/null || date -u +'%Y-%m-%dT%H:%M:%S%z')"
  ts="${ts/+00:00/Z}"
  ts="${ts/+0000/Z}"
  printf '%s\n' "$ts"
}

_prtend_state_seed_json() {
  local pr="$1" forge_now ts
  forge_now="${PRTEND_FORGE:-unknown}"
  ts="$(_prtend_state_now)"
  jq -n \
    --argjson pr "$pr" \
    --arg forge "$forge_now" \
    --arg ts "$ts" \
    '{pr: $pr, forge: $forge, subscribed_at: $ts, ci_attempts: {}}'
}

# -- public API ------------------------------------------------------------

prtend_state_path() {
  local pr="${1:-}"
  if [[ -z "$pr" ]]; then
    prtend_log_error "prtend_state_path: missing pr argument"
    return 2
  fi
  local dir
  dir="$(prtend_state_dir)" || return 1
  printf '%s/%s.json\n' "$dir" "$pr"
}

prtend_state_read() {
  local pr="${1:-}" path
  [[ -n "$pr" ]] || { prtend_log_error "prtend_state_read: missing pr"; return 2; }
  path="$(prtend_state_path "$pr")" || return 1
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  cat -- "$path"
}

prtend_state_write() {
  local pr="${1:-}" json="${2:-}" path
  [[ -n "$pr" ]] || { prtend_log_error "prtend_state_write: missing pr"; return 2; }
  [[ -n "$json" ]] || { prtend_log_error "prtend_state_write: missing json"; return 2; }
  if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    prtend_log_error "prtend_state_write: input is not valid JSON"
    return 2
  fi
  path="$(prtend_state_path "$pr")" || return 1
  printf '%s\n' "$json" | prtend_atomic_write "$path"
}

prtend_state_increment_ci_attempt() {
  local pr="${1:-}" sig="${2:-}" path existing next updated
  [[ -n "$pr" ]] || { prtend_log_error "increment_ci_attempt: missing pr"; return 2; }
  [[ -n "$sig" ]] || { prtend_log_error "increment_ci_attempt: missing signature"; return 2; }
  [[ "$pr" =~ ^[0-9]+$ ]] || { prtend_log_error "increment_ci_attempt: pr must be numeric (got '$pr')"; return 2; }

  path="$(prtend_state_path "$pr")" || return 1
  if [[ -f "$path" ]]; then
    existing="$(cat -- "$path")"
  else
    existing="$(_prtend_state_seed_json "$pr")"
  fi

  next="$(printf '%s' "$existing" | jq \
    --arg sig "$sig" \
    '.ci_attempts[$sig] = ((.ci_attempts[$sig] // 0) + 1) | .ci_attempts[$sig]')"
  updated="$(printf '%s' "$existing" | jq \
    --arg sig "$sig" \
    '.ci_attempts[$sig] = ((.ci_attempts[$sig] // 0) + 1)')"

  prtend_state_write "$pr" "$updated"
  printf '%s\n' "$next"
}

prtend_state_ci_attempts() {
  local pr="${1:-}" sig="${2:-}" path
  [[ -n "$pr" ]] || { prtend_log_error "ci_attempts: missing pr"; return 2; }
  [[ -n "$sig" ]] || { prtend_log_error "ci_attempts: missing signature"; return 2; }
  path="$(prtend_state_path "$pr")" || return 1
  if [[ ! -f "$path" ]]; then
    printf '0\n'
    return 0
  fi
  jq -r --arg sig "$sig" '.ci_attempts[$sig] // 0' < "$path"
}

prtend_state_set_cursor() {
  local pr="${1:-}" cursor="${2:-}" path existing updated ts
  [[ -n "$pr" ]] || { prtend_log_error "set_cursor: missing pr"; return 2; }
  [[ "$pr" =~ ^[0-9]+$ ]] || { prtend_log_error "set_cursor: pr must be numeric (got '$pr')"; return 2; }

  path="$(prtend_state_path "$pr")" || return 1
  if [[ -f "$path" ]]; then
    existing="$(cat -- "$path")"
  else
    existing="$(_prtend_state_seed_json "$pr")"
  fi
  ts="$(_prtend_state_now)"

  updated="$(printf '%s' "$existing" | jq \
    --arg cursor "$cursor" \
    --arg ts "$ts" \
    '.last_review_cursor = $cursor | .last_review_at = $ts')"
  prtend_state_write "$pr" "$updated"
}

prtend_state_get_cursor() {
  local pr="${1:-}" path
  [[ -n "$pr" ]] || { prtend_log_error "get_cursor: missing pr"; return 2; }
  path="$(prtend_state_path "$pr")" || return 1
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  jq -r '.last_review_cursor // ""' < "$path"
}

prtend_state_clear() {
  local pr="${1:-}" path
  [[ -n "$pr" ]] || { prtend_log_error "clear: missing pr"; return 2; }
  path="$(prtend_state_path "$pr")" || return 1
  rm -f -- "$path"
}
