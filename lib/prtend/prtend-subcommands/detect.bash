#!/usr/bin/env bash
# detect.bash — `prtend detect` subcommand.
# Composes forge detection, branch lookup, PR resolution, and remote/default
# branch observations into the JSON object documented in cli-contract.md.

set -euo pipefail

prtend_cmd_detect() {
  local branch="" no_cache=0

  while (( $# > 0 )); do
    case "$1" in
      --no-cache)
        no_cache=1
        shift
        ;;
      --branch)
        if (( $# < 2 )) || [[ -z "$2" || "$2" == -* ]]; then
          prtend_log_error "detect: --branch requires a non-empty argument"
          return 2
        fi
        branch="$2"
        shift 2
        ;;
      --branch=*)
        branch="${1#--branch=}"
        if [[ -z "$branch" ]]; then
          prtend_log_error "detect: --branch requires a non-empty argument"
          return 2
        fi
        shift
        ;;
      *)
        prtend_log_error "detect: unknown argument '$1'"
        return 2
        ;;
    esac
  done

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    printf 'prtend: not in a git repository\n' >&2
    return 1
  fi

  if (( no_cache == 1 )); then
    # Shadow the caller's PRTEND_FORGE for this call only; an empty value
    # makes prtend_forge_detect re-probe rather than reuse the cache.
    # shellcheck disable=SC2034 # read by prtend_forge_detect via dynamic scope
    local PRTEND_FORGE=""
  fi

  if [[ -z "$branch" ]]; then
    branch="$(prtend_forge_current_branch)"
  fi

  local forge="" rc=0
  forge="$(prtend_forge_detect 2>/dev/null)" || rc=$?
  if (( rc == 2 )); then
    return 2
  fi
  if (( rc != 0 )); then
    forge=""
  fi

  local remote=""
  remote="$(prtend_forge_active_remote 2>/dev/null || true)"

  local default_branch="" is_default_branch="false"
  if [[ -n "$forge" ]]; then
    default_branch="$(prtend_forge_default_branch 2>/dev/null || true)"
    if [[ -n "$default_branch" && "$default_branch" == "$branch" ]]; then
      is_default_branch="true"
    fi
  fi

  local pr="" pr_state=""
  if [[ -n "$forge" ]]; then
    rc=0
    pr="$(prtend_forge_pr_for_branch "$branch" 2>/dev/null)" || rc=$?
    if (( rc == 2 )); then
      prtend_log_error "detect: multiple open PRs match branch '$branch'"
      return 4
    fi
    if (( rc == 1 )); then
      pr=""
      pr_state=""
    elif (( rc == 0 )); then
      local state_json
      if ! state_json="$(prtend_forge_pr_state "$pr")"; then
        prtend_log_error "detect: forge call failed resolving pr_state for #$pr"
        return 3
      fi
      pr_state="$(printf '%s' "$state_json" | jq -r '.state')"
    else
      return "$rc"
    fi
  fi

  jq -cn \
    --arg forge "${forge:-}" \
    --arg branch "$branch" \
    --arg pr "${pr:-}" \
    --arg pr_state "${pr_state:-}" \
    --argjson is_default_branch "$is_default_branch" \
    --arg remote "${remote:-}" \
    '{
       forge:             (if $forge   == "" then null else $forge end),
       branch:            $branch,
       pr:                (if $pr      == "" then null else ($pr | tonumber) end),
       pr_state:          (if $pr_state == "" then null else $pr_state end),
       is_default_branch: $is_default_branch,
       remote:            (if $remote  == "" then null else $remote end)
     }'
}
