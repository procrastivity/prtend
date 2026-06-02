#!/usr/bin/env bash
# prtend-forge-lib.bash — forge abstraction over gh/glab.
# Sourced by bin/prtend and any subcommand that needs to talk to a forge.
# Sourcing must have no side effects (no probing of $PATH, no git calls);
# all detection happens lazily inside the public functions.

if [[ -n "${PRTEND_FORGE_LIB_LOADED:-}" ]]; then
  return 0
fi
PRTEND_FORGE_LIB_LOADED=1

set -euo pipefail

# Signature derivation used by ci_failures; sourced here so callers of
# prtend_forge_ci_failures don't have to remember a second lib.
# shellcheck source=lib/prtend/prtend-signature-lib.bash
# shellcheck disable=SC1091
source "${BASH_SOURCE[0]%/*}/prtend-signature-lib.bash"

# -- internal dispatch -----------------------------------------------------

# Calls _prtend_forge_gh_<suffix> or _prtend_forge_gl_<suffix> based on the
# active forge. Detects on demand if $PRTEND_FORGE is unset.
prtend_forge_dispatch() {
  local suffix="${1:-}"
  if [[ -z "$suffix" ]]; then
    prtend_log_error "prtend_forge_dispatch: missing suffix argument"
    return 2
  fi
  shift
  if [[ -z "${PRTEND_FORGE:-}" ]]; then
    prtend_forge_detect >/dev/null || return $?
  fi
  local handler
  case "$PRTEND_FORGE" in
    github) handler="_prtend_forge_gh_${suffix}" ;;
    gitlab) handler="_prtend_forge_gl_${suffix}" ;;
    *)
      prtend_log_error "prtend_forge_dispatch: unknown forge '$PRTEND_FORGE'"
      return 2
      ;;
  esac
  if ! declare -F "$handler" >/dev/null; then
    prtend_log_error "prtend_forge_dispatch: handler '$handler' not implemented"
    return 2
  fi
  "$handler" "$@"
}

# -- detection -------------------------------------------------------------

# Sniff a forge from a git remote URL. Echoes "github" | "gitlab" or nothing.
# Extracts the host first, then matches on dot-bounded labels so hosts like
# `notgithub.com` or `fakegitlab.io` don't match — only real `github`/`gitlab`
# domain labels do (covers `github.com`, GHE hosts like `github.example.com`,
# `git.gitlab.mycorp`, etc.).
_prtend_forge_sniff_url() {
  local url="${1:-}" host
  if [[ -z "$url" ]]; then
    return 1
  fi
  if [[ "$url" == *"://"* ]]; then
    host="${url#*://}"
    host="${host#*@}"
    host="${host%%/*}"
    host="${host%%:*}"
  elif [[ "$url" == *:* ]]; then
    host="${url#*@}"
    host="${host%%:*}"
  else
    return 1
  fi
  # Hostnames are case-insensitive — normalise before label matching.
  host="${host,,}"
  # Match `github` / `gitlab` only as a full dot-separated label.
  case ".${host}." in
    *.github.*) printf 'github\n' ;;
    *.gitlab.*) printf 'gitlab\n' ;;
    *) return 1 ;;
  esac
}

# Resolve the host of the remote tracked by the current branch's upstream.
# Echoes "github" | "gitlab" or nothing if no upstream / unrecognised host.
_prtend_forge_from_upstream() {
  local upstream remote url
  if ! upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    return 1
  fi
  remote="${upstream%%/*}"
  if [[ -z "$remote" || "$remote" == "$upstream" ]]; then
    return 1
  fi
  if ! url="$(git remote get-url "$remote" 2>/dev/null)"; then
    return 1
  fi
  _prtend_forge_sniff_url "$url"
}

prtend_forge_detect() {
  if [[ -n "${PRTEND_FORGE:-}" ]]; then
    case "$PRTEND_FORGE" in
      github|gitlab)
        printf '%s\n' "$PRTEND_FORGE"
        return 0
        ;;
      *)
        prtend_log_error "prtend_forge_detect: invalid PRTEND_FORGE='$PRTEND_FORGE' (expected 'github' or 'gitlab')"
        return 2
        ;;
    esac
  fi

  local gh_ok=0 gl_ok=0 hint
  if command -v gh >/dev/null 2>&1; then
    if gh repo view --json url >/dev/null 2>&1; then
      gh_ok=1
    fi
  fi
  if command -v glab >/dev/null 2>&1; then
    if glab repo view --output json >/dev/null 2>&1; then
      gl_ok=1
    fi
  fi

  if (( gh_ok == 1 && gl_ok == 1 )); then
    # Both CLIs see a repo (origin + mirror). Prefer the forge that backs the
    # upstream tracking branch's remote; fall back to gh.
    if hint="$(_prtend_forge_from_upstream)" && [[ -n "$hint" ]]; then
      PRTEND_FORGE="$hint"
    else
      PRTEND_FORGE=github
    fi
    export PRTEND_FORGE
    printf '%s\n' "$PRTEND_FORGE"
    return 0
  elif (( gh_ok == 1 )); then
    PRTEND_FORGE=github
    export PRTEND_FORGE
    printf '%s\n' "$PRTEND_FORGE"
    return 0
  elif (( gl_ok == 1 )); then
    PRTEND_FORGE=gitlab
    export PRTEND_FORGE
    printf '%s\n' "$PRTEND_FORGE"
    return 0
  fi

  # Fallback: URL sniff the origin so `doctor` can still hint at the forge
  # when no CLI is installed.
  local url
  if url="$(git remote get-url origin 2>/dev/null)" && hint="$(_prtend_forge_sniff_url "$url")"; then
    PRTEND_FORGE="$hint"
    export PRTEND_FORGE
    printf '%s\n' "$PRTEND_FORGE"
    return 0
  fi

  return 1
}

# -- readiness -------------------------------------------------------------

_prtend_forge_gh_cli_ready() {
  command -v gh >/dev/null 2>&1 || return 3
  gh auth status >/dev/null 2>&1 || return 1
  return 0
}

_prtend_forge_gl_cli_ready() {
  command -v glab >/dev/null 2>&1 || return 3
  glab auth status >/dev/null 2>&1 || return 1
  return 0
}

prtend_forge_cli_ready() {
  # `set -e` would abort on a bare non-zero `prtend_forge_detect` call before
  # `rc=$?` could capture; wrapping with `|| rc=$?` neutralises that so the
  # mapping below actually runs.
  local rc=0
  prtend_forge_detect >/dev/null || rc=$?
  if (( rc != 0 )); then
    # Only the "couldn't detect a forge" case (exit 1) maps to the documented
    # "CLI not installed" exit code (3). Other detect failures — e.g. an
    # invalid PRTEND_FORGE override (exit 2) — propagate as-is so callers
    # like `doctor` can distinguish "no forge here" from "user gave us junk".
    if (( rc == 1 )); then
      return 3
    fi
    return "$rc"
  fi
  prtend_forge_dispatch cli_ready
}

# -- branch ----------------------------------------------------------------

prtend_forge_current_branch() {
  git rev-parse --abbrev-ref HEAD
}

# -- default branch --------------------------------------------------------

prtend_forge_default_branch() {
  prtend_forge_dispatch default_branch "$@"
}

_prtend_forge_gh_default_branch() {
  local out
  out="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)" || return $?
  if [[ -z "$out" ]]; then return 1; fi
  printf '%s\n' "$out"
}

_prtend_forge_gl_default_branch() {
  local out
  out="$(glab repo view --output json | jq -r '.default_branch // empty')" || return $?
  if [[ -z "$out" ]]; then return 1; fi
  printf '%s\n' "$out"
}

# -- active remote ---------------------------------------------------------

# Forge-agnostic. Prints the remote name PRs/MRs go to: branch upstream's
# remote if set, else `origin` if it exists, else the first remote sorted
# lexicographically. Exit 1 if no remotes at all.
prtend_forge_active_remote() {
  local upstream remote remotes
  if upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    remote="${upstream%%/*}"
    if [[ -n "$remote" && "$remote" != "$upstream" ]]; then
      printf '%s\n' "$remote"
      return 0
    fi
  fi
  if git remote get-url origin >/dev/null 2>&1; then
    printf 'origin\n'
    return 0
  fi
  remotes="$(git remote 2>/dev/null | sort)"
  if [[ -z "$remotes" ]]; then
    return 1
  fi
  printf '%s\n' "$remotes" | head -n1
}

# -- repo identity helpers -------------------------------------------------

# {owner}/{repo} for the current GitHub remote. Per-call; do not cache across
# invocations (would require a global to invalidate). See docs/steps/step-04.
_prtend_forge_gh_repo_slug() {
  gh repo view --json nameWithOwner -q .nameWithOwner
}

# Numeric project ID for the current GitLab remote. Per-call; not cached.
_prtend_forge_gl_project_id() {
  glab repo view --output json | jq -r '.id'
}

# Convert an ISO-8601 timestamp to epoch seconds. Tries GNU `date -d` first,
# falls back to BSD `date -j -f`. GitLab timestamps routinely include
# fractional seconds (e.g. `...03.176Z`); BSD `date` can't parse those, so
# strip the fractional portion before the BSD form. Echoes the epoch on
# stdout, exit 0 on success, exit 1 if neither form parses.
_prtend_iso_to_epoch() {
  local ts="$1" out clean
  if out="$(date -u -d "$ts" +%s 2>/dev/null)"; then
    printf '%s\n' "$out"; return 0
  fi
  case "$ts" in
    *.[0-9]*Z) clean="${ts%.*}Z" ;;
    *)         clean="$ts" ;;
  esac
  if out="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$clean" +%s 2>/dev/null)"; then
    printf '%s\n' "$out"; return 0
  fi
  return 1
}

# -- pr_for_branch ---------------------------------------------------------

prtend_forge_pr_for_branch() {
  prtend_forge_dispatch pr_for_branch "$@"
}

# Exit 0 + number on single match; exit 1 + empty on no match;
# exit 2 + empty on multiple matches.
_prtend_forge_gh_pr_for_branch() {
  local branch="${1:-}" out count
  if [[ -z "$branch" ]]; then
    prtend_log_error "pr_for_branch: missing branch argument"
    return 2
  fi
  out="$(gh pr list --head "$branch" --state open --json number)" || return $?
  count="$(printf '%s' "$out" | jq 'length')"
  if (( count == 0 )); then return 1; fi
  if (( count > 1 )); then return 2; fi
  printf '%s\n' "$out" | jq -r '.[0].number'
}

_prtend_forge_gl_pr_for_branch() {
  local branch="${1:-}" project_id out filtered count
  if [[ -z "$branch" ]]; then
    prtend_log_error "pr_for_branch: missing branch argument"
    return 2
  fi
  project_id="$(_prtend_forge_gl_project_id)" || return $?
  out="$(glab mr list --source-branch "$branch" --state opened --output json)" || return $?
  filtered="$(printf '%s' "$out" | jq --argjson pid "$project_id" \
    '[ .[] | select(.target_project_id == $pid) ]')"
  count="$(printf '%s' "$filtered" | jq 'length')"
  if (( count == 0 )); then return 1; fi
  if (( count > 1 )); then return 2; fi
  printf '%s\n' "$filtered" | jq -r '.[0].iid'
}

# -- pr_last_for_branch ----------------------------------------------------

# Most recent PR for the branch regardless of state (open / closed / merged).
# Exit 0 + number on hit, exit 1 + empty when the branch has never had a PR.
# Used by `pr-open` to detect "branch already has a closed/merged PR" — the
# open-only `pr_for_branch` misses that case and would let pr-open silently
# create a duplicate.
prtend_forge_pr_last_for_branch() {
  prtend_forge_dispatch pr_last_for_branch "$@"
}

_prtend_forge_gh_pr_last_for_branch() {
  local branch="${1:-}" out
  if [[ -z "$branch" ]]; then
    prtend_log_error "pr_last_for_branch: missing branch argument"; return 2
  fi
  out="$(gh pr list --head "$branch" --state all --json number,createdAt)" || return $?
  if [[ "$(printf '%s' "$out" | jq 'length')" == 0 ]]; then return 1; fi
  printf '%s' "$out" | jq -r 'sort_by(.createdAt) | last | .number'
}

_prtend_forge_gl_pr_last_for_branch() {
  local branch="${1:-}" project_id out filtered
  if [[ -z "$branch" ]]; then
    prtend_log_error "pr_last_for_branch: missing branch argument"; return 2
  fi
  project_id="$(_prtend_forge_gl_project_id)" || return $?
  out="$(glab mr list --source-branch "$branch" --state all --output json)" || return $?
  filtered="$(printf '%s' "$out" | jq --argjson pid "$project_id" \
    '[ .[] | select(.target_project_id == $pid) ]')"
  if [[ "$(printf '%s' "$filtered" | jq 'length')" == 0 ]]; then return 1; fi
  printf '%s' "$filtered" | jq -r 'sort_by(.created_at) | last | .iid'
}

# -- pr_state --------------------------------------------------------------

prtend_forge_pr_state() {
  prtend_forge_dispatch pr_state "$@"
}

_prtend_forge_gh_pr_state() {
  local pr="${1:-}"
  if [[ -z "$pr" ]]; then
    prtend_log_error "pr_state: missing pr argument"; return 2
  fi
  gh pr view "$pr" --json state,isDraft | jq -c '
    if .state == "OPEN" and (.isDraft // false) then {state: "draft"}
    elif .state == "OPEN" then {state: "open"}
    elif .state == "MERGED" then {state: "merged"}
    elif .state == "CLOSED" then {state: "closed"}
    else {state: (.state // "" | ascii_downcase)} end'
}

_prtend_forge_gl_pr_state() {
  local pr="${1:-}"
  if [[ -z "$pr" ]]; then
    prtend_log_error "pr_state: missing pr argument"; return 2
  fi
  glab mr view "$pr" --output json | jq -c '
    if .state == "opened" and (.draft // false) then {state: "draft"}
    elif .state == "opened" then {state: "open"}
    elif .state == "merged" then {state: "merged"}
    elif .state == "closed" or .state == "locked" then {state: "closed"}
    else {state: (.state // "")} end'
}

# -- ci_status -------------------------------------------------------------

prtend_forge_ci_status() {
  prtend_forge_dispatch ci_status "$@"
}

# `gh pr checks` exits non-zero (e.g. 8) when checks have failed or are still
# pending — that is data, not an API error. Capture exit code and treat any
# JSON output as authoritative; only propagate the failure when stdout is empty.
_prtend_forge_gh_ci_status() {
  local pr="${1:-}" out rc=0
  if [[ -z "$pr" ]]; then
    prtend_log_error "ci_status: missing pr argument"; return 2
  fi
  # `gh pr checks --json` exposes `bucket` (pass/fail/pending/skipping/cancel)
  # rather than a separate conclusion field; we map bucket → canonical conclusion.
  # When the PR has no checks at all, gh exits 1 with empty stdout and the
  # string "no checks reported" on stderr — that's a valid observation, not
  # an error, so we distinguish it from genuine API failures.
  local err_file err
  err_file="$(mktemp)"
  out="$(gh pr checks "$pr" --json name,state,bucket,link 2>"$err_file")" || rc=$?
  err="$(cat "$err_file")"; rm -f "$err_file"
  if [[ -z "$out" ]]; then
    if (( rc != 0 )) && [[ "$err" != *"no checks reported"* ]]; then
      printf '%s\n' "$err" >&2
      return "$rc"
    fi
    printf '{"state":"pending","checks":[]}\n'
    return 0
  fi
  printf '%s' "$out" | jq -c '
    def map_bucket(b):
      if   b == "pass"     then "success"
      elif b == "fail"     then "failure"
      elif b == "pending"  then "pending"
      elif b == "skipping" then "skipped"
      elif b == "cancel"   then "cancelled"
      else (b // "") end;
    def per_check: {
      name:       (.name // ""),
      state:      ((.state // "") | ascii_downcase),
      conclusion: map_bucket(.bucket // ""),
      url:        (.link // "")
    };
    (map(per_check)) as $cs
    | { state: (
          if   any($cs[]; .conclusion == "failure")   then "failure"
          elif any($cs[]; .conclusion == "pending")   then "running"
          elif ($cs | length) == 0                    then "pending"
          elif all($cs[]; .conclusion == "cancelled") then "cancelled"
          else "success" end),
        checks: $cs }'
}

# Two-step: MR view → head_pipeline.id; then `glab ci status --pipeline`.
# "No pipeline yet" is a valid observation, not an error.
_prtend_forge_gl_ci_status() {
  local pr="${1:-}" mr_json pipeline_id pipeline_status jobs_json
  if [[ -z "$pr" ]]; then
    prtend_log_error "ci_status: missing pr argument"; return 2
  fi
  mr_json="$(glab mr view "$pr" --output json)" || return $?
  pipeline_id="$(printf '%s' "$mr_json" | jq -r '.head_pipeline.id // empty')"
  if [[ -z "$pipeline_id" ]]; then
    printf '{"state":"pending","checks":[]}\n'
    return 0
  fi
  pipeline_status="$(printf '%s' "$mr_json" | jq -r '.head_pipeline.status // "pending"')"
  jobs_json="$(glab ci status --pipeline "$pipeline_id" --output json)" || return $?
  printf '%s' "$jobs_json" | jq -c --arg pstate "$pipeline_status" '
    def map_state(s):
      if   s == "failed"   then "failure"
      elif s == "success"  then "success"
      elif s == "running"  then "running"
      elif s == "pending"  then "pending"
      elif s == "canceled" then "cancelled"
      else s end;
    (if type == "array" then . else (.jobs // []) end) as $jobs
    | { state: map_state($pstate),
        checks: [ $jobs[] | {
          name:       (.name // ""),
          state:      (.status // ""),
          conclusion: map_state(.status // ""),
          url:        (.web_url // "")
        } ] }'
}

# -- reviews_since ---------------------------------------------------------

prtend_forge_reviews_since() {
  prtend_forge_dispatch reviews_since "$@"
}

# Cursor for GitHub is the last seen review ID (numeric). Empty cursor → all.
# next_cursor is the largest review id observed (or the input cursor if no
# new reviews). Per-batch comment_ids require a second API call per review.
_prtend_forge_gh_reviews_since() {
  local pr="${1:-}" cursor="${2:-}" slug reviews_json filtered count i
  local review_id submitted_at author state comments_json comment_ids batch
  local batches batch_resume_cursor next_cursor cur_ts cur_id legacy
  if [[ -z "$pr" ]]; then
    prtend_log_error "reviews_since: missing pr argument"; return 2
  fi
  slug="$(_prtend_forge_gh_repo_slug)" || return $?

  # Cursor wire format: "<submitted_at>|<id>". A review-id-only cursor
  # would lose lower-id pending drafts that get submitted *after* a
  # higher-id review is processed: GitHub assigns ids at draft creation,
  # not at submission, so a draft with id=100 created before id=200 may
  # show up in the API only later, with `.id > 200_cursor` filtering it
  # out forever. The pair `(submitted_at, id)` is monotonic in submission
  # order (id is the tie-breaker for same-instant submissions).
  #
  # Backward compatibility: an earlier version (and the original docs)
  # documented the cursor as just the last seen review id. A bare numeric
  # cursor coming from an existing state file or an explicit `--cursor 200`
  # call is interpreted under the legacy id-only semantic (`.id > $cur_id`)
  # so it doesn't silently re-emit every review; the next emission writes
  # the new compound form, self-healing the state file.
  legacy=0
  if [[ -z "$cursor" ]]; then
    cur_ts=""; cur_id=0
  elif [[ "$cursor" == *"|"* ]]; then
    cur_ts="${cursor%|*}"
    cur_id="${cursor##*|}"
  elif [[ "$cursor" =~ ^[0-9]+$ ]]; then
    cur_ts=""; cur_id="$cursor"; legacy=1
  else
    # Malformed: treat as "from the beginning" rather than fail closed —
    # the forge contract doesn't validate cursor strings.
    cur_ts=""; cur_id=0
  fi

  # `gh api --paginate` on a JSON-array endpoint usually merges pages, but
  # older versions and some endpoints emit one concatenated array per page.
  # Defensively slurp+flatten so the downstream jq filter sees one array.
  reviews_json="$(gh api "repos/${slug}/pulls/${pr}/reviews" --paginate | jq -s 'add // []')" || return $?

  filtered="$(printf '%s' "$reviews_json" | jq -c \
    --arg cur_ts "$cur_ts" --argjson cur_id "$cur_id" --argjson legacy "$legacy" '
    [ .[]
      | select(.submitted_at != null)
      | select(
          if $legacy == 1 then .id > $cur_id
          else (.submitted_at > $cur_ts)
               or (.submitted_at == $cur_ts and .id > $cur_id)
          end
        )
    ] | sort_by(.submitted_at, .id)')"
  count="$(printf '%s' "$filtered" | jq 'length')"
  batches='[]'
  next_cursor="$cursor"
  for ((i=0; i<count; i++)); do
    review_id="$(printf '%s' "$filtered" | jq -r ".[$i].id")"
    submitted_at="$(printf '%s' "$filtered" | jq -r ".[$i].submitted_at // \"\"")"
    author="$(printf '%s' "$filtered" | jq -r ".[$i].user.login // \"\"")"
    state="$(printf '%s' "$filtered" | jq -r "
      .[$i].state // \"\" | ascii_downcase
      | if . == \"changes_requested\" then \"changes_requested\"
        elif . == \"approved\" then \"approved\"
        else \"commented\" end")"
    # Propagate per-review comments errors; spec says don't swallow forge failures.
    comments_json="$(gh api "repos/${slug}/pulls/${pr}/reviews/${review_id}/comments" --paginate | jq -s 'add // []')" || return $?
    comment_ids="$(printf '%s' "$comments_json" | jq '[ .[] | (.id | tostring) ]')"
    # `resume_cursor` is the per-batch resume token — the compound
    # "submitted_at|id" pair the *next* call should pass to skip past this
    # batch alone. The subcommand uses it when `--block` emits one batch
    # out of N pending: state advances past just that one batch.
    batch_resume_cursor="${submitted_at}|${review_id}"
    batch="$(jq -nc \
      --arg id "$review_id" --arg sa "$submitted_at" \
      --arg au "$author" --arg st "$state" \
      --argjson cids "$comment_ids" \
      --arg rc "$batch_resume_cursor" \
      '{batch_id: $id, submitted_at: $sa, author: $au, state: $st,
        comment_ids: $cids, resume_cursor: $rc}')"
    batches="$(printf '%s' "$batches" | jq -c --argjson b "$batch" '. + [$b]')"
    # Batches are emission-sorted (submitted_at, id) ascending, so the
    # last batch's resume_cursor is the across-call next_cursor.
    next_cursor="$batch_resume_cursor"
  done
  jq -nc --argjson batches "$batches" --arg cursor "$next_cursor" \
    '{batches: $batches, next_cursor: $cursor}'
}

# Returns 0 if the discussion is settled (no new note has arrived within the
# quiet window), 1 otherwise. Used by step-05's reviews-poll subcommand.
# Argument: ISO-8601 timestamp of the latest note in the discussion.
_prtend_forge_gl_discussion_settled() {
  local latest="${1:-}" quiet_window now latest_epoch
  if [[ -z "$latest" ]]; then return 2; fi
  quiet_window="${PRTEND_QUIET_WINDOW:-60}"
  now="$(date -u +%s)"
  if ! latest_epoch="$(_prtend_iso_to_epoch "$latest")"; then
    return 2
  fi
  (( now - latest_epoch > quiet_window ))
}

# Cursor for GitLab is an ISO-8601 timestamp (the latest settled-note time
# seen so far). A discussion is emitted only when (a) all its notes are newer
# than the cursor, and (b) the latest note is older than now - PRTEND_QUIET_WINDOW.
_prtend_forge_gl_reviews_since() {
  local pr="${1:-}" cursor="${2:-}" project_id quiet_window now
  local discussions_json filtered batches next_cursor
  if [[ -z "$pr" ]]; then
    prtend_log_error "reviews_since: missing pr argument"; return 2
  fi
  project_id="$(_prtend_forge_gl_project_id)" || return $?
  quiet_window="${PRTEND_QUIET_WINDOW:-60}"
  now="$(date -u +%s)"

  discussions_json="$(glab api "projects/${project_id}/merge_requests/${pr}/discussions" --paginate)" || return $?

  # GitLab created_at strings include fractional seconds (e.g. `...46.176Z`).
  # We MUST preserve that precision in the cursor: two discussions whose
  # latest notes fall in the same whole second are common enough that a
  # second-precision cursor (the original implementation truncated via
  # `fromdateiso8601`) would advance past one and silently swallow the
  # others under `--block` (the next `all($times[]; . > $cur)` would
  # exclude any note at the same second). Compare ISO strings directly,
  # after normalizing to a canonical width — the only catch is that
  # backward-compat cursors written by an older version (or by the user)
  # might omit the fractional portion, so we pad to `.000Z`. Lex order on
  # the normalized form matches temporal order.
  filtered="$(printf '%s' "$discussions_json" | jq -s 'add // []' | jq -c \
    --arg cur "$cursor" --argjson now "$now" --argjson qw "$quiet_window" '
    def norm_iso:
      if test("\\.[0-9]+Z$") then . else sub("Z$"; ".000Z") end;
    def to_epoch_f:
      capture("^(?<sec>\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})(?<frac>\\.\\d+)?Z$") as $m
      | ($m.sec + "Z" | fromdateiso8601) + (($m.frac // "0") | tonumber);
    ($cur | if . == "" then "" else norm_iso end) as $cur_n
    | [ .[]
      | . as $d
      | ([ .notes[]? | select((.system // false) | not) ]) as $all_notes
      | ($all_notes | map(.created_at | norm_iso)) as $all_times
      | ($all_notes | map(select((.created_at | norm_iso) > $cur_n))) as $new_notes
      # Emit when ANY note is newer than the cursor — a discussion that
      # already settled past the cursor can still receive a fresh human
      # follow-up note, which is the case `overview.md` § "Edge cases"
      # item 11 ("New comment on a thread after Accept") explicitly
      # promises to surface. Requiring all notes > cursor would drop the
      # re-emission silently.
      | select(($new_notes | length) > 0)
      | ($all_times | max) as $_max_t
      | select(($_max_t | to_epoch_f) <= ($now - $qw))
      # Batch metadata is computed from the *new* notes. comment_ids is
      # restricted to the new subset so the subcommand projection emits
      # only fresh notes (old ones were already emitted on a prior call).
      | {
          batch_id:     (.id | tostring),
          submitted_at: ($new_notes | map(.created_at | norm_iso) | min),
          author:       ($new_notes[0].author.username // ""),
          state:        "commented",
          comment_ids:  ($new_notes | map(.id | tostring)),
          _max_t:       $_max_t
        }
    ] | sort_by(._max_t)')"

  # `resume_cursor` is the per-batch resume token — the normalized ISO max
  # settled-note timestamp for the batch (with `.NNN` fractional preserved).
  # The across-call `next_cursor` is the lex-max of per-batch resume_cursors.
  batches="$(printf '%s' "$filtered" | jq -c '
    [ .[] | . + { resume_cursor: ._max_t } | del(._max_t) ]')"
  next_cursor="$(printf '%s' "$filtered" | jq -r --arg fb "$cursor" '
    if length == 0 then $fb
    else ([ .[]._max_t ] | max) end')"

  jq -nc --argjson b "$batches" --arg c "$next_cursor" \
    '{batches: $b, next_cursor: $c}'
}

# -- review_comments -------------------------------------------------------

prtend_forge_review_comments() {
  prtend_forge_dispatch review_comments "$@"
}

# anchor_stale is always emitted as false here — the lib has no view of HEAD.
# Step-07's reviews-poll subcommand overwrites it after diffing against HEAD.
_prtend_forge_gh_review_comments() {
  local pr="${1:-}" review_id="${2:-}" slug
  if [[ -z "$pr" || -z "$review_id" ]]; then
    prtend_log_error "review_comments: missing pr or review-id argument"; return 2
  fi
  slug="$(_prtend_forge_gh_repo_slug)" || return $?
  # Slurp+flatten so multi-page responses still produce one canonical object.
  gh api "repos/${slug}/pulls/${pr}/reviews/${review_id}/comments" --paginate \
    | jq -s 'add // []' \
    | jq -c '
        { comments: [ .[] | {
            comment_id:   (.id | tostring),
            author:       (.user.login // ""),
            body:         (.body // ""),
            path:         (.path // ""),
            line:         (.line // .original_line // .start_line // null),
            anchor_stale: false,
            created_at:   (.created_at // "")
          } ] }'
}

_prtend_forge_gl_review_comments() {
  local pr="${1:-}" discussion_id="${2:-}" project_id
  if [[ -z "$pr" || -z "$discussion_id" ]]; then
    prtend_log_error "review_comments: missing pr or discussion-id argument"; return 2
  fi
  project_id="$(_prtend_forge_gl_project_id)" || return $?
  glab api "projects/${project_id}/merge_requests/${pr}/discussions/${discussion_id}" | jq -c '
    { comments: [ .notes[]? | select((.system // false) | not) | {
        comment_id:   (.id | tostring),
        author:       (.author.username // ""),
        body:         (.body // ""),
        path:         (.position.new_path // ""),
        line:         (.position.new_line // null),
        anchor_stale: false,
        created_at:   (.created_at // "")
      } ] }'
}

# -- comment_body ----------------------------------------------------------

prtend_forge_comment_body() {
  prtend_forge_dispatch comment_body "$@"
}

# Raw body text — NOT JSON. The skill's prtend_note_is_handled greps for the
# marker in the body; a JSON wrapper would force every caller to re-parse.
_prtend_forge_gh_comment_body() {
  local pr="${1:-}" comment_id="${2:-}" slug
  if [[ -z "$comment_id" ]]; then
    prtend_log_error "comment_body: missing comment-id argument"; return 2
  fi
  : "${pr:-}"  # signature consistency; gh endpoint is PR-independent
  slug="$(_prtend_forge_gh_repo_slug)" || return $?
  gh api "repos/${slug}/pulls/comments/${comment_id}" --jq .body
}

_prtend_forge_gl_comment_body() {
  local pr="${1:-}" comment_id="${2:-}" project_id
  if [[ -z "$pr" || -z "$comment_id" ]]; then
    prtend_log_error "comment_body: missing pr or comment-id argument"; return 2
  fi
  project_id="$(_prtend_forge_gl_project_id)" || return $?
  glab api "projects/${project_id}/merge_requests/${pr}/notes/${comment_id}" --jq .body
}

# -- comment_info ----------------------------------------------------------

# Structured cousin of `comment_body`: returns a canonical JSON object with
# the full single-comment metadata needed to render a defer document. See
# docs/forge-mapping.md § "Single comment body (for marker detection)" — the
# per-forge endpoints are the same, only the projection differs.
prtend_forge_comment_info() {
  prtend_forge_dispatch comment_info "$@"
}

_prtend_forge_gh_comment_info() {
  local pr="${1:-}" comment_id="${2:-}" slug raw owning_pr
  if [[ -z "$comment_id" ]]; then
    prtend_log_error "comment_info: missing comment-id argument"; return 2
  fi
  if [[ -n "$pr" && ! "$pr" =~ ^[0-9]+$ ]]; then
    prtend_log_error "comment_info: --pr must be a positive integer"; return 2
  fi
  slug="$(_prtend_forge_gh_repo_slug)" || return $?
  if ! raw="$(gh api "repos/${slug}/pulls/comments/${comment_id}" 2>/dev/null)"; then
    return 1
  fi
  # GitHub's review-comment endpoint is repo-scoped; `comment_id` alone could
  # belong to any PR in the repo. Cross-check the response's pull_request_url
  # (`.../pulls/<N>`) against the caller's `$pr` so a caller asking for
  # PR 123 doesn't silently get back PR 456's comment.
  if [[ -n "$pr" ]]; then
    owning_pr="$(printf '%s' "$raw" | jq -r '.pull_request_url // "" | capture("/pulls/(?<n>[0-9]+)$").n // ""')"
    if [[ -n "$owning_pr" && "$owning_pr" != "$pr" ]]; then
      return 1
    fi
  fi
  printf '%s' "$raw" | jq -c '{
    comment_id:   (.id | tostring),
    author:       (.user.login // ""),
    body:         (.body // ""),
    path:         (.path // ""),
    line:         (.line // .original_line // .start_line // null),
    url:          (.html_url // ""),
    created_at:   (.created_at // "")
  }'
}

_prtend_forge_gl_comment_info() {
  local pr="${1:-}" comment_id="${2:-}" project_id
  if [[ -z "$pr" || ! "$pr" =~ ^[0-9]+$ ]]; then
    prtend_log_error "comment_info: --pr must be a positive integer"; return 2
  fi
  if [[ -z "$comment_id" ]]; then
    prtend_log_error "comment_info: missing comment-id argument"; return 2
  fi
  project_id="$(_prtend_forge_gl_project_id)" || return $?
  if ! glab api "projects/${project_id}/merge_requests/${pr}/notes/${comment_id}" 2>/dev/null \
        | jq -c '{
            comment_id:   (.id | tostring),
            author:       (.author.username // ""),
            body:         (.body // ""),
            path:         (.position.new_path // ""),
            line:         (.position.new_line // null),
            url:          (.web_url // ""),
            created_at:   (.created_at // "")
          }'; then
    return 1
  fi
}

# -- review_thread_bodies --------------------------------------------------

# Concatenated bodies of every comment/note in the thread containing
# <comment_id>. Used by note-post to detect a prior prtend reply — the
# marker lives in the *reply* we post, not in the reviewer's original
# comment, so checking only the original body misses the handled case.
#
# Exit 0 + bodies joined by newlines on hit, exit 1 + empty if the comment
# id is unknown on this PR/MR.
prtend_forge_review_thread_bodies() {
  prtend_forge_dispatch review_thread_bodies "$@"
}

# GitHub review-comment replies are flat: every reply in a thread shares the
# same `in_reply_to_id` (the root). The root itself has no `in_reply_to_id`.
# We list all review comments on the PR, identify the thread root for
# <comment_id> (it might be the root or a reply), and concat every body
# whose id == root or whose in_reply_to_id == root.
_prtend_forge_gh_review_thread_bodies() {
  local pr="${1:-}" comment_id="${2:-}" slug all
  if [[ -z "$pr" || -z "$comment_id" ]]; then
    prtend_log_error "review_thread_bodies: missing pr or comment-id argument"; return 2
  fi
  slug="$(_prtend_forge_gh_repo_slug)" || return $?
  all="$(gh api "repos/${slug}/pulls/${pr}/comments" --paginate | jq -s 'add // []')" || return $?
  if [[ "$(printf '%s' "$all" | jq --arg cid "$comment_id" \
        '[.[] | select((.id|tostring) == $cid)] | length')" == "0" ]]; then
    return 1
  fi
  printf '%s' "$all" | jq -r --arg cid "$comment_id" '
    (map(select((.id|tostring) == $cid))[0]) as $target
    | (($target.in_reply_to_id // $target.id) | tostring) as $root
    | [ .[]
        | select((.id|tostring) == $root or ((.in_reply_to_id // "") | tostring) == $root)
        | (.body // "") ]
    | join("\n")'
}

# GitLab: the discussion containing <comment_id> holds every note in the
# thread; concat their bodies.
_prtend_forge_gl_review_thread_bodies() {
  local pr="${1:-}" comment_id="${2:-}" project_id discussion
  if [[ -z "$pr" || -z "$comment_id" ]]; then
    prtend_log_error "review_thread_bodies: missing pr or comment-id argument"; return 2
  fi
  project_id="$(_prtend_forge_gl_project_id)" || return $?
  discussion="$(glab api "projects/${project_id}/merge_requests/${pr}/discussions" --paginate \
    | jq -s --arg cid "$comment_id" '
        add // []
        | map(select(any(.notes[]?; (.id|tostring) == $cid)))
        | first // null')" || return $?
  if [[ -z "$discussion" || "$discussion" == "null" ]]; then
    return 1
  fi
  printf '%s' "$discussion" | jq -r '[.notes[]? | (.body // "")] | join("\n")'
}

# -- review_thread_notes ---------------------------------------------------

# Like `review_thread_bodies`, but emits per-note objects so callers can
# answer time-sensitive questions like "is there a prtend marker on a
# reply posted *after* this comment?" `note-post` doesn't need the
# timestamps (it just wants any-marker-in-thread to refuse a double-post)
# and stays on `review_thread_bodies`; `reviews-poll` uses this one to
# avoid false-positive `already_handled` flags on fresh follow-ups in
# already-replied threads (`docs/overview.md` § "Edge cases" item 11).
#
# Returns `{notes: [{id, created_at, body}, ...]}` on hit, exit 1 + empty
# if the comment id is unknown.
prtend_forge_review_thread_notes() {
  prtend_forge_dispatch review_thread_notes "$@"
}

_prtend_forge_gh_review_thread_notes() {
  local pr="${1:-}" comment_id="${2:-}" slug all
  if [[ -z "$pr" || -z "$comment_id" ]]; then
    prtend_log_error "review_thread_notes: missing pr or comment-id argument"; return 2
  fi
  slug="$(_prtend_forge_gh_repo_slug)" || return $?
  all="$(gh api "repos/${slug}/pulls/${pr}/comments" --paginate | jq -s 'add // []')" || return $?
  if [[ "$(printf '%s' "$all" | jq --arg cid "$comment_id" \
        '[.[] | select((.id|tostring) == $cid)] | length')" == "0" ]]; then
    return 1
  fi
  printf '%s' "$all" | jq -c --arg cid "$comment_id" '
    (map(select((.id|tostring) == $cid))[0]) as $target
    | (($target.in_reply_to_id // $target.id) | tostring) as $root
    | { notes: [ .[]
          | select((.id|tostring) == $root or ((.in_reply_to_id // "") | tostring) == $root)
          | { id: (.id | tostring), created_at: (.created_at // ""), body: (.body // "") }
        ] }'
}

_prtend_forge_gl_review_thread_notes() {
  local pr="${1:-}" comment_id="${2:-}" project_id discussion
  if [[ -z "$pr" || -z "$comment_id" ]]; then
    prtend_log_error "review_thread_notes: missing pr or comment-id argument"; return 2
  fi
  project_id="$(_prtend_forge_gl_project_id)" || return $?
  discussion="$(glab api "projects/${project_id}/merge_requests/${pr}/discussions" --paginate \
    | jq -s --arg cid "$comment_id" '
        add // []
        | map(select(any(.notes[]?; (.id|tostring) == $cid)))
        | first // null')" || return $?
  if [[ -z "$discussion" || "$discussion" == "null" ]]; then
    return 1
  fi
  printf '%s' "$discussion" | jq -c '
    { notes: [ .notes[]?
        | { id: (.id | tostring), created_at: (.created_at // ""), body: (.body // "") }
      ] }'
}

# -- pr_create -------------------------------------------------------------

prtend_forge_pr_create() {
  prtend_forge_dispatch pr_create "$@"
}

# Parse the trailing integer of a forge-printed URL (e.g.
# `https://github.com/owner/repo/pull/124`). Echoes the integer, exit 0 on
# success, exit 1 if no integer suffix was found.
_prtend_forge_parse_pr_from_url() {
  local url="${1:-}" tail
  tail="${url##*/}"
  # Strip surrounding whitespace / trailing CR.
  tail="${tail//$'\r'/}"
  tail="${tail%"${tail##*[![:space:]]}"}"
  if [[ "$tail" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$tail"
    return 0
  fi
  return 1
}

# Common flag parser for the create privates. Sets the global associative
# array PRTEND_FORGE_PRCREATE_ARGS with keys: title, body, draft, target.
_prtend_forge_parse_create_args() {
  PRTEND_FORGE_PRCREATE_TITLE=""
  PRTEND_FORGE_PRCREATE_BODY=""
  PRTEND_FORGE_PRCREATE_DRAFT=0
  PRTEND_FORGE_PRCREATE_TARGET=""
  while (( $# > 0 )); do
    case "$1" in
      --title)
        PRTEND_FORGE_PRCREATE_TITLE="${2:-}"; shift 2 ;;
      --body)
        PRTEND_FORGE_PRCREATE_BODY="${2:-}"; shift 2 ;;
      --draft)
        PRTEND_FORGE_PRCREATE_DRAFT=1; shift ;;
      --target-branch)
        PRTEND_FORGE_PRCREATE_TARGET="${2:-}"; shift 2 ;;
      *)
        prtend_log_error "pr_create: unknown argument '$1'"; return 2 ;;
    esac
  done
  if [[ -z "$PRTEND_FORGE_PRCREATE_TITLE" ]]; then
    prtend_log_error "pr_create: --title is required"
    return 2
  fi
}

_prtend_forge_gh_pr_create() {
  _prtend_forge_parse_create_args "$@" || return $?
  local branch out url
  branch="$(prtend_forge_current_branch)" || return $?
  local -a argv=(gh pr create --head "$branch" --title "$PRTEND_FORGE_PRCREATE_TITLE")
  argv+=(--body "$PRTEND_FORGE_PRCREATE_BODY")
  if (( PRTEND_FORGE_PRCREATE_DRAFT == 1 )); then
    argv+=(--draft)
  fi
  if [[ -n "$PRTEND_FORGE_PRCREATE_TARGET" ]]; then
    argv+=(--base "$PRTEND_FORGE_PRCREATE_TARGET")
  fi
  if ! out="$("${argv[@]}")"; then
    return 1
  fi
  # Tail line is the URL; previous lines may be warnings.
  url="$(printf '%s' "$out" | tail -n1)"
  if ! _prtend_forge_parse_pr_from_url "$url"; then
    printf '%s\n' "$out" >&2
    return 1
  fi
}

_prtend_forge_gl_pr_create() {
  _prtend_forge_parse_create_args "$@" || return $?
  local branch out url
  branch="$(prtend_forge_current_branch)" || return $?
  local -a argv=(glab mr create --source-branch "$branch" --title "$PRTEND_FORGE_PRCREATE_TITLE")
  argv+=(--description "$PRTEND_FORGE_PRCREATE_BODY")
  if (( PRTEND_FORGE_PRCREATE_DRAFT == 1 )); then
    argv+=(--draft)
  fi
  if [[ -n "$PRTEND_FORGE_PRCREATE_TARGET" ]]; then
    argv+=(--target-branch "$PRTEND_FORGE_PRCREATE_TARGET")
  fi
  if ! out="$("${argv[@]}")"; then
    return 1
  fi
  url="$(printf '%s' "$out" | tail -n1)"
  if ! _prtend_forge_parse_pr_from_url "$url"; then
    printf '%s\n' "$out" >&2
    return 1
  fi
}

# -- pr_url ----------------------------------------------------------------

prtend_forge_pr_url() {
  prtend_forge_dispatch pr_url "$@"
}

_prtend_forge_gh_pr_url() {
  local pr="${1:-}" out
  if [[ -z "$pr" ]]; then
    prtend_log_error "pr_url: missing pr argument"; return 2
  fi
  out="$(gh pr view "$pr" --json url -q .url)" || return $?
  if [[ -z "$out" ]]; then return 1; fi
  printf '%s\n' "$out"
}

_prtend_forge_gl_pr_url() {
  local pr="${1:-}" out
  if [[ -z "$pr" ]]; then
    prtend_log_error "pr_url: missing pr argument"; return 2
  fi
  out="$(glab mr view "$pr" --output json | jq -r '.web_url // empty')" || return $?
  if [[ -z "$out" ]]; then return 1; fi
  printf '%s\n' "$out"
}

# -- reviewer_add ----------------------------------------------------------

prtend_forge_reviewer_add() {
  prtend_forge_dispatch reviewer_add "$@"
}

# Exit 0 — added (or already present). Exit 1 — forge rejected (unknown user,
# no permission). Exit ≥2 — CLI/network failure; propagated.
_prtend_forge_gh_reviewer_add() {
  local pr="${1:-}" login="${2:-}" err err_file rc=0
  if [[ -z "$pr" || -z "$login" ]]; then
    prtend_log_error "reviewer_add: missing pr or login argument"; return 2
  fi
  err_file="$(mktemp)"
  gh pr edit "$pr" --add-reviewer "$login" >/dev/null 2>"$err_file" || rc=$?
  err="$(cat "$err_file")"; rm -f "$err_file"
  if (( rc == 0 )); then return 0; fi
  if [[ "$err" == *"Could not request reviewer"* \
        || "$err" == *"Could not resolve to a User"* \
        || "$err" == *"Reviewers could not be added"* ]]; then
    printf '%s\n' "$err" >&2
    return 1
  fi
  printf '%s\n' "$err" >&2
  return "$rc"
}

# Older glab versions REPLACE the reviewer set on `--reviewer`. To stay
# additive across versions we read the current list, append (skipping
# duplicates), and pass the combined list. See docs/forge-mapping.md
# § "Add reviewer".
# -- post_review_reply -----------------------------------------------------

# Post a reply to a review comment. The body is read from stdin (not argv) so
# multi-line bodies, embedded quotes, and shell metacharacters survive
# unmangled. Echoes the new reply id (as a string) on stdout.
prtend_forge_post_review_reply() {
  prtend_forge_dispatch post_review_reply "$@"
}

_prtend_forge_gh_post_review_reply() {
  local pr="${1:-}" comment_id="${2:-}" slug body out
  if [[ -z "$pr" || ! "$pr" =~ ^[0-9]+$ ]]; then
    prtend_log_error "post_review_reply: --pr must be a positive integer"; return 2
  fi
  if [[ -z "$comment_id" ]]; then
    prtend_log_error "post_review_reply: missing comment-id argument"; return 2
  fi
  body="$(cat)"
  if [[ -z "$body" ]]; then
    prtend_log_error "post_review_reply: refusing to post empty body"; return 2
  fi
  slug="$(_prtend_forge_gh_repo_slug)" || return $?
  if ! out="$(gh api -X POST "repos/${slug}/pulls/${pr}/comments/${comment_id}/replies" \
        -f "body=${body}" --jq .id)"; then
    return 1
  fi
  printf '%s\n' "$out"
}

# GitLab can only append to a *discussion*, not directly to a note. The plain
# note id surfaced by reviews-poll / review_comments isn't usable as a reply
# target; we first look up the discussion that contains it. See
# docs/forge-mapping.md § "What doesn't map cleanly" item 2.
_prtend_forge_gl_post_review_reply() {
  local pr="${1:-}" comment_id="${2:-}" project_id body discussion_id out
  if [[ -z "$pr" || ! "$pr" =~ ^[0-9]+$ ]]; then
    prtend_log_error "post_review_reply: --pr must be a positive integer"; return 2
  fi
  if [[ -z "$comment_id" ]]; then
    prtend_log_error "post_review_reply: missing comment-id argument"; return 2
  fi
  body="$(cat)"
  if [[ -z "$body" ]]; then
    prtend_log_error "post_review_reply: refusing to post empty body"; return 2
  fi
  project_id="$(_prtend_forge_gl_project_id)" || return $?
  discussion_id="$(glab api "projects/${project_id}/merge_requests/${pr}/discussions" --paginate \
    | jq -rs --arg cid "$comment_id" '
        add // []
        | [ .[] | select(any(.notes[]?; (.id | tostring) == $cid)) | .id ]
        | first // empty')" || return $?
  if [[ -z "$discussion_id" ]]; then
    printf 'post_review_reply: no discussion contains note %s on MR %s\n' \
      "$comment_id" "$pr" >&2
    return 1
  fi
  if ! out="$(glab api -X POST \
        "projects/${project_id}/merge_requests/${pr}/discussions/${discussion_id}/notes" \
        -f "body=${body}" --jq .id)"; then
    return 1
  fi
  printf '%s\n' "$out"
}

_prtend_forge_gl_reviewer_add() {
  local pr="${1:-}" login="${2:-}" mr_json existing combined err err_file rc=0
  if [[ -z "$pr" || -z "$login" ]]; then
    prtend_log_error "reviewer_add: missing pr or login argument"; return 2
  fi
  mr_json="$(glab mr view "$pr" --output json)" || return $?
  existing="$(printf '%s' "$mr_json" | jq -r '[.reviewers[]?.username] | join(",")')"
  # Already requested → idempotent success.
  if [[ ",$existing," == *",$login,"* ]]; then
    return 0
  fi
  if [[ -n "$existing" ]]; then
    combined="$existing,$login"
  else
    combined="$login"
  fi
  err_file="$(mktemp)"
  glab mr update "$pr" --reviewer "$combined" >/dev/null 2>"$err_file" || rc=$?
  err="$(cat "$err_file")"; rm -f "$err_file"
  if (( rc == 0 )); then return 0; fi
  if [[ "$err" == *"not found"* || "$err" == *"User Not Found"* || "$err" == *"404"* ]]; then
    printf '%s\n' "$err" >&2
    return 1
  fi
  printf '%s\n' "$err" >&2
  return "$rc"
}

# -- ci_failures -----------------------------------------------------------
# Canonical {failures:[{check_name,conclusion,log_url,log_excerpt,signature}]}.
# `signature` is computed by prtend-signature-lib.bash, not the forge.
# See ../docs/forge-mapping.md § "CI failures (detail)".

prtend_forge_ci_failures() {
  prtend_forge_dispatch ci_failures "$@"
}

# Build one canonical failure object on stdout. Reads the excerpt from a
# temp file so signature derivation can re-read it without re-passing the
# (potentially large) body through argv.
_prtend_forge_ci_failure_obj() {
  local check_name="$1" conclusion="$2" log_url="$3" log_path="$4" sig excerpt
  excerpt="$(cat -- "$log_path")"
  sig="$(prtend_signature_from_log "$check_name" "$log_path")"
  jq -cn \
    --arg name "$check_name" \
    --arg concl "$conclusion" \
    --arg url "$log_url" \
    --arg excerpt "$excerpt" \
    --arg sig "$sig" \
    '{check_name:$name, conclusion:$concl, log_url:$url, log_excerpt:$excerpt, signature:$sig}'
}

_prtend_forge_gh_ci_failures() {
  local pr="${1:-}" checks_json count i name link run_id log_tmp
  if [[ -z "$pr" ]]; then
    prtend_log_error "ci_failures: missing pr argument"; return 2
  fi
  # `gh pr checks --json` exits non-zero when any check failed or is still
  # pending; that's data, not an error. Capture stdout regardless of exit
  # code (same pattern as _prtend_forge_gh_ci_status) and only treat an
  # empty stdout as "nothing to report."
  local rc=0
  checks_json="$(gh pr checks "$pr" --json name,bucket,workflow,link 2>/dev/null)" || rc=$?
  if [[ -z "$checks_json" ]]; then
    if (( rc != 0 )); then
      # Distinguish "no checks reported" (valid: empty failure list) from
      # genuine API failure. gh prints "no checks reported" on stderr in
      # the former; we already swallowed stderr, so fall through to empty.
      :
    fi
    printf '{"failures":[]}\n'; return 0
  fi
  local failed
  failed="$(printf '%s' "$checks_json" | jq -c '[ .[] | select(.bucket == "fail") ]')"
  count="$(printf '%s' "$failed" | jq 'length')"
  if (( count == 0 )); then
    printf '{"failures":[]}\n'; return 0
  fi
  local -a objs=()
  for ((i=0; i<count; i++)); do
    name="$(printf '%s' "$failed" | jq -r ".[$i].name // \"\"")"
    link="$(printf '%s' "$failed" | jq -r ".[$i].link // \"\"")"
    # Run id parse from link `…/actions/runs/<run-id>/job/<job-id>`.
    run_id=""
    if [[ "$link" =~ /actions/runs/([0-9]+)(/|$) ]]; then
      run_id="${BASH_REMATCH[1]}"
    fi
    log_tmp="$(mktemp)"
    if [[ -n "$run_id" ]]; then
      gh run view "$run_id" --log-failed 2>/dev/null | tail -n 50 > "$log_tmp" || true
    fi
    objs+=( "$(_prtend_forge_ci_failure_obj "$name" "failure" "$link" "$log_tmp")" )
    rm -f -- "$log_tmp"
  done
  printf '%s\n' "${objs[@]}" | jq -cs '{failures: .}'
}

_prtend_forge_gl_ci_failures() {
  local pr="${1:-}" project_id mr_json pipeline_id jobs_json failed count i
  local job_id name web_url log_tmp
  if [[ -z "$pr" ]]; then
    prtend_log_error "ci_failures: missing pr argument"; return 2
  fi
  project_id="$(_prtend_forge_gl_project_id)" || return $?
  mr_json="$(glab mr view "$pr" --output json)" || return $?
  pipeline_id="$(printf '%s' "$mr_json" | jq -r '.head_pipeline.id // empty')"
  if [[ -z "$pipeline_id" ]]; then
    printf '{"failures":[]}\n'; return 0
  fi
  jobs_json="$(glab api "projects/${project_id}/pipelines/${pipeline_id}/jobs")" || return $?
  failed="$(printf '%s' "$jobs_json" | jq -c '[ .[] | select(.status == "failed") ]')"
  count="$(printf '%s' "$failed" | jq 'length')"
  if (( count == 0 )); then
    printf '{"failures":[]}\n'; return 0
  fi
  local -a objs=()
  for ((i=0; i<count; i++)); do
    job_id="$(printf '%s' "$failed" | jq -r ".[$i].id")"
    name="$(printf '%s' "$failed" | jq -r ".[$i].name // \"\"")"
    web_url="$(printf '%s' "$failed" | jq -r ".[$i].web_url // \"\"")"
    log_tmp="$(mktemp)"
    # `glab api .../trace` returns plain text; `glab ci trace` may be
    # interactive in tty contexts, so prefer the API endpoint.
    glab api "projects/${project_id}/jobs/${job_id}/trace" 2>/dev/null | tail -n 50 > "$log_tmp" || true
    objs+=( "$(_prtend_forge_ci_failure_obj "$name" "failure" "$web_url" "$log_tmp")" )
    rm -f -- "$log_tmp"
  done
  printf '%s\n' "${objs[@]}" | jq -cs '{failures: .}'
}

# -- ci_watch_block --------------------------------------------------------
# Block until prtend_forge_ci_status reports a `.state` different from
# <last_state>, or the PR closes. Honors $PRTEND_POLL_INTERVAL (default 15s).
# Echoes the new ci_status JSON; exit 4 if the PR closes mid-watch.

prtend_forge_ci_watch_block() {
  prtend_forge_dispatch ci_watch_block "$@"
}

_prtend_forge_ci_watch_block_common() {
  # Forge-agnostic poll loop. Used by both gh and gl privates; keeps the two
  # symmetric and lets the test harness drive every iteration via mocks.
  # Optional <max_seconds> bounds the wait; on expiry returns 124 (mirrors
  # the coreutils `timeout` convention) so the subcommand can map that to a
  # clean exit-0-no-output per the cli-contract.
  local pr="${1:-}" last_state="${2:-}" max_seconds="${3:-}"
  local status state pr_state_json pr_state interval start now elapsed
  if [[ -z "$pr" || -z "$last_state" ]]; then
    prtend_log_error "ci_watch_block: missing pr or last_state"; return 2
  fi
  interval="${PRTEND_POLL_INTERVAL:-15}"
  start="${SECONDS}"
  while :; do
    status="$(prtend_forge_ci_status "$pr")" || return $?
    state="$(printf '%s' "$status" | jq -r '.state // ""')"
    if [[ -n "$state" && "$state" != "$last_state" ]]; then
      printf '%s\n' "$status"
      return 0
    fi
    pr_state_json="$(prtend_forge_pr_state "$pr")" || return $?
    pr_state="$(printf '%s' "$pr_state_json" | jq -r '.state // ""')"
    if [[ "$pr_state" == "closed" || "$pr_state" == "merged" ]]; then
      return 4
    fi
    local nap="$interval"
    if [[ -n "$max_seconds" ]]; then
      now="${SECONDS}"
      elapsed=$(( now - start ))
      if (( elapsed >= max_seconds )); then
        return 124
      fi
      # Cap the sleep to the remaining wall-clock budget so a short
      # --timeout actually returns near its requested bound instead of
      # waiting out a full poll interval.
      local remaining=$(( max_seconds - elapsed ))
      if (( remaining < nap )); then
        nap="$remaining"
      fi
    fi
    sleep "$nap"
  done
}

_prtend_forge_gh_ci_watch_block() {
  _prtend_forge_ci_watch_block_common "$@"
}

_prtend_forge_gl_ci_watch_block() {
  _prtend_forge_ci_watch_block_common "$@"
}
