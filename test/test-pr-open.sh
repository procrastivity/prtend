#!/usr/bin/env bash
# test-pr-open.sh — covers prtend pr-open. Mirrors the harness style from
# test-prtend.sh (detect): subshell isolation, forge primitives shadowed via
# function override, no real network.
#
# shellcheck disable=SC2030,SC2031,SC2329

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_ROOT/test/fixtures/pr_open"

RESULTS="$(mktemp -t prtend-results.XXXXXX)"
export RESULTS
trap 'rm -f "$RESULTS"' EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'P\n' >>"$RESULTS"
    printf '  ok    %s\n' "$label"
  else
    printf 'F\n' >>"$RESULTS"
    printf '  FAIL  %s\n        expected: %q\n        actual:   %q\n' "$label" "$expected" "$actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'P\n' >>"$RESULTS"
    printf '  ok    %s\n' "$label"
  else
    printf 'F\n' >>"$RESULTS"
    printf '  FAIL  %s\n        needle:   %q\n        haystack: %q\n' "$label" "$needle" "$haystack"
  fi
}

new_sandbox() {
  SANDBOX="$(mktemp -d -t prtend-test.XXXXXX)"
  (
    cd "$SANDBOX"
    git init -q
    git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
    # Create a bare repo to act as the "remote" so ls-remote/fetch can work.
    REMOTE="$SANDBOX.remote"
    git init -q --bare "$REMOTE"
    git remote add origin "$REMOTE"
    git checkout -q -b feature/x
    git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m work
  )
}

load_libs() {
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-forge-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-subcommands/pr_open.bash"
  set +e
  # Stable forge selection so dispatch goes through the _gh_* privates.
  export PRTEND_FORGE=github
  # Mark the CLI as ready by default.
  _prtend_forge_gh_cli_ready() { return 0; }
  # No system reviewers from config by default.
  unset PRTEND_SYSTEM_REVIEWERS
}

# Track pushes so tests can assert on what was issued.
install_git_push_recorder() {
  PUSH_LOG="$(mktemp)"
  export PUSH_LOG
  # Wrap `git push` by intercepting via a shell function. Because real
  # subcommand code calls `git push ...`, define a `git()` function that
  # short-circuits push and delegates everything else.
  git() {
    if [[ "${1:-}" == "push" ]]; then
      shift
      printf '%s\n' "$*" >>"$PUSH_LOG"
      return 0
    fi
    command git "$@"
  }
  export -f git 2>/dev/null || true
}

# --------------------------------------------------------------------------
# Case 1 — happy path: no PR, branch not on remote → push + create.
# --------------------------------------------------------------------------
case_happy_path() {
  echo "case: happy path (created)"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    install_git_push_recorder
    _prtend_forge_gh_pr_for_branch() { return 1; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    _prtend_forge_gh_pr_create()     { printf '124\n'; }
    _prtend_forge_gh_pr_url()        { printf 'https://github.com/owner/repo/pull/124\n'; }
    _prtend_forge_gh_pr_state()      { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_reviewer_add()  { return 0; }

    out="$(prtend_cmd_pr_open --title "Sandbox PR" --optional-reviewer alice 2>/dev/null)"
    rc=$?
    assert_eq "exit code"      0 "$rc"
    assert_eq "pr"             '124' "$(jq -c .pr <<<"$out")"
    assert_eq "action"         '"created"' "$(jq -c .action <<<"$out")"
    assert_eq "url"            '"https://github.com/owner/repo/pull/124"' "$(jq -c .url <<<"$out")"
    assert_eq "state"          '"open"' "$(jq -c .state <<<"$out")"
    assert_eq "requested"      '["alice"]' "$(jq -c .reviewers_requested <<<"$out")"
    assert_eq "skipped"        '[]' "$(jq -c .reviewers_skipped <<<"$out")"
    push_cmd="$(cat "$PUSH_LOG" 2>/dev/null || true)"
    assert_contains "push uses --set-upstream" "--set-upstream" "$push_cmd"
  )
}

# --------------------------------------------------------------------------
# Case 2 — branch on remote, no PR → create_existing_branch, no push.
# --------------------------------------------------------------------------
case_created_existing_branch() {
  echo "case: created_existing_branch (branch already on remote)"
  (
    new_sandbox
    cd "$SANDBOX"
    # Mirror feature/x to the bare remote so ls-remote finds it.
    ( cd "$SANDBOX" && command git push -q origin feature/x )
    load_libs
    install_git_push_recorder
    _prtend_forge_gh_pr_for_branch() { return 1; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    _prtend_forge_gh_pr_create()     { printf '125\n'; }
    _prtend_forge_gh_pr_url()        { printf 'https://github.com/owner/repo/pull/125\n'; }
    _prtend_forge_gh_pr_state()      { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_reviewer_add()  { return 0; }

    out="$(prtend_cmd_pr_open --title "Sandbox PR" 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "action"    '"created_existing_branch"' "$(jq -c .action <<<"$out")"
    push_cmd="$(cat "$PUSH_LOG" 2>/dev/null || true)"
    assert_eq "no push issued" "" "$push_cmd"
  )
}

# --------------------------------------------------------------------------
# Case 3 — open PR exists, local matches remote → used_existing.
# --------------------------------------------------------------------------
case_used_existing() {
  echo "case: used_existing"
  (
    new_sandbox
    cd "$SANDBOX"
    ( cd "$SANDBOX" && command git push -q origin feature/x )
    load_libs
    install_git_push_recorder
    _prtend_forge_gh_pr_for_branch() { printf '200\n'; }
    _prtend_forge_gh_pr_state()      { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    _prtend_forge_gh_pr_url()        { printf 'https://github.com/owner/repo/pull/200\n'; }
    _prtend_forge_gh_reviewer_add()  { return 0; }

    out="$(prtend_cmd_pr_open --title "Sandbox PR" 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "action"    '"used_existing"' "$(jq -c .action <<<"$out")"
    assert_eq "pr"        '200' "$(jq -c .pr <<<"$out")"
    push_cmd="$(cat "$PUSH_LOG" 2>/dev/null || true)"
    assert_eq "no push issued" "" "$push_cmd"
  )
}

# --------------------------------------------------------------------------
# Case 4 — open PR exists, local ahead of remote → pushed_existing_pr.
# --------------------------------------------------------------------------
case_pushed_existing_pr() {
  echo "case: pushed_existing_pr"
  (
    new_sandbox
    cd "$SANDBOX"
    ( cd "$SANDBOX" && command git push -q origin feature/x )
    # Add a new local commit so HEAD is ahead of origin/feature/x.
    ( cd "$SANDBOX" && command git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m more )
    load_libs
    install_git_push_recorder
    _prtend_forge_gh_pr_for_branch() { printf '201\n'; }
    _prtend_forge_gh_pr_state()      { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    _prtend_forge_gh_pr_url()        { printf 'https://github.com/owner/repo/pull/201\n'; }
    _prtend_forge_gh_reviewer_add()  { return 0; }

    out="$(prtend_cmd_pr_open --title "Sandbox PR" 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "action"    '"pushed_existing_pr"' "$(jq -c .action <<<"$out")"
    push_cmd="$(cat "$PUSH_LOG" 2>/dev/null || true)"
    assert_contains "push issued" "origin feature/x" "$push_cmd"
    if [[ "$push_cmd" == *"--set-upstream"* ]]; then
      printf 'F\n' >>"$RESULTS"; printf '  FAIL  push must not use --set-upstream on existing branch\n'
    else
      printf 'P\n' >>"$RESULTS"; printf '  ok    push does not use --set-upstream\n'
    fi
  )
}

# --------------------------------------------------------------------------
# Case 5 — closed PR exists → exit 4.
# --------------------------------------------------------------------------
case_closed_pr() {
  echo "case: closed PR refusal"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    install_git_push_recorder
    _prtend_forge_gh_pr_for_branch() { printf '300\n'; }
    _prtend_forge_gh_pr_state()      { cat "$FIXTURES/pr_state.closed.json"; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    err="$(prtend_cmd_pr_open --title "x" 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 4 "$rc"
    assert_contains "stderr message" "closed/merged PR" "$err"
    push_cmd="$(cat "$PUSH_LOG" 2>/dev/null || true)"
    assert_eq "no push issued" "" "$push_cmd"
  )
}

# --------------------------------------------------------------------------
# Case 6 — merged PR exists → exit 4.
# --------------------------------------------------------------------------
case_merged_pr() {
  echo "case: merged PR refusal"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    _prtend_forge_gh_pr_for_branch() { printf '301\n'; }
    _prtend_forge_gh_pr_state()      { cat "$FIXTURES/pr_state.merged.json"; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    prtend_cmd_pr_open --title "x" >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 4 "$rc"
  )
}

# --------------------------------------------------------------------------
# Case 7 — ambiguous (multiple open) → exit 4.
# --------------------------------------------------------------------------
case_ambiguous() {
  echo "case: ambiguous PR"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    _prtend_forge_gh_pr_for_branch() { return 2; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    err="$(prtend_cmd_pr_open --title "x" 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 4 "$rc"
    assert_contains "stderr message" "multiple open PRs" "$err"
  )
}

# --------------------------------------------------------------------------
# Case 8 — on default branch → exit 2.
# --------------------------------------------------------------------------
case_default_branch() {
  echo "case: default branch refusal"
  (
    new_sandbox
    cd "$SANDBOX"
    # Switch to main.
    command git checkout -q -b main 2>/dev/null || command git checkout -q main
    load_libs
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    err="$(prtend_cmd_pr_open --title "x" 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 2 "$rc"
    assert_contains "stderr message" "default branch" "$err"
  )
}

# --------------------------------------------------------------------------
# Case 9 — forge CLI not installed → exit 3.
# --------------------------------------------------------------------------
case_not_authed() {
  echo "case: forge CLI not ready"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    _prtend_forge_gh_cli_ready() { return 3; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    prtend_cmd_pr_open --title "x" >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 3 "$rc"
  )
}

# --------------------------------------------------------------------------
# Case 10 — reviewer rejected → entry in reviewers_skipped, still exit 0.
# --------------------------------------------------------------------------
case_reviewer_rejected() {
  echo "case: reviewer rejected"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    install_git_push_recorder
    _prtend_forge_gh_pr_for_branch() { return 1; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    _prtend_forge_gh_pr_create()     { printf '400\n'; }
    _prtend_forge_gh_pr_url()        { printf 'https://github.com/owner/repo/pull/400\n'; }
    _prtend_forge_gh_pr_state()      { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_reviewer_add()  {
      if [[ "${2:-}" == "badname" ]]; then return 1; fi
      return 0
    }
    out="$(prtend_cmd_pr_open --title "x" --optional-reviewer alice --optional-reviewer badname 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "requested" '["alice"]'   "$(jq -c .reviewers_requested <<<"$out")"
    assert_eq "skipped"   '["badname"]' "$(jq -c .reviewers_skipped <<<"$out")"
  )
}

# --------------------------------------------------------------------------
# Case 11 — --draft sets state to draft on emitted JSON.
# --------------------------------------------------------------------------
case_draft() {
  echo "case: --draft"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    install_git_push_recorder
    _prtend_forge_gh_pr_for_branch() { return 1; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    _prtend_forge_gh_pr_create()     { printf '500\n'; }
    _prtend_forge_gh_pr_url()        { printf 'https://github.com/owner/repo/pull/500\n'; }
    _prtend_forge_gh_pr_state()      { cat "$FIXTURES/pr_state.draft.json"; }
    _prtend_forge_gh_reviewer_add()  { return 0; }
    out="$(prtend_cmd_pr_open --title "x" --draft 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "state" '"draft"' "$(jq -c .state <<<"$out")"
  )
}

# --------------------------------------------------------------------------
# Case 12 — diverged → exit 1.
# --------------------------------------------------------------------------
case_diverged() {
  echo "case: diverged branch refusal"
  (
    new_sandbox
    cd "$SANDBOX"
    # Push, then rewrite local history so HEAD is no longer a descendant.
    ( cd "$SANDBOX" && command git push -q origin feature/x )
    ( cd "$SANDBOX" && command git reset -q --hard HEAD~1 )
    ( cd "$SANDBOX" && command git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m diverged )
    load_libs
    install_git_push_recorder
    _prtend_forge_gh_pr_for_branch() { return 1; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    err="$(prtend_cmd_pr_open --title "x" 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 1 "$rc"
    assert_contains "stderr message" "diverges" "$err"
  )
}

# --------------------------------------------------------------------------
# Case 13 — missing --title.
# --------------------------------------------------------------------------
case_missing_title() {
  echo "case: missing --title"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    prtend_cmd_pr_open >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 2 "$rc"
  )
}

# --------------------------------------------------------------------------
# Case 14 — multiple --optional-reviewer end up in order.
# --------------------------------------------------------------------------
case_multiple_optional_reviewers() {
  echo "case: multiple optional reviewers preserve order"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    install_git_push_recorder
    _prtend_forge_gh_pr_for_branch() { return 1; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    _prtend_forge_gh_pr_create()     { printf '600\n'; }
    _prtend_forge_gh_pr_url()        { printf 'https://github.com/owner/repo/pull/600\n'; }
    _prtend_forge_gh_pr_state()      { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_reviewer_add()  { return 0; }
    out="$(prtend_cmd_pr_open --title "x" \
      --optional-reviewer alice --optional-reviewer bob --optional-reviewer carol 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "requested order" '["alice","bob","carol"]' "$(jq -c .reviewers_requested <<<"$out")"
  )
}

# --------------------------------------------------------------------------
# Case 15 — system reviewers from config (via PRTEND_SYSTEM_REVIEWERS env).
# --------------------------------------------------------------------------
case_system_reviewers_env() {
  echo "case: system reviewers from env override"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    install_git_push_recorder
    export PRTEND_SYSTEM_REVIEWERS="copilot,duo"
    _prtend_forge_gh_pr_for_branch() { return 1; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    _prtend_forge_gh_pr_create()     { printf '700\n'; }
    _prtend_forge_gh_pr_url()        { printf 'https://github.com/owner/repo/pull/700\n'; }
    _prtend_forge_gh_pr_state()      { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_reviewer_add()  { return 0; }
    out="$(prtend_cmd_pr_open --title "x" --optional-reviewer alice 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "system + optional in order" \
      '["copilot","duo","alice"]' "$(jq -c .reviewers_requested <<<"$out")"
  )
}

# --------------------------------------------------------------------------
# Case 16 — system reviewers from block-style YAML config file.
# --------------------------------------------------------------------------
case_system_reviewers_config_file() {
  echo "case: system reviewers from YAML config file"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    install_git_push_recorder
    export PRTEND_CONFIG="$FIXTURES/config_with_system_reviewers.yml"
    _prtend_forge_gh_pr_for_branch() { return 1; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    _prtend_forge_gh_pr_create()     { printf '701\n'; }
    _prtend_forge_gh_pr_url()        { printf 'https://github.com/owner/repo/pull/701\n'; }
    _prtend_forge_gh_pr_state()      { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_reviewer_add()  { return 0; }
    out="$(prtend_cmd_pr_open --title "x" 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "system reviewers from yaml" \
      '["copilot","duo"]' "$(jq -c .reviewers_requested <<<"$out")"
  )
}

case_happy_path
case_created_existing_branch
case_used_existing
case_pushed_existing_pr
case_closed_pr
case_merged_pr
case_ambiguous
case_default_branch
case_not_authed
case_reviewer_rejected
case_draft
case_diverged
case_missing_title
case_multiple_optional_reviewers
case_system_reviewers_env
case_system_reviewers_config_file

PASS="$(grep -c '^P' "$RESULTS" || true)"
FAIL="$(grep -c '^F' "$RESULTS" || true)"
echo
echo "passed: ${PASS:-0}    failed: ${FAIL:-0}"
if (( FAIL > 0 )); then exit 1; fi
