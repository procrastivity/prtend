#!/usr/bin/env bash
# test-prtend.sh — plain-bash harness covering prtend subcommands.
# Each test runs in a fresh subshell against a freshly-initialised git repo,
# with the forge-lib's _gh/_gl primitives overridden so no real network is hit.
#
# Subshell isolation is intentional (SC2030/SC2031) so overrides don't leak;
# stub fns are called indirectly via prtend_forge_dispatch (SC2329).
# shellcheck disable=SC2030,SC2031,SC2329

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_ROOT/test/fixtures/detect"

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

# Build a fresh sandbox repo and source the libs into the current shell so we
# can shadow the forge primitives via function redefinition. Returns via
# global $SANDBOX (the repo dir) — caller cd's into it.
new_sandbox() {
  SANDBOX="$(mktemp -d -t prtend-test.XXXXXX)"
  (
    cd "$SANDBOX"
    git init -q
    git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
    git remote add origin https://github.com/example/repo.git
    git checkout -q -b feature/x
  )
}

# Source the libs into THIS shell so we can monkey-patch primitives, then
# invoke prtend_cmd_detect directly. Cheaper than spawning bin/prtend and
# lets us stub the dispatch primitives.
load_libs() {
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-forge-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-subcommands/detect.bash"
  # Libs enable `set -e`; the harness uses explicit rc capture instead so
  # we can assert on non-zero exits without aborting the test.
  set +e
}

# --------------------------------------------------------------------------
# Case 1 — happy path: open PR, feature branch.
# --------------------------------------------------------------------------
case_happy_path() {
  echo "case: happy path"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    export PRTEND_FORGE=github
    _prtend_forge_gh_pr_for_branch() { printf '123\n'; }
    _prtend_forge_gh_pr_state()      { cat "$FIXTURES/pr_state.open.json"; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    out="$(prtend_cmd_detect)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "forge"     '"github"' "$(jq -c .forge <<<"$out")"
    assert_eq "branch"    '"feature/x"' "$(jq -c .branch <<<"$out")"
    assert_eq "pr"        '123' "$(jq -c .pr <<<"$out")"
    assert_eq "pr_state"  '"open"' "$(jq -c .pr_state <<<"$out")"
    assert_eq "is_default_branch" 'false' "$(jq -c .is_default_branch <<<"$out")"
    assert_eq "remote"    '"origin"' "$(jq -c .remote <<<"$out")"
  )
}

# --------------------------------------------------------------------------
# Case 2 — no PR for branch.
# --------------------------------------------------------------------------
case_no_pr() {
  echo "case: no PR"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    export PRTEND_FORGE=github
    _prtend_forge_gh_pr_for_branch() { return 1; }
    _prtend_forge_gh_pr_state()      { echo "must not be called" >&2; return 99; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    out="$(prtend_cmd_detect)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "pr"        'null' "$(jq -c .pr <<<"$out")"
    assert_eq "pr_state"  'null' "$(jq -c .pr_state <<<"$out")"
  )
}

# --------------------------------------------------------------------------
# Case 3 — default branch.
# --------------------------------------------------------------------------
case_default_branch() {
  echo "case: default branch"
  (
    new_sandbox
    cd "$SANDBOX"
    git checkout -q -b main 2>/dev/null || git checkout -q main
    load_libs
    export PRTEND_FORGE=github
    _prtend_forge_gh_pr_for_branch() { return 1; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    out="$(prtend_cmd_detect --branch main)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "is_default_branch" 'true' "$(jq -c .is_default_branch <<<"$out")"
  )
}

# --------------------------------------------------------------------------
# Case 4 — ambiguous PR (multiple open).
# --------------------------------------------------------------------------
case_ambiguous() {
  echo "case: ambiguous PR"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    export PRTEND_FORGE=github
    _prtend_forge_gh_pr_for_branch() { return 2; }
    _prtend_forge_gh_default_branch(){ printf 'main\n'; }
    prtend_cmd_detect >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 4 "$rc"
  )
}

# --------------------------------------------------------------------------
# Case 5 — no forge (PRTEND_FORGE invalid → detect maps).
# Emulate "couldn't detect" by removing gh/glab from PATH and unsetting forge.
# --------------------------------------------------------------------------
case_no_forge() {
  echo "case: no forge"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    unset PRTEND_FORGE
    # Simulate "no forge detected" without depending on $PATH manipulation.
    prtend_forge_detect() { return 1; }
    out="$(prtend_cmd_detect)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "forge"    'null' "$(jq -c .forge <<<"$out")"
    assert_eq "pr"       'null' "$(jq -c .pr <<<"$out")"
    assert_eq "pr_state" 'null' "$(jq -c .pr_state <<<"$out")"
  )
}

# --------------------------------------------------------------------------
# Case 6 — not a git repo.
# --------------------------------------------------------------------------
case_not_a_repo() {
  echo "case: not a git repo"
  (
    tmp="$(mktemp -d)"
    cd "$tmp"
    load_libs
    err="$(prtend_cmd_detect 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 1 "$rc"
    assert_contains "stderr message" "not in a git repository" "$err"
  )
}

# --------------------------------------------------------------------------
# Case 7 — bad flag.
# --------------------------------------------------------------------------
case_bad_flag() {
  echo "case: bad --branch flag"
  (
    new_sandbox
    cd "$SANDBOX"
    load_libs
    prtend_cmd_detect --branch >/dev/null 2>&1
    rc=$?
    assert_eq "exit code" 2 "$rc"
    prtend_cmd_detect --branch --no-cache >/dev/null 2>&1
    rc=$?
    assert_eq "rejects --branch swallowing next flag" 2 "$rc"
  )
}

case_happy_path
case_no_pr
case_default_branch
case_ambiguous
case_no_forge
case_not_a_repo
case_bad_flag

PASS="$(grep -c '^P' "$RESULTS" || true)"
FAIL="$(grep -c '^F' "$RESULTS" || true)"
echo
echo "passed: ${PASS:-0}    failed: ${FAIL:-0}"
if (( FAIL > 0 )); then exit 1; fi
