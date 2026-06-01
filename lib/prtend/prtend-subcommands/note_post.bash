#!/usr/bin/env bash
# note_post.bash — `prtend note-post` subcommand.
# Renders a resolution-note body (with marker) and posts it as a reply to a
# review comment. Idempotent: refuses to double-post if the target comment
# already contains a prtend marker. Never resolves the thread.

set -euo pipefail

# shellcheck source=../prtend-notes-lib.bash
# shellcheck disable=SC1091
source "${PRTEND_LIB:-$(dirname "${BASH_SOURCE[0]}")/..}/prtend-notes-lib.bash"

_prtend_note_post_check_value() {
  local flag="$1" val="${2:-__MISSING__}"
  if [[ "$val" == "__MISSING__" || -z "$val" || "$val" == -* ]]; then
    prtend_log_error "note-post: $flag requires a non-empty argument"
    return 2
  fi
}

prtend_cmd_note_post() {
  local pr="" comment="" kind="" reason="" commit="" doc=""

  while (( $# > 0 )); do
    case "$1" in
      --pr)
        _prtend_note_post_check_value --pr "${2:-}" || return $?
        pr="$2"; shift 2 ;;
      --comment)
        _prtend_note_post_check_value --comment "${2:-}" || return $?
        comment="$2"; shift 2 ;;
      --kind)
        _prtend_note_post_check_value --kind "${2:-}" || return $?
        kind="$2"; shift 2 ;;
      --reason)
        _prtend_note_post_check_value --reason "${2:-}" || return $?
        reason="$2"; shift 2 ;;
      --commit)
        _prtend_note_post_check_value --commit "${2:-}" || return $?
        commit="$2"; shift 2 ;;
      --doc)
        _prtend_note_post_check_value --doc "${2:-}" || return $?
        doc="$2"; shift 2 ;;
      *)
        prtend_log_error "note-post: unknown argument '$1'"; return 2 ;;
    esac
  done

  if [[ -z "$pr" ]]; then
    prtend_log_error "note-post: --pr is required"; return 2
  fi
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    prtend_log_error "note-post: --pr must be a positive integer"; return 2
  fi
  if [[ -z "$comment" ]]; then
    prtend_log_error "note-post: --comment is required"; return 2
  fi
  if [[ -z "$kind" ]]; then
    prtend_log_error "note-post: --kind is required"; return 2
  fi

  # Kind validation. `ignore` gets a targeted message — common skill-side bug.
  case "$kind" in
    reject|accept|halt|defer) ;;
    ignore)
      printf "prtend: --kind 'ignore' is not valid for note-post (Ignore posts nothing)\n" >&2
      return 2 ;;
    *)
      printf "prtend: invalid --kind '%s' (expected reject|accept|halt|defer)\n" "$kind" >&2
      return 2 ;;
  esac

  # Pairing table: required flag and forbidden flags per kind.
  local required forbid_list
  case "$kind" in
    reject) required="--reason"; forbid_list="--commit,--doc" ;;
    accept) required="--commit"; forbid_list="--reason,--doc"  ;;
    halt)   required="--reason"; forbid_list="--commit,--doc"  ;;
    defer)  required="--doc";    forbid_list="--reason,--commit" ;;
  esac

  local req_ok=0
  case "$required" in
    --reason) [[ -n "$reason" ]] && req_ok=1 ;;
    --commit) [[ -n "$commit" ]] && req_ok=1 ;;
    --doc)    [[ -n "$doc"    ]] && req_ok=1 ;;
  esac

  local violated=0 f forbidden
  IFS=',' read -r -a forbidden <<<"$forbid_list"
  for f in "${forbidden[@]}"; do
    case "$f" in
      --reason) [[ -n "$reason" ]] && violated=1 ;;
      --commit) [[ -n "$commit" ]] && violated=1 ;;
      --doc)    [[ -n "$doc"    ]] && violated=1 ;;
    esac
  done

  if (( req_ok == 0 || violated == 1 )); then
    printf "prtend: --kind %s requires %s and forbids %s\n" \
      "$kind" "$required" "${forbid_list//,/, }" >&2
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

  # 2. Idempotency probe. Read existing body; check for marker.
  local body_existing="" probe_rc=0
  body_existing="$(prtend_forge_comment_body "$pr" "$comment" 2>/dev/null)" || probe_rc=$?
  case "$probe_rc" in
    0)
      if prtend_note_is_handled "$body_existing"; then
        printf 'prtend: comment %s already has a prtend marker; refusing to double-post\n' \
          "$comment" >&2
        return 4
      fi
      ;;
    1)
      printf 'prtend: comment %s not found on PR %s\n' "$comment" "$pr" >&2
      return 4
      ;;
    3)
      return 3 ;;
    *)
      return 1 ;;
  esac

  # 3. Render the note body via the notes lib.
  local body=""
  case "$kind" in
    reject) body="$(prtend_note_reject "$reason")" ;;
    accept) body="$(prtend_note_accept "$commit")" ;;
    halt)   body="$(prtend_note_halt   "$reason")" ;;
    defer)  body="$(prtend_note_defer  "$doc")"    ;;
  esac
  if [[ -z "$body" ]]; then
    prtend_log_error "note-post: rendered body is empty"
    return 1
  fi

  # 4. Post the reply (body via stdin).
  local reply_id=""
  if ! reply_id="$(printf '%s' "$body" | prtend_forge_post_review_reply "$pr" "$comment")"; then
    return 1
  fi
  if [[ -z "$reply_id" ]]; then
    prtend_log_error "note-post: forge returned empty reply id"
    return 1
  fi

  # 5. Emit JSON. comment_id and reply_id always strings.
  local marker_version
  marker_version="$(prtend_note_marker_version)"

  jq -cn \
    --arg comment_id "$comment" \
    --arg reply_id "$reply_id" \
    --arg kind "$kind" \
    --arg marker_version "$marker_version" \
    --arg body "$body" \
    '{
       posted: true,
       comment_id: $comment_id,
       reply_id: $reply_id,
       kind: $kind,
       marker_version: $marker_version,
       body: $body
     }'
}
