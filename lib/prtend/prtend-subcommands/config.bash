#!/usr/bin/env bash
# config.bash — `prtend config` subcommand family.
# Routes to one of: init | show | get | set | path.
# The CLI never prompts; the skill gathers values from the user and passes them
# via flags. See docs/cli-contract.md § "`prtend config`" for the five output
# contracts and docs/overview.md § "First-run init (per repo)" for the
# resolution chain and write-target rationale.

set -euo pipefail

_PRTEND_CONFIG_KNOWN_KEYS=(
  system_reviewers
  optional_reviewers
  watch_strategy
  write_target
  poll_interval_seconds
  ci_retry_limit
)

_PRTEND_CONFIG_LIST_KEYS=(system_reviewers optional_reviewers)
_PRTEND_CONFIG_SCALAR_KEYS=(watch_strategy write_target poll_interval_seconds ci_retry_limit)

_prtend_config_is_known_key() {
  local k="$1" known
  for known in "${_PRTEND_CONFIG_KNOWN_KEYS[@]}"; do
    [[ "$k" == "$known" ]] && return 0
  done
  return 1
}

_prtend_config_is_list_key() {
  local k="$1" lk
  for lk in "${_PRTEND_CONFIG_LIST_KEYS[@]}"; do
    [[ "$k" == "$lk" ]] && return 0
  done
  return 1
}

# Apply YAML scalar quoting policy to a single value.
# Wraps in double quotes (and escapes \ and ") when the value contains
# `:`, `#`, or leading/trailing whitespace. Otherwise emits verbatim.
_prtend_config_quote_yaml() {
  local v="$1" escaped
  if [[ "$v" == *:* || "$v" == *\#* || "$v" =~ ^[[:space:]] || "$v" =~ [[:space:]]$ ]]; then
    escaped="${v//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    printf '"%s"' "$escaped"
  else
    printf '%s' "$v"
  fi
}

# Validate a scalar value for a given key. Echoes nothing; returns 0 if valid,
# 2 otherwise with a diagnostic on stderr.
_prtend_config_validate_scalar() {
  local context="$1" key="$2" value="$3"
  case "$key" in
    watch_strategy)
      case "$value" in
        blocking|poll-on-resume|background) return 0 ;;
        *)
          prtend_log_error "$context: invalid value for watch_strategy '$value' (expected blocking|poll-on-resume|background)"
          return 2 ;;
      esac ;;
    write_target)
      case "$value" in
        env|xdg|repo) return 0 ;;
        *)
          prtend_log_error "$context: invalid value for write_target '$value' (expected env|xdg|repo)"
          return 2 ;;
      esac ;;
    poll_interval_seconds|ci_retry_limit)
      if [[ ! "$value" =~ ^[0-9]+$ ]] || (( 10#$value < 1 )); then
        prtend_log_error "$context: $key must be a positive integer (got '$value')"
        return 2
      fi
      return 0 ;;
    *)
      prtend_log_error "$context: not a scalar key: '$key'"
      return 2 ;;
  esac
}

# Split a comma-separated list value into one element per line on stdout.
# Trims surrounding whitespace; rejects empty tokens with exit 2.
_prtend_config_split_list() {
  local context="$1" raw="$2" item
  # Reject empty input, and leading/trailing/adjacent commas up front —
  # bash word splitting drops trailing empty fields, so we can't rely on
  # the loop below to catch `alice,` or `,alice`.
  if [[ -z "$raw" || "$raw" == ,* || "$raw" == *, || "$raw" == *,,* ]]; then
    prtend_log_error "$context: empty list element after split"
    return 2
  fi
  local IFS=','
  for item in $raw; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [[ -z "$item" ]]; then
      prtend_log_error "$context: empty list element after split"
      return 2
    fi
    printf '%s\n' "$item"
  done
}

# Render a YAML block for a list key. Args: key, then list values.
# Emits:
#   <key>:
#     - val1
#     - val2
# (or just `<key>:` when no values)
_prtend_config_render_list_block() {
  local key="$1"; shift
  printf '%s:\n' "$key"
  local v
  for v in "$@"; do
    printf '  - %s\n' "$(_prtend_config_quote_yaml "$v")"
  done
}

# Assemble the full canonical YAML body. All six keys appear, in fixed order.
# Args: watch_strategy write_target poll_interval ci_retry_limit
#       system_reviewers... -- optional_reviewers...
# (The two lists are separated by a literal `--` argument so they can be
#  passed as variadic groups in a single call.)
_prtend_config_render_yaml() {
  local ws="$1" wt="$2" poll="$3" retry="$4"
  shift 4
  local sysrev=() optrev=() in_opt=0 arg
  for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then in_opt=1; continue; fi
    if (( in_opt == 1 )); then
      optrev+=("$arg")
    else
      sysrev+=("$arg")
    fi
  done

  # shellcheck disable=SC2016
  printf '# prtend config — managed by `prtend config init` / `prtend config set`\n'
  printf '# See docs/overview.md § "First-run init (per repo)" for what each key does.\n'
  printf '\n'
  printf 'watch_strategy: %s\n' "$(_prtend_config_quote_yaml "$ws")"
  printf 'write_target: %s\n' "$(_prtend_config_quote_yaml "$wt")"
  printf 'poll_interval_seconds: %s\n' "$poll"
  printf 'ci_retry_limit: %s\n' "$retry"
  printf '\n'
  _prtend_config_render_list_block system_reviewers "${sysrev[@]+"${sysrev[@]}"}"
  printf '\n'
  _prtend_config_render_list_block optional_reviewers "${optrev[@]+"${optrev[@]}"}"
}

# Read a config file from $1, replace the top-level scalar line for $2 with
# `$2: <quoted $3>`, atomic-write back to $1. If the key is absent, append.
_prtend_config_rewrite_scalar() {
  local path="$1" key="$2" value="$3"
  local quoted body line found=0
  quoted="$(_prtend_config_quote_yaml "$value")"
  body=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^${key}:[[:space:]] || "$line" =~ ^${key}:$ ]]; then
      body+="${key}: ${quoted}"$'\n'
      found=1
    else
      body+="${line}"$'\n'
    fi
  done <"$path"
  if (( found == 0 )); then
    body+="${key}: ${quoted}"$'\n'
  fi
  printf '%s' "$body" | prtend_atomic_write "$path"
}

# Read a config file from $1, replace the entire block for list-key $2 with
# `$2:` followed by `  - <quoted item>` lines built from $3.. ; atomic-write
# back. Drops every subsequent indented `- value` line and any blank lines
# directly following them, up to (but not including) the next top-level key.
# If the key is absent, append the block at EOF.
_prtend_config_rewrite_list() {
  local path="$1" key="$2"
  shift 2
  local items=("$@")
  local body="" line found=0 in_block=0
  local block
  block="$(_prtend_config_render_list_block "$key" "${items[@]+"${items[@]}"}")"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( in_block == 1 )); then
      # Stay in the block as long as we see indented list items or blank lines.
      if [[ "$line" =~ ^[[:space:]]+-[[:space:]] ]]; then
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]*$ ]]; then
        continue
      fi
      # Block ended — fall through and process this line normally.
      in_block=0
    fi
    if [[ "$line" =~ ^${key}:[[:space:]] || "$line" =~ ^${key}:$ ]]; then
      body+="${block}"$'\n'
      # Preserve one trailing blank separator after the rewritten block.
      body+=$'\n'
      found=1
      in_block=1
      continue
    fi
    body+="${line}"$'\n'
  done <"$path"

  if (( found == 0 )); then
    # No prior block — append at EOF (with a leading blank for readability).
    if [[ -n "$body" && "${body: -2}" != $'\n\n' ]]; then
      body+=$'\n'
    fi
    body+="${block}"$'\n'
  fi

  printf '%s' "$body" | prtend_atomic_write "$path"
}

_prtend_config_sub_usage() {
  cat <<'EOF'
Usage:
  prtend config init   --watch-strategy STRATEGY --write-target TARGET [options]
  prtend config show
  prtend config get    KEY
  prtend config set    KEY VALUE
  prtend config path

Sub-subcommands:
  init   Write a new config file (--force to overwrite).
  show   Print the active config as JSON, including the resolution chain.
  get    Print a single key's value (raw scalar or one list element per line).
  set    Mutate a single key in the active config in place.
  path   Print the active config file path.

See docs/cli-contract.md § "prtend config" for full flag tables and exit codes.
EOF
}

# --------------------------------------------------------------------------
# init
# --------------------------------------------------------------------------
_prtend_cmd_config_init() {
  local ws="" wt="" poll="" retry="" force=0
  local sysrev=() optrev=()

  _check_value() {
    local flag="$1" val="${2:-__MISSING__}"
    if [[ "$val" == "__MISSING__" || -z "$val" || "$val" == -* ]]; then
      prtend_log_error "config init: $flag requires a non-empty argument"
      return 2
    fi
  }

  while (( $# > 0 )); do
    case "$1" in
      --watch-strategy)
        _check_value --watch-strategy "${2:-}" || return $?
        ws="$2"; shift 2 ;;
      --write-target)
        _check_value --write-target "${2:-}" || return $?
        wt="$2"; shift 2 ;;
      --system-reviewer)
        _check_value --system-reviewer "${2:-}" || return $?
        sysrev+=("$2"); shift 2 ;;
      --optional-reviewer)
        _check_value --optional-reviewer "${2:-}" || return $?
        optrev+=("$2"); shift 2 ;;
      --poll-interval-seconds)
        _check_value --poll-interval-seconds "${2:-}" || return $?
        poll="$2"; shift 2 ;;
      --ci-retry-limit)
        _check_value --ci-retry-limit "${2:-}" || return $?
        retry="$2"; shift 2 ;;
      --force)
        force=1; shift ;;
      -h|--help)
        _prtend_config_sub_usage; return 0 ;;
      *)
        prtend_log_error "config init: unknown argument '$1'"
        return 2 ;;
    esac
  done

  if [[ -z "$ws" ]]; then
    prtend_log_error "config init: --watch-strategy is required"
    return 2
  fi
  _prtend_config_validate_scalar "config init" watch_strategy "$ws" || return 2

  if [[ -z "$wt" ]]; then
    prtend_log_error "config init: --write-target is required"
    return 2
  fi
  _prtend_config_validate_scalar "config init" write_target "$wt" || return 2

  if [[ -n "$poll" ]]; then
    _prtend_config_validate_scalar "config init" poll_interval_seconds "$poll" || return 2
  else
    poll=15
  fi
  if [[ -n "$retry" ]]; then
    _prtend_config_validate_scalar "config init" ci_retry_limit "$retry" || return 2
  else
    retry=3
  fi

  # 1. Git repo gate.
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    printf 'prtend: not in a git repository\n' >&2
    return 1
  fi

  # 2. Write-target preconditions.
  if [[ "$wt" == "env" && -z "${PRTEND_CONFIG:-}" ]]; then
    # shellcheck disable=SC2016
    prtend_log_error 'config init: --write-target env requires $PRTEND_CONFIG to be set'
    return 2
  fi

  # 3. Resolve the write-target path.
  local out_path=""
  if ! out_path="$(prtend_config_target_path "$wt" 2>/dev/null)" || [[ -z "$out_path" ]]; then
    prtend_log_error "config init: could not resolve path for --write-target $wt"
    return 1
  fi

  # 4. Overwrite gate.
  if [[ -e "$out_path" && $force -eq 0 ]]; then
    printf 'prtend: config already exists at %s; pass --force to overwrite\n' "$out_path" >&2
    return 4
  fi

  # 5. Assemble YAML.
  local body
  body="$(_prtend_config_render_yaml \
    "$ws" "$wt" "$poll" "$retry" \
    "${sysrev[@]+"${sysrev[@]}"}" -- "${optrev[@]+"${optrev[@]}"}")"

  # 6. Write atomically.
  if ! printf '%s\n' "$body" | prtend_atomic_write "$out_path"; then
    return 1
  fi

  # 7. Emit JSON.
  jq -cn \
    --arg p "$out_path" \
    --arg wt "$wt" \
    '{written_to: $p, write_target: $wt, keys_set: ["system_reviewers","optional_reviewers","watch_strategy","write_target","poll_interval_seconds","ci_retry_limit"]}'
}

# --------------------------------------------------------------------------
# show
# --------------------------------------------------------------------------
_prtend_cmd_config_show() {
  if (( $# > 0 )); then
    case "$1" in
      -h|--help) _prtend_config_sub_usage; return 0 ;;
      *) prtend_log_error "config show: unknown argument '$1'"; return 2 ;;
    esac
  fi

  local sources=(env xdg repo)
  local src path active_path="" entries_json="[]"
  local active_marked=0
  local entry

  for src in "${sources[@]}"; do
    path=""
    if ! path="$(prtend_config_target_path "$src" 2>/dev/null)"; then
      path=""
    fi
    local file_exists=0
    if [[ -n "$path" && -f "$path" ]]; then
      file_exists=1
    fi
    local entry_active=false
    if (( file_exists == 1 && active_marked == 0 )); then
      entry_active=true
      active_marked=1
      active_path="$path"
    fi
    # env reports its expected path even if the file is missing; xdg/repo
    # report a path only when the file exists.
    if [[ "$src" != "env" && $file_exists -eq 0 ]]; then
      path=""
    fi
    if [[ -n "$path" ]]; then
      entry="$(jq -cn --arg s "$src" --arg p "$path" --argjson a "$entry_active" \
        '{source: $s, path: $p, active: $a}')"
    else
      entry="$(jq -cn --arg s "$src" --argjson a "$entry_active" \
        '{source: $s, path: null, active: $a}')"
    fi
    entries_json="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$entries_json")"
  done

  local values_json="{}"
  if [[ -n "$active_path" ]]; then
    local sysrev_arr optrev_arr ws wt poll retry
    sysrev_arr="$(prtend_config_list_get system_reviewers | jq -R . | jq -c -s .)"
    optrev_arr="$(prtend_config_list_get optional_reviewers | jq -R . | jq -c -s .)"
    ws="$(prtend_config_get watch_strategy)"
    wt="$(prtend_config_get write_target)"
    poll="$(prtend_config_get poll_interval_seconds)"
    retry="$(prtend_config_get ci_retry_limit)"
    : "${poll:=15}"
    : "${retry:=3}"
    values_json="$(jq -cn \
      --argjson sys "$sysrev_arr" \
      --argjson opt "$optrev_arr" \
      --arg ws "$ws" \
      --arg wt "$wt" \
      --argjson poll "$poll" \
      --argjson retry "$retry" \
      '{system_reviewers: $sys, optional_reviewers: $opt, watch_strategy: $ws, write_target: $wt, poll_interval_seconds: $poll, ci_retry_limit: $retry}')"
  fi

  if [[ -n "$active_path" ]]; then
    jq -cn \
      --arg ap "$active_path" \
      --argjson chain "$entries_json" \
      --argjson values "$values_json" \
      '{active_config_path: $ap, resolution_chain: $chain, values: $values}'
  else
    jq -cn \
      --argjson chain "$entries_json" \
      --argjson values "$values_json" \
      '{active_config_path: null, resolution_chain: $chain, values: $values}'
  fi
}

# --------------------------------------------------------------------------
# get
# --------------------------------------------------------------------------
_prtend_cmd_config_get() {
  local key=""
  while (( $# > 0 )); do
    case "$1" in
      -h|--help) _prtend_config_sub_usage; return 0 ;;
      -*) prtend_log_error "config get: unknown argument '$1'"; return 2 ;;
      *)
        if [[ -n "$key" ]]; then
          prtend_log_error "config get: too many positional arguments"
          return 2
        fi
        key="$1"; shift ;;
    esac
  done

  if [[ -z "$key" ]]; then
    prtend_log_error "config get: KEY is required"
    return 2
  fi
  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    prtend_log_error "config get: invalid key '$key'"
    return 2
  fi
  if ! _prtend_config_is_known_key "$key"; then
    prtend_log_error "config get: unknown key '$key' (known: ${_PRTEND_CONFIG_KNOWN_KEYS[*]})"
    return 2
  fi

  if _prtend_config_is_list_key "$key"; then
    prtend_config_list_get "$key"
  else
    local v
    v="$(prtend_config_get "$key")"
    if [[ -n "$v" ]]; then
      printf '%s\n' "$v"
    fi
  fi
}

# --------------------------------------------------------------------------
# set
# --------------------------------------------------------------------------
_prtend_cmd_config_set() {
  local key="" value="" got=0
  while (( $# > 0 )); do
    case "$1" in
      -h|--help) _prtend_config_sub_usage; return 0 ;;
      --) shift
          while (( $# > 0 )); do
            if   (( got == 0 )); then key="$1"; got=1
            elif (( got == 1 )); then value="$1"; got=2
            else prtend_log_error "config set: too many positional arguments"; return 2
            fi
            shift
          done ;;
      -*) prtend_log_error "config set: unknown argument '$1'"; return 2 ;;
      *)
        if   (( got == 0 )); then key="$1"; got=1
        elif (( got == 1 )); then value="$1"; got=2
        else prtend_log_error "config set: too many positional arguments"; return 2
        fi
        shift ;;
    esac
  done

  if (( got < 2 )); then
    prtend_log_error "config set: KEY and VALUE are required"
    return 2
  fi
  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    prtend_log_error "config set: invalid key '$key'"
    return 2
  fi
  if ! _prtend_config_is_known_key "$key"; then
    prtend_log_error "config set: unknown key '$key' (known: ${_PRTEND_CONFIG_KNOWN_KEYS[*]})"
    return 2
  fi

  local target_path
  target_path="$(prtend_config_resolve)"
  if [[ -z "$target_path" ]]; then
    printf "prtend: no active config; run 'prtend config init' before config set\n" >&2
    return 4
  fi

  if _prtend_config_is_list_key "$key"; then
    local split_out item items=()
    if ! split_out="$(_prtend_config_split_list "config set" "$value")"; then
      return 2
    fi
    while IFS= read -r item; do
      [[ -n "$item" ]] && items+=("$item")
    done <<<"$split_out"
    _prtend_config_rewrite_list "$target_path" "$key" "${items[@]+"${items[@]}"}"
  else
    _prtend_config_validate_scalar "config set" "$key" "$value" || return 2
    _prtend_config_rewrite_scalar "$target_path" "$key" "$value"
  fi
}

# --------------------------------------------------------------------------
# path
# --------------------------------------------------------------------------
_prtend_cmd_config_path() {
  if (( $# > 0 )); then
    case "$1" in
      -h|--help) _prtend_config_sub_usage; return 0 ;;
      *) prtend_log_error "config path: unknown argument '$1'"; return 2 ;;
    esac
  fi
  prtend_config_resolve
}

# --------------------------------------------------------------------------
# router
# --------------------------------------------------------------------------
prtend_cmd_config() {
  if (( $# == 0 )); then
    _prtend_config_sub_usage
    return 0
  fi
  case "$1" in
    -h|--help) _prtend_config_sub_usage; return 0 ;;
    init)  shift; _prtend_cmd_config_init "$@" ;;
    show)  shift; _prtend_cmd_config_show "$@" ;;
    get)   shift; _prtend_cmd_config_get  "$@" ;;
    set)   shift; _prtend_cmd_config_set  "$@" ;;
    path)  shift; _prtend_cmd_config_path "$@" ;;
    *)
      prtend_log_error "config: unknown subcommand '$1'"
      return 2 ;;
  esac
}
