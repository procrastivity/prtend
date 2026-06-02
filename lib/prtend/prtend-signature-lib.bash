#!/usr/bin/env bash
# prtend-signature-lib.bash — derive a stable `<tool>:<scope>:<short-rule>`
# signature from a CI log excerpt. Pure string work; no I/O beyond reading
# the excerpt file. Used by prtend-forge-lib.bash's ci_failures privates to
# tag failures so prtend-state-lib.bash can count attempts per signature.

if [[ -n "${PRTEND_SIGNATURE_LIB_LOADED:-}" ]]; then
  return 0
fi

if [[ -z "${PRTEND_LIB_LOADED:-}" ]]; then
  printf 'error: prtend-signature-lib.bash requires prtend-lib.bash to be sourced first\n' >&2
  return 1
fi

set -euo pipefail
PRTEND_SIGNATURE_LIB_LOADED=1

# -- private helpers -------------------------------------------------------

_prtend_signature_basename() {
  local p="${1:-}"
  printf '%s\n' "${p##*/}"
}

# Heuristics. Each returns 0 with the signature on stdout, or 1 with no
# output. Order is plan-significant (first-match-wins in the caller).

_prtend_signature_try_jest() {
  local path="$1" file="" test_name="" expected="" received="" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^FAIL[[:space:]]+([^[:space:]]+) ]]; then
      file="${BASH_REMATCH[1]}"; test_name=""; expected=""; received=""
    elif [[ -n "$file" && "$line" =~ ^[[:space:]]*●[[:space:]]+(.+)$ ]]; then
      test_name="${BASH_REMATCH[1]}"
    elif [[ -n "$file" && "$line" =~ ^[[:space:]]*Expected:[[:space:]]+(.+)$ ]]; then
      expected="${BASH_REMATCH[1]}"
    elif [[ -n "$file" && "$line" =~ ^[[:space:]]*Received:[[:space:]]+(.+)$ ]]; then
      received="${BASH_REMATCH[1]}"
    fi
    if [[ -n "$file" && -n "$expected" && -n "$received" ]]; then
      printf 'jest:%s:%s-%s\n' "$(_prtend_signature_basename "$file")" "$expected" "$received"
      return 0
    fi
  done < "$path"
  return 1
}

_prtend_signature_try_vitest() {
  local path="$1" file="" expected="" received="" line saw_vitest=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == *"vitest"* || "$line" =~ ^[[:space:]]*❯[[:space:]] ]]; then
      saw_vitest=1
    fi
    if [[ "$line" =~ ^[[:space:]]*FAIL[[:space:]]+([^[:space:]]+) ]]; then
      file="${BASH_REMATCH[1]}"; expected=""; received=""
    elif [[ -n "$file" && "$line" =~ ^[[:space:]]*Expected:[[:space:]]+(.+)$ ]]; then
      expected="${BASH_REMATCH[1]}"
    elif [[ -n "$file" && "$line" =~ ^[[:space:]]*Received:[[:space:]]+(.+)$ ]]; then
      received="${BASH_REMATCH[1]}"
    fi
    if (( saw_vitest == 1 )) && [[ -n "$file" && -n "$expected" && -n "$received" ]]; then
      printf 'vitest:%s:%s-%s\n' "$(_prtend_signature_basename "$file")" "$expected" "$received"
      return 0
    fi
  done < "$path"
  return 1
}

_prtend_signature_try_eslint() {
  local path="$1" line re
  re='^([^[:space:]:]+):([0-9]+):[0-9]+[[:space:]]+error[[:space:]]+.+[[:space:]]+([a-z0-9-]+/[a-z0-9-]+)[[:space:]]*$'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re ]]; then
      printf 'eslint:%s:%s\n' "$(_prtend_signature_basename "${BASH_REMATCH[1]}")" "${BASH_REMATCH[3]}"
      return 0
    fi
  done < "$path"
  return 1
}

_prtend_signature_try_tsc() {
  local path="$1" line re
  re='^([^[:space:](]+)\([0-9]+,[0-9]+\):[[:space:]]error[[:space:]](TS[0-9]+):'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re ]]; then
      printf 'tsc:%s:%s\n' "$(_prtend_signature_basename "${BASH_REMATCH[1]}")" "${BASH_REMATCH[2]}"
      return 0
    fi
  done < "$path"
  return 1
}

_prtend_signature_try_mypy() {
  local path="$1" line re
  re='^([^[:space:]:]+):[0-9]+:[[:space:]]error:[[:space:]].+[[:space:]]\[([a-z-]+)\][[:space:]]*$'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re ]]; then
      printf 'mypy:%s:%s\n' "$(_prtend_signature_basename "${BASH_REMATCH[1]}")" "${BASH_REMATCH[2]}"
      return 0
    fi
  done < "$path"
  return 1
}

_prtend_signature_try_pytest() {
  local path="$1" line re
  re='^FAILED[[:space:]]([^[:space:]:]+)::([^[:space:]]+)'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re ]]; then
      printf 'pytest:%s:%s\n' "$(_prtend_signature_basename "${BASH_REMATCH[1]}")" "${BASH_REMATCH[2]}"
      return 0
    fi
  done < "$path"
  return 1
}

_prtend_signature_try_go() {
  local path="$1" line test_name="" re_fail re_loc
  re_fail='^---[[:space:]]FAIL:[[:space:]]([^[:space:]]+)'
  re_loc='^[[:space:]]+([^[:space:]:]+):[0-9]+:'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re_fail ]]; then
      test_name="${BASH_REMATCH[1]}"
    elif [[ -n "$test_name" && "$line" =~ $re_loc ]]; then
      printf 'go:%s:%s\n' "$(_prtend_signature_basename "${BASH_REMATCH[1]}")" "$test_name"
      return 0
    fi
  done < "$path"
  return 1
}

_prtend_signature_try_cargo() {
  local path="$1" line test_name="" panic="" re_test re_panic
  re_test='^test[[:space:]]([^[:space:]]+)[[:space:]]\.\.\.[[:space:]]FAILED[[:space:]]*$'
  re_panic="^thread[[:space:]]'[^']+'[[:space:]]panicked[[:space:]]at[[:space:]]'([^']+)'"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re_test ]]; then
      test_name="${BASH_REMATCH[1]}"
    elif [[ -n "$test_name" && "$line" =~ $re_panic ]]; then
      panic="${BASH_REMATCH[1]}"
      # scope = last module path segment of test_name
      local scope="${test_name##*::}"
      printf 'cargo:%s:%s\n' "$scope" "$panic"
      return 0
    fi
  done < "$path"
  return 1
}

_prtend_signature_try_shellcheck() {
  local path="$1" line file="" re_in re_sc
  re_in='^In[[:space:]]([^[:space:]]+)[[:space:]]line[[:space:]][0-9]+:'
  re_sc='(SC[0-9]+)'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re_in ]]; then
      file="${BASH_REMATCH[1]}"
    elif [[ -n "$file" && "$line" =~ $re_sc ]]; then
      printf 'shellcheck:%s:%s\n' "$(_prtend_signature_basename "$file")" "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$path"
  return 1
}

_prtend_signature_fallback() {
  local check_name="$1" path="$2" first hash
  first="$(grep -m1 -E '[^[:space:]]' "$path" 2>/dev/null || true)"
  if [[ -z "$first" ]]; then
    first="$check_name"
  fi
  hash="$(printf '%s' "$first" | shasum -a 1 2>/dev/null | awk '{print $1}')"
  if [[ -z "$hash" ]]; then
    hash="$(printf '%s' "$first" | sha1sum 2>/dev/null | awk '{print $1}')"
  fi
  hash="${hash:0:12}"
  printf 'unknown:%s:%s\n' "$check_name" "$hash"
}

# -- public API ------------------------------------------------------------

prtend_signature_from_log() {
  local check_name="${1:-}" path="${2:-}" sig
  if [[ -z "$check_name" ]]; then
    prtend_log_error "prtend_signature_from_log: missing check_name"
    return 2
  fi
  if [[ -z "$path" || ! -f "$path" ]]; then
    prtend_log_error "prtend_signature_from_log: missing or unreadable log path"
    return 2
  fi
  # Order matters: vitest before jest would steal jest's `FAIL` lines unless
  # the vitest path is gated on its own marker. Keep plan order.
  if sig="$(_prtend_signature_try_jest "$path")"; then printf '%s\n' "$sig"; return 0; fi
  if sig="$(_prtend_signature_try_vitest "$path")"; then printf '%s\n' "$sig"; return 0; fi
  if sig="$(_prtend_signature_try_eslint "$path")"; then printf '%s\n' "$sig"; return 0; fi
  if sig="$(_prtend_signature_try_tsc "$path")"; then printf '%s\n' "$sig"; return 0; fi
  if sig="$(_prtend_signature_try_mypy "$path")"; then printf '%s\n' "$sig"; return 0; fi
  if sig="$(_prtend_signature_try_pytest "$path")"; then printf '%s\n' "$sig"; return 0; fi
  if sig="$(_prtend_signature_try_go "$path")"; then printf '%s\n' "$sig"; return 0; fi
  if sig="$(_prtend_signature_try_cargo "$path")"; then printf '%s\n' "$sig"; return 0; fi
  if sig="$(_prtend_signature_try_shellcheck "$path")"; then printf '%s\n' "$sig"; return 0; fi
  _prtend_signature_fallback "$check_name" "$path"
}
