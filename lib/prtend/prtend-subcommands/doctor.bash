#!/usr/bin/env bash
# doctor.bash — `prtend doctor` subcommand. Runs the seven standard health
# checks (forge_cli_installed, forge_cli_authed, forge_cli_version,
# config_readable, state_dir_writable, stale_subscriptions,
# marker_consistency) and emits a single JSON document on stdout. With
# --fix, applies safe repairs to fixable checks (currently only
# stale_subscriptions) and re-runs just those checks.

set -uo pipefail

PRTEND_GH_MIN_VERSION="${PRTEND_GH_MIN_VERSION:-2.50.0}"
PRTEND_GLAB_MIN_VERSION="${PRTEND_GLAB_MIN_VERSION:-1.35.0}"

_DOCTOR_CHECKS=(forge_cli_installed forge_cli_authed forge_cli_version config_readable state_dir_writable stale_subscriptions marker_consistency)
_DOCTOR_KNOWN_MARKER_VERSIONS=("v1")

_prtend_doctor_load_libs() {
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

# -- row builders ----------------------------------------------------------

_doctor_row() {
  local name="$1" status="$2" message="$3" fixable="$4" fix_action="${5:-}"
  if [[ -n "$fix_action" ]]; then
    jq -cn \
      --arg name "$name" \
      --arg status "$status" \
      --arg message "$message" \
      --argjson fixable "$fixable" \
      --arg fix_action "$fix_action" \
      '{name:$name, status:$status, message:$message, fixable:$fixable, fix_action:$fix_action}'
  else
    jq -cn \
      --arg name "$name" \
      --arg status "$status" \
      --arg message "$message" \
      --argjson fixable "$fixable" \
      '{name:$name, status:$status, message:$message, fixable:$fixable}'
  fi
}

# -- forge helpers ---------------------------------------------------------

# Resolve the active forge once per run; cached in _DOCTOR_FORGE.
_doctor_resolve_forge() {
  if [[ -n "${_DOCTOR_FORGE:-}" ]]; then
    printf '%s\n' "$_DOCTOR_FORGE"
    return 0
  fi
  local f rc=0
  f="$(prtend_forge_detect 2>/dev/null)" || rc=$?
  if (( rc == 0 )) && [[ -n "$f" ]]; then
    _DOCTOR_FORGE="$f"
    printf '%s\n' "$f"
    return 0
  fi
  # Fall back to the exported PRTEND_FORGE (always guard for set -u).
  if [[ -n "${PRTEND_FORGE:-}" ]]; then
    _DOCTOR_FORGE="$PRTEND_FORGE"
    printf '%s\n' "$_DOCTOR_FORGE"
    return 0
  fi
  return 1
}

_doctor_forge_cli_name() {
  local forge="$1"
  case "$forge" in
    github) printf 'gh\n' ;;
    gitlab) printf 'glab\n' ;;
    *) return 1 ;;
  esac
}

# -- version compare -------------------------------------------------------

# _doctor_version_ge <a> <b>  → exit 0 if a >= b, else exit 1
# Strips pre-release suffixes (-rc.1, -beta.1) before comparing.
_doctor_version_ge() {
  local a="${1:-0}" b="${2:-0}"
  a="${a%%-*}"
  b="${b%%-*}"
  local IFS=.
  # shellcheck disable=SC2206
  local av=($a) bv=($b)
  local i
  for i in 0 1 2; do
    local ai="${av[$i]:-0}" bi="${bv[$i]:-0}"
    # Reject non-numeric components defensively.
    [[ "$ai" =~ ^[0-9]+$ ]] || ai=0
    [[ "$bi" =~ ^[0-9]+$ ]] || bi=0
    if (( 10#$ai > 10#$bi )); then return 0; fi
    if (( 10#$ai < 10#$bi )); then return 1; fi
  done
  return 0
}

# -- individual checks -----------------------------------------------------

_doctor_check_forge_cli_installed() {
  local forge cli
  if ! forge="$(_doctor_resolve_forge)"; then
    _doctor_row forge_cli_installed fail "no forge detected" false
    return 0
  fi
  if ! cli="$(_doctor_forge_cli_name "$forge")"; then
    _doctor_row forge_cli_installed fail "unknown forge '$forge'" false
    return 0
  fi
  if ! command -v "$cli" >/dev/null 2>&1; then
    _doctor_row forge_cli_installed fail "$cli not found on PATH" false
    return 0
  fi
  local ver_line
  ver_line="$("$cli" --version 2>/dev/null | head -n 1)"
  if [[ -z "$ver_line" ]]; then ver_line="$cli (version unknown)"; fi
  _doctor_row forge_cli_installed pass "$ver_line detected" false
}

_doctor_check_forge_cli_authed() {
  local forge cli
  if ! forge="$(_doctor_resolve_forge)" || ! cli="$(_doctor_forge_cli_name "$forge")"; then
    _doctor_row forge_cli_authed warn "forge CLI not installed; skipped" false
    return 0
  fi
  if ! command -v "$cli" >/dev/null 2>&1; then
    _doctor_row forge_cli_authed warn "forge CLI not installed; skipped" false
    return 0
  fi
  local out rc=0
  # gh / glab both print auth status to stderr; capture both.
  out="$("$cli" auth status 2>&1)" || rc=$?
  if (( rc == 0 )); then
    local login
    # Try to extract a login from the auth status output. gh format:
    # "  ✓ Logged in to github.com as <user>". glab: "Logged in to ... as <user>"
    login="$(printf '%s\n' "$out" | grep -Eo 'as [^ ]+' | head -n 1 | awk '{print $2}')"
    if [[ -n "$login" ]]; then
      _doctor_row forge_cli_authed pass "Authenticated as $login" false
    else
      _doctor_row forge_cli_authed pass "Authenticated" false
    fi
    return 0
  fi
  local msg
  msg="$(printf '%s\n' "$out" | head -n 1)"
  if [[ -z "$msg" ]]; then msg="$cli auth status failed"; fi
  _doctor_row forge_cli_authed fail "$msg" false
}

_doctor_check_forge_cli_version() {
  local forge cli
  if ! forge="$(_doctor_resolve_forge)" || ! cli="$(_doctor_forge_cli_name "$forge")"; then
    _doctor_row forge_cli_version warn "forge CLI not installed; skipped" false
    return 0
  fi
  if ! command -v "$cli" >/dev/null 2>&1; then
    _doctor_row forge_cli_version warn "forge CLI not installed; skipped" false
    return 0
  fi
  local ver_line floor
  ver_line="$("$cli" --version 2>/dev/null | head -n 1)"
  case "$forge" in
    github) floor="$PRTEND_GH_MIN_VERSION" ;;
    gitlab) floor="$PRTEND_GLAB_MIN_VERSION" ;;
  esac
  # Extract first dotted-numeric token (optionally with -prerelease suffix).
  local ver
  ver="$(printf '%s\n' "$ver_line" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' | head -n 1)"
  if [[ -z "$ver" ]]; then
    _doctor_row forge_cli_version warn "could not parse $cli version" false
    return 0
  fi
  if _doctor_version_ge "$ver" "$floor"; then
    _doctor_row forge_cli_version pass "$cli $ver meets minimum $floor" false
  else
    _doctor_row forge_cli_version fail "$cli $ver is below minimum $floor" false
  fi
}

# Pure-Bash structural scan that mirrors the grammar `prtend_config_get` /
# `prtend_config_list_get` parse: top-level keys, list items, blanks, comments.
# Returns "" on a clean scan, or "<line-no>: <reason>" on the first violation.
_doctor_scan_config() {
  local path="$1"
  local lineno=0 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$(( lineno + 1 ))
    # Blank.
    if [[ "$line" =~ ^[[:space:]]*$ ]]; then continue; fi
    # Comment.
    if [[ "$line" =~ ^[[:space:]]*# ]]; then continue; fi
    # Top-level key (list header or scalar).
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*:([[:space:]].*|[[:space:]]*)$ ]]; then continue; fi
    # Indented list item.
    if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+.*$ ]]; then continue; fi
    printf '%d: malformed line\n' "$lineno"
    return 0
  done <"$path"
}

_doctor_check_config_readable() {
  local path
  path="$(prtend_config_resolve 2>/dev/null || true)"
  if [[ -z "$path" ]]; then
    _doctor_row config_readable warn "no config file found; using built-in defaults" false
    return 0
  fi
  if [[ ! -e "$path" ]]; then
    _doctor_row config_readable fail "$path does not exist" false
    return 0
  fi
  if [[ ! -r "$path" ]]; then
    _doctor_row config_readable fail "$path: permission denied" false
    return 0
  fi
  local violation
  violation="$(_doctor_scan_config "$path")"
  if [[ -n "$violation" ]]; then
    _doctor_row config_readable fail "$path:$violation" false
    return 0
  fi
  _doctor_row config_readable pass "Loaded from $path" false
}

_doctor_check_state_dir_writable() {
  local dir rc=0
  dir="$(prtend_state_dir 2>/dev/null)" || rc=$?
  if (( rc != 0 )) || [[ -z "$dir" ]]; then
    _doctor_row state_dir_writable fail "state directory could not be resolved" false
    return 0
  fi
  local err
  if [[ ! -d "$dir" ]]; then
    err="$(mkdir -p -- "$dir" 2>&1)" || {
      _doctor_row state_dir_writable fail "$(printf '%s\n' "$err" | head -n 1)" false
      return 0
    }
  fi
  local probe="$dir/.prtend-doctor-probe"
  # Use a subshell with EXIT trap so the probe never lingers if anything below fails.
  (
    trap 'rm -f -- "$probe"' EXIT
    if ! printf 'ok' >"$probe" 2>/dev/null; then exit 1; fi
    if ! rm -f -- "$probe" 2>/dev/null; then exit 1; fi
  )
  rc=$?
  if (( rc != 0 )); then
    _doctor_row state_dir_writable fail "$dir: not writable" false
    return 0
  fi
  _doctor_row state_dir_writable pass "Writable: $dir" false
}

# Populates the module-scoped _DOCTOR_STALE_PRS array (sorted numerically)
# with PR numbers whose state file is stale (positive closed/merged JSON only).
# Independent of _DOCTOR_FORGE_READY — callers gate on that themselves; this
# helper is also invoked from the fix routine where the entrypoint cannot
# propagate readiness state into the process-substitution subshell.
_doctor_collect_stale_prs() {
  _DOCTOR_STALE_PRS=()
  local dir
  dir="$(prtend_state_dir 2>/dev/null)" || return 0
  [[ -d "$dir" ]] || return 0
  local f stem json st rc
  local -a found=()
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    stem="$(basename -- "$f" .json)"
    [[ "$stem" =~ ^[0-9]+$ ]] || continue
    rc=0
    json="$(prtend_forge_pr_state "$stem" 2>/dev/null)" || rc=$?
    if (( rc != 0 )) || [[ -z "$json" ]]; then continue; fi
    if ! st="$(printf '%s' "$json" | jq -r '.state // empty' 2>/dev/null)"; then continue; fi
    if [[ "$st" == "closed" || "$st" == "merged" ]]; then
      found+=("$stem")
    fi
  done
  if (( ${#found[@]} > 0 )); then
    # Sort numerically.
    mapfile -t _DOCTOR_STALE_PRS < <(printf '%s\n' "${found[@]}" | sort -n)
  fi
}

_doctor_check_stale_subscriptions() {
  # Probe readiness directly rather than depending on prior rows — the check
  # may run in isolation via `--check stale_subscriptions`.
  local ready=0
  if prtend_forge_cli_ready >/dev/null 2>&1; then ready=1; fi
  _DOCTOR_FORGE_READY=$ready
  if (( ready != 1 )); then
    _doctor_row stale_subscriptions warn "forge CLI not ready; skipped" false
    return 0
  fi
  local dir
  dir="$(prtend_state_dir 2>/dev/null)" || dir=""
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    _doctor_row stale_subscriptions pass "No state files yet" false
    return 0
  fi
  _doctor_collect_stale_prs
  if (( ${#_DOCTOR_STALE_PRS[@]} == 0 )); then
    _doctor_row stale_subscriptions pass "No stale subscriptions" false
    return 0
  fi
  local pr list=""
  for pr in "${_DOCTOR_STALE_PRS[@]}"; do
    if [[ -z "$list" ]]; then list="#$pr"; else list="$list, #$pr"; fi
  done
  _doctor_row stale_subscriptions warn \
    "${#_DOCTOR_STALE_PRS[@]} state files for closed PRs (PR $list)" \
    true "remove stale state files"
}

_doctor_check_marker_consistency() {
  local v
  v="$(prtend_note_marker_version)"
  local known
  for known in "${_DOCTOR_KNOWN_MARKER_VERSIONS[@]}"; do
    if [[ "$v" == "$known" ]]; then
      _doctor_row marker_consistency pass "Only marker $v in use" false
      return 0
    fi
  done
  _doctor_row marker_consistency warn \
    "Unknown marker version $v; doctor's known-version list may be stale" false
}

# Dispatch by check slug to the helper function.
_doctor_run_check() {
  local name="$1"
  case "$name" in
    forge_cli_installed)  _doctor_check_forge_cli_installed ;;
    forge_cli_authed)     _doctor_check_forge_cli_authed ;;
    forge_cli_version)    _doctor_check_forge_cli_version ;;
    config_readable)      _doctor_check_config_readable ;;
    state_dir_writable)   _doctor_check_state_dir_writable ;;
    stale_subscriptions)  _doctor_check_stale_subscriptions ;;
    marker_consistency)   _doctor_check_marker_consistency ;;
    *) return 1 ;;
  esac
}

# -- fix routines ----------------------------------------------------------

# Echoes one path per removed file. Re-discovers the stale set itself so it
# does not depend on parent-shell array state surviving command substitution
# (the row builder runs inside $()).
_doctor_fix_stale_subscriptions() {
  _doctor_collect_stale_prs
  local pr path
  for pr in "${_DOCTOR_STALE_PRS[@]:-}"; do
    [[ -n "$pr" ]] || continue
    path="$(prtend_state_path "$pr" 2>/dev/null)" || continue
    if prtend_state_clear "$pr" 2>/dev/null && [[ ! -e "$path" ]]; then
      printf '%s\n' "$path"
    else
      if [[ "${_DOCTOR_QUIET:-0}" != "1" ]]; then
        prtend_log_warn "doctor: failed to remove state file for PR $pr" >&2
      fi
    fi
  done
}

# -- entrypoint ------------------------------------------------------------

prtend_cmd_doctor() {
  local fix=0
  local quiet=0 verbose=0
  local -a requested=()
  while (( $# > 0 )); do
    case "$1" in
      --fix) fix=1; shift ;;
      --check)
        if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
          prtend_log_error "doctor: --check requires a non-empty argument"
          return 2
        fi
        requested+=("$2"); shift 2 ;;
      -q|--quiet) quiet=1; shift ;;
      -v|--verbose) verbose=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: prtend doctor [--fix] [--check NAME ...]

Runs health checks and emits one JSON document on stdout. With --fix,
applies safe repairs (currently: stale_subscriptions). Exit 0 if no
fail results remain; exit 1 otherwise.
EOF
        return 0 ;;
      *)
        printf "prtend: doctor: unknown option '%s'\n" "$1" >&2
        return 2 ;;
    esac
  done

  _prtend_doctor_load_libs
  export _DOCTOR_QUIET="$quiet"

  # Build the ordered list of checks to run.
  local -a to_run=()
  if (( ${#requested[@]} == 0 )); then
    to_run=("${_DOCTOR_CHECKS[@]}")
  else
    # Validate every requested name up-front before any check runs.
    local r known found
    for r in "${requested[@]}"; do
      found=0
      for known in "${_DOCTOR_CHECKS[@]}"; do
        if [[ "$r" == "$known" ]]; then found=1; break; fi
      done
      if (( found == 0 )); then
        printf "prtend: doctor: unknown check '%s'\n" "$r" >&2
        return 2
      fi
    done
    # Preserve canonical order regardless of how --check was passed.
    local c
    for c in "${_DOCTOR_CHECKS[@]}"; do
      for r in "${requested[@]}"; do
        if [[ "$r" == "$c" ]]; then to_run+=("$c"); break; fi
      done
    done
  fi

  # Run checks in canonical order, accumulating one row each.
  local -a rows=()
  local row name installed_status authed_status
  installed_status=""
  authed_status=""
  for name in "${to_run[@]}"; do
    if (( verbose == 1 )) && (( quiet == 0 )); then
      printf 'doctor: running check %s\n' "$name" >&2
    fi
    # Set _DOCTOR_FORGE_READY before stale_subscriptions sees it.
    if [[ "$name" == "stale_subscriptions" ]]; then
      if [[ "$installed_status" == "pass" && "$authed_status" == "pass" ]]; then
        _DOCTOR_FORGE_READY=1
      else
        _DOCTOR_FORGE_READY=0
      fi
    fi
    row="$(_doctor_run_check "$name")" || {
      row="$(_doctor_row "$name" fail "internal error: check did not produce a row" false)"
    }
    rows+=("$row")
    case "$name" in
      forge_cli_installed) installed_status="$(printf '%s' "$row" | jq -r '.status')" ;;
      forge_cli_authed)    authed_status="$(printf '%s' "$row" | jq -r '.status')" ;;
    esac
  done

  # Apply --fix.
  local -a fixed=()
  if (( fix == 1 )); then
    local i fixable status fix_name
    for i in "${!rows[@]}"; do
      row="${rows[$i]}"
      fix_name="$(printf '%s' "$row" | jq -r '.name')"
      fixable="$(printf '%s' "$row" | jq -r '.fixable')"
      status="$(printf '%s' "$row" | jq -r '.status')"
      if [[ "$fixable" != "true" || "$status" == "pass" ]]; then continue; fi
      case "$fix_name" in
        stale_subscriptions)
          local -a removed=()
          mapfile -t removed < <(_doctor_fix_stale_subscriptions)
          local details_json
          details_json="$(printf '%s\n' "${removed[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"
          fixed+=("$(jq -cn \
            --arg check "$fix_name" \
            --arg action removed \
            --argjson details "$details_json" \
            '{check:$check, action:$action, details:$details}')")
          # Re-run the check to refresh the row.
          if [[ "$installed_status" == "pass" && "$authed_status" == "pass" ]]; then
            _DOCTOR_FORGE_READY=1
          else
            _DOCTOR_FORGE_READY=0
          fi
          rows[i]="$(_doctor_run_check "$fix_name")"
          ;;
      esac
    done
  fi

  # Compose final JSON document.
  local checks_json fixed_json summary_json
  if (( ${#rows[@]} == 0 )); then
    checks_json='[]'
  else
    checks_json="$(printf '%s\n' "${rows[@]}" | jq -s '.')"
  fi
  if (( ${#fixed[@]} == 0 )); then
    fixed_json='[]'
  else
    fixed_json="$(printf '%s\n' "${fixed[@]}" | jq -s '.')"
  fi
  summary_json="$(printf '%s' "$checks_json" | jq '{
    pass: (map(select(.status=="pass")) | length),
    warn: (map(select(.status=="warn")) | length),
    fail: (map(select(.status=="fail")) | length)
  }')"

  jq -cn \
    --argjson checks "$checks_json" \
    --argjson summary "$summary_json" \
    --argjson fixed "$fixed_json" \
    '{checks:$checks, summary:$summary, fixed:$fixed}'

  local fail_count
  fail_count="$(printf '%s' "$summary_json" | jq -r '.fail')"
  if (( fail_count > 0 )); then return 1; fi
  return 0
}

export PRTEND_DOCTOR_LOADED=1
