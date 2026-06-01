#!/usr/bin/env bash
# defer_write.bash — `prtend defer-write` subcommand.
# Writes a Markdown defer doc (YAML frontmatter + sections) capturing a review
# comment for later resolution. Idempotent: re-invocation against the same
# (pr, comment) returns the existing path without overwriting the file. Does
# NOT post a resolution note — that's a separate `note-post --kind defer` call.

set -euo pipefail

_prtend_defer_write_check_value() {
  local flag="$1" val="${2:-__MISSING__}"
  if [[ "$val" == "__MISSING__" || -z "$val" || "$val" == -* ]]; then
    prtend_log_error "defer-write: $flag requires a non-empty argument"
    return 2
  fi
}

# Extract a snippet centered on $line (±3 lines) from $path. Echoes the raw
# snippet text on stdout, exit 0 on success. Exit 1 if path is missing/empty.
_prtend_defer_write_snippet() {
  local path="$1" line="$2" start end
  if [[ -z "$path" || ! -f "$path" ]]; then
    return 1
  fi
  start=$(( line - 3 ))
  (( start < 1 )) && start=1
  end=$(( line + 3 ))
  awk -v s="$start" -v e="$end" 'NR>=s && NR<=e { print }' "$path"
}

# Render every line of "$1" as a Markdown blockquote line on stdout. Blank
# input lines become bare `>` lines so the blockquote stays contiguous.
_prtend_defer_write_blockquote() {
  local body="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]]; then
      printf '>\n'
    else
      printf '> %s\n' "$line"
    fi
  done <<<"$body"
}

prtend_cmd_defer_write() {
  local pr="" comment_id="" reason=""

  while (( $# > 0 )); do
    case "$1" in
      --pr)
        _prtend_defer_write_check_value --pr "${2:-}" || return $?
        pr="$2"; shift 2 ;;
      --comment)
        _prtend_defer_write_check_value --comment "${2:-}" || return $?
        comment_id="$2"; shift 2 ;;
      --reason)
        _prtend_defer_write_check_value --reason "${2:-}" || return $?
        reason="$2"; shift 2 ;;
      *)
        prtend_log_error "defer-write: unknown argument '$1'"; return 2 ;;
    esac
  done

  if [[ -z "$pr" ]]; then
    prtend_log_error "defer-write: --pr is required"; return 2
  fi
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    prtend_log_error "defer-write: --pr must be a positive integer"; return 2
  fi
  if [[ -z "$comment_id" ]]; then
    prtend_log_error "defer-write: --comment is required"; return 2
  fi
  if [[ -z "$reason" ]]; then
    prtend_log_error "defer-write: --reason is required"; return 2
  fi
  # Multi-line reasons break YAML frontmatter without quoting; reject up front.
  if [[ "$reason" == *$'\n'* ]]; then
    printf 'prtend: --reason must not contain a newline\n' >&2
    return 2
  fi

  # 1. Git repo + forge readiness.
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    printf 'prtend: not in a git repository\n' >&2
    return 1
  fi
  local rc=0
  prtend_forge_cli_ready || rc=$?
  if (( rc != 0 )); then
    return "$rc"
  fi

  # 2. Resolve config dir → derive defer doc path.
  local config_path config_dir defer_dir doc_path
  config_path="$(prtend_config_resolve)"
  if [[ -z "$config_path" ]]; then
    printf "prtend: no active config; run 'prtend config init' before defer-write\n" >&2
    return 4
  fi
  config_dir="$(dirname "$config_path")"
  defer_dir="$config_dir/deferred"
  doc_path="$defer_dir/${pr}-${comment_id}.md"

  # 4. Fetch comment info (always — even on idempotent re-call, we still need
  #    `url` for the JSON response). See "Key decisions" in step 11.
  local info=""
  rc=0
  info="$(prtend_forge_comment_info "$pr" "$comment_id" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) ;;
    1)
      printf 'prtend: comment %s not found on PR %s\n' "$comment_id" "$pr" >&2
      return 4 ;;
    3) return 3 ;;
    *) return 1 ;;
  esac

  local comment_url body_text author path_field line_field
  comment_url="$(printf '%s' "$info" | jq -r '.url // ""')"

  # 3. Idempotency: if the doc already exists, skip composition. We still emit
  #    the canonical JSON, sourcing `comment_url` from the fresh forge call.
  if [[ -e "$doc_path" ]]; then
    local abs_path
    abs_path="$(cd "$(dirname "$doc_path")" && pwd)/$(basename "$doc_path")"
    jq -cn \
      --arg path "$abs_path" \
      --argjson pr "$pr" \
      --arg cid "$comment_id" \
      --arg url "$comment_url" \
      '{path: $path, pr: $pr, comment_id: $cid, comment_url: $url}'
    return 0
  fi

  body_text="$(printf '%s' "$info" | jq -r '.body // ""')"
  author="$(printf '%s' "$info" | jq -r '.author // ""')"
  path_field="$(printf '%s' "$info" | jq -r '.path // ""')"
  line_field="$(printf '%s' "$info" | jq -r '.line // empty')"

  # 5. Snippet extraction from working tree.
  local snippet=""
  if [[ -n "$path_field" && -n "$line_field" && -f "$path_field" ]]; then
    snippet="$(_prtend_defer_write_snippet "$path_field" "$line_field" || true)"
  fi
  if [[ -z "$snippet" ]]; then
    snippet="<no snippet available — comment is not inline or path is not present in current HEAD>"
  fi

  # 6. Compose the doc.
  local forge deferred_at comment_loc quoted
  forge="$(prtend_forge_detect)" || forge=""
  deferred_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -n "$path_field" && -n "$line_field" ]]; then
    comment_loc="\`${path_field}:${line_field}\`"
  elif [[ -n "$path_field" ]]; then
    comment_loc="\`${path_field}\`"
  else
    comment_loc="(non-inline)"
  fi

  quoted="$(_prtend_defer_write_blockquote "$body_text")"

  local doc
  doc="$(cat <<EOF
---
pr: ${pr}
comment_id: ${comment_id}
forge: ${forge}
deferred_at: ${deferred_at}
reason: ${reason}
---

# Deferred review feedback — PR #${pr}, comment ${comment_id}

## Comment location

${comment_loc}

## Reviewer

@${author}

## Original comment

${quoted}

## Code in question

\`\`\`
${snippet}
\`\`\`

## Reason for deferral

${reason}

## Comment link

${comment_url}
EOF
)"

  # 7. Atomic write (creates parent dir if missing).
  if ! printf '%s\n' "$doc" | prtend_atomic_write "$doc_path"; then
    return 1
  fi

  # 8. Emit JSON.
  local abs_path
  abs_path="$(cd "$(dirname "$doc_path")" && pwd)/$(basename "$doc_path")"
  jq -cn \
    --arg path "$abs_path" \
    --argjson pr "$pr" \
    --arg cid "$comment_id" \
    --arg url "$comment_url" \
    '{path: $path, pr: $pr, comment_id: $cid, comment_url: $url}'
}
