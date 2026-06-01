#!/usr/bin/env bash
# pr_open.bash — `prtend pr-open` subcommand.
# Ensures the current branch is on the remote, creates a PR if absent,
# then runs the reviewer flow. Idempotent on re-invocation.

set -euo pipefail

# Validate a flag-value argument: non-empty and not another flag.
_prtend_pr_open_check_value() {
  local flag="$1" val="${2:-__MISSING__}"
  if [[ "$val" == "__MISSING__" || -z "$val" || "$val" == -* ]]; then
    prtend_log_error "pr-open: $flag requires a non-empty argument"
    return 2
  fi
}

prtend_cmd_pr_open() {
  local title="" body="" draft=0 target=""
  local -a optional_reviewers=()

  while (( $# > 0 )); do
    case "$1" in
      --title)
        _prtend_pr_open_check_value --title "${2:-}" || return $?
        title="$2"; shift 2 ;;
      --title=*)
        title="${1#--title=}"
        if [[ -z "$title" ]]; then
          prtend_log_error "pr-open: --title requires a non-empty argument"; return 2
        fi
        shift ;;
      --body)
        _prtend_pr_open_check_value --body "${2:-}" || return $?
        body="$2"; shift 2 ;;
      --body=*)
        body="${1#--body=}"; shift ;;
      --draft)
        draft=1; shift ;;
      --target-branch)
        _prtend_pr_open_check_value --target-branch "${2:-}" || return $?
        target="$2"; shift 2 ;;
      --target-branch=*)
        target="${1#--target-branch=}"
        if [[ -z "$target" ]]; then
          prtend_log_error "pr-open: --target-branch requires a non-empty argument"; return 2
        fi
        shift ;;
      --optional-reviewer)
        _prtend_pr_open_check_value --optional-reviewer "${2:-}" || return $?
        optional_reviewers+=("$2"); shift 2 ;;
      --optional-reviewer=*)
        local v="${1#--optional-reviewer=}"
        if [[ -z "$v" ]]; then
          prtend_log_error "pr-open: --optional-reviewer requires a non-empty argument"; return 2
        fi
        optional_reviewers+=("$v"); shift ;;
      *)
        prtend_log_error "pr-open: unknown argument '$1'"; return 2 ;;
    esac
  done

  if [[ -z "$title" ]]; then
    prtend_log_error "pr-open: --title is required"
    return 2
  fi

  # 1. Git repo + readiness gate.
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    printf 'prtend: not in a git repository\n' >&2
    return 1
  fi
  local rc=0
  prtend_forge_cli_ready || rc=$?
  if (( rc != 0 )); then
    return "$rc"
  fi

  # 2. Resolve current branch and default branch.
  local branch
  if ! branch="$(prtend_forge_current_branch)"; then
    prtend_log_error "pr-open: unable to resolve current branch"
    return 1
  fi
  local default_branch=""
  default_branch="$(prtend_forge_default_branch 2>/dev/null || true)"
  if [[ -n "$default_branch" && "$default_branch" == "$branch" ]]; then
    printf "prtend: refusing to open a PR from the default branch ('%s')\n" "$branch" >&2
    return 2
  fi

  # 3. Active remote.
  local remote
  if ! remote="$(prtend_forge_active_remote)"; then
    prtend_log_error "pr-open: no git remote configured"
    return 1
  fi

  # 4. Existing-PR probe. `pr_for_branch` is open-only; when it reports no
  #    open PR we also check for closed/merged PRs on the same branch via
  #    `pr_last_for_branch` so we refuse instead of silently creating a
  #    duplicate.
  local pr="" pr_existed_open=0
  rc=0
  pr="$(prtend_forge_pr_for_branch "$branch" 2>/dev/null)" || rc=$?
  if (( rc == 2 )); then
    printf "prtend: branch '%s' has multiple open PRs; refusing\n" "$branch" >&2
    return 4
  elif (( rc == 0 )); then
    local state_json state
    if ! state_json="$(prtend_forge_pr_state "$pr")"; then
      prtend_log_error "pr-open: forge call failed resolving pr_state for #$pr"
      return 3
    fi
    state="$(printf '%s' "$state_json" | jq -r '.state')"
    case "$state" in
      open|draft)
        pr_existed_open=1 ;;
      closed|merged)
        printf "prtend: branch '%s' has a closed/merged PR (#%s); user must decide reopen/new/abort\n" \
          "$branch" "$pr" >&2
        return 4 ;;
      *)
        prtend_log_error "pr-open: unexpected pr_state '$state' for #$pr"
        return 1 ;;
    esac
  elif (( rc == 1 )); then
    # No open PR. Check whether a closed or merged PR exists for the branch.
    local last_pr="" lrc=0
    last_pr="$(prtend_forge_pr_last_for_branch "$branch" 2>/dev/null)" || lrc=$?
    if (( lrc == 0 )) && [[ -n "$last_pr" ]]; then
      local last_state_json last_state
      if ! last_state_json="$(prtend_forge_pr_state "$last_pr")"; then
        prtend_log_error "pr-open: forge call failed resolving pr_state for #$last_pr"
        return 3
      fi
      last_state="$(printf '%s' "$last_state_json" | jq -r '.state')"
      case "$last_state" in
        closed|merged)
          printf "prtend: branch '%s' has a closed/merged PR (#%s); user must decide reopen/new/abort\n" \
            "$branch" "$last_pr" >&2
          return 4 ;;
        *) ;;  # open/draft would mean a race with the open probe; let creation path run.
      esac
    fi
  else
    return "$rc"
  fi

  # 5. Push decision booleans.
  local branch_on_remote=0 local_ahead=0
  if git ls-remote --exit-code --heads "$remote" "$branch" >/dev/null 2>&1; then
    branch_on_remote=1
    git fetch --quiet "$remote" "$branch" 2>/dev/null || true
    local local_sha remote_sha
    local_sha="$(git rev-parse HEAD 2>/dev/null || true)"
    remote_sha="$(git rev-parse "$remote/$branch" 2>/dev/null || true)"
    if [[ -n "$local_sha" && -n "$remote_sha" && "$local_sha" != "$remote_sha" ]]; then
      if git merge-base --is-ancestor "$remote/$branch" HEAD 2>/dev/null; then
        local_ahead=1
      else
        printf "prtend: branch '%s' diverges from %s/%s; push manually first\n" \
          "$branch" "$remote" "$branch" >&2
        return 1
      fi
    fi
  fi

  # 6. Push and choose action.
  local action=""
  if (( pr_existed_open == 1 )); then
    if (( local_ahead == 1 )); then
      if ! git push "$remote" "$branch"; then
        return 1
      fi
      action="pushed_existing_pr"
    else
      action="used_existing"
    fi
  else
    if (( branch_on_remote == 0 )); then
      if ! git push --set-upstream "$remote" "$branch"; then
        return 1
      fi
      action="created"
    else
      if (( local_ahead == 1 )); then
        if ! git push "$remote" "$branch"; then
          return 1
        fi
      fi
      action="created_existing_branch"
    fi
  fi

  # 7. Create PR if needed.
  if (( pr_existed_open == 0 )); then
    local -a create_args=(--title "$title" --body "$body")
    if (( draft == 1 )); then
      create_args+=(--draft)
    fi
    if [[ -n "$target" ]]; then
      create_args+=(--target-branch "$target")
    elif [[ -n "$default_branch" ]]; then
      create_args+=(--target-branch "$default_branch")
    fi
    if ! pr="$(prtend_forge_pr_create "${create_args[@]}")"; then
      return 1
    fi
  fi

  # 8. Resolve URL and final state.
  local url state state_json
  if ! url="$(prtend_forge_pr_url "$pr")"; then
    prtend_log_error "pr-open: unable to resolve URL for #$pr"
    return 1
  fi
  if ! state_json="$(prtend_forge_pr_state "$pr")"; then
    prtend_log_error "pr-open: unable to resolve state for #$pr"
    return 1
  fi
  state="$(printf '%s' "$state_json" | jq -r '.state')"

  # 9. Reviewer flow. Combine system (config) + optional (flags), preserve
  #    order, dedup.
  local -a system_reviewers=()
  if command -v prtend_config_list_get >/dev/null 2>&1; then
    local sysline
    while IFS= read -r sysline; do
      [[ -n "$sysline" ]] && system_reviewers+=("$sysline")
    done < <(prtend_config_list_get system_reviewers || true)
  fi

  local -a all_reviewers=()
  local -A seen=()
  local r
  for r in "${system_reviewers[@]}" "${optional_reviewers[@]}"; do
    if [[ -z "${seen[$r]:-}" ]]; then
      seen[$r]=1
      all_reviewers+=("$r")
    fi
  done

  local -a requested=() skipped=()
  for r in "${all_reviewers[@]}"; do
    rc=0
    prtend_forge_reviewer_add "$pr" "$r" >/dev/null || rc=$?
    if (( rc == 0 )); then
      requested+=("$r")
    elif (( rc == 1 )); then
      printf "pr-open: reviewer '%s' rejected by forge\n" "$r" >&2
      skipped+=("$r")
    else
      return "$rc"
    fi
  done

  # 10. Emit JSON.
  local requested_json skipped_json
  requested_json="$(printf '%s\n' "${requested[@]:-}" | jq -R . | jq -cs 'map(select(. != ""))')"
  skipped_json="$(printf '%s\n' "${skipped[@]:-}" | jq -R . | jq -cs 'map(select(. != ""))')"

  jq -cn \
    --argjson pr "$pr" \
    --arg action "$action" \
    --arg url "$url" \
    --arg state "$state" \
    --argjson requested "$requested_json" \
    --argjson skipped "$skipped_json" \
    '{
       pr: $pr,
       action: $action,
       url: $url,
       state: $state,
       reviewers_requested: $requested,
       reviewers_skipped: $skipped
     }'
}
