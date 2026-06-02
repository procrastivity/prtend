#!/usr/bin/env bash
# test-doctor.sh — covers prtend doctor. Per-test subshell isolation. A fake
# `gh` binary is dropped into the sandbox's bin dir and prepended to PATH so
# the production check functions (which exec `gh --version` / `gh auth status`
# directly) see deterministic output. Per-test overrides shadow
# _prtend_forge_gh_pr_state and prtend_config_resolve as needed.
#
# shellcheck disable=SC2030,SC2031,SC2329

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_ROOT/test/fixtures/doctor"

RESULTS="$(mktemp -t prtend-doctor-results.XXXXXX)"
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
  SANDBOX="$(mktemp -d -t prtend-doctor.XXXXXX)"
  mkdir -p "$SANDBOX/bin"
  (
    cd "$SANDBOX" || exit
    git init -q
    git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
    git remote add origin "https://github.com/o/test-${RANDOM}.git"
  )
  export XDG_STATE_HOME="$SANDBOX/state"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export PATH="$SANDBOX/bin:$PATH"
  unset PRTEND_FORGE
}

# install a fake `gh` whose behavior is parameterized by env vars set per-test.
# auth_format: "as" (default, older gh) or "account" (newer multi-account gh).
install_fake_gh() {
  local version="${1:-2.62.0}"
  local authed="${2:-1}"
  local login="${3:-procrastivity}"
  local auth_format="${4:-as}"
  cat >"$SANDBOX/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version)
    printf 'gh version $version (2026-01-01)\n'
    printf 'https://github.com/cli/cli/releases/tag/v$version\n'
    ;;
  auth)
    if [[ "$authed" == "1" ]]; then
      printf 'github.com\n  ✓ Logged in to github.com $auth_format $login\n' >&2
      exit 0
    else
      printf 'You are not logged into any GitHub hosts.\n' >&2
      exit 1
    fi
    ;;
  repo)
    # Used by prtend_forge_detect's gh-probe. Stay quiet, succeed.
    printf '{"url":"https://github.com/o/r"}\n'
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$SANDBOX/bin/gh"
}

load_libs() {
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-forge-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-state-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-notes-lib.bash"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/prtend/prtend-subcommands/doctor.bash"
  set +e
  export PRTEND_FORGE=github
}

# ----------------------------------------------------------------------------
# Case 1 — All checks pass.
# ----------------------------------------------------------------------------
case_all_pass() {
  echo "case: all checks pass"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    install_fake_gh 2.62.0 1 alice
    load_libs
    # Use the in-repo config slot so resolve picks up a well-formed file.
    mkdir -p "$SANDBOX/.claude"
    cp "$FIXTURES/config.well_formed.yml" "$SANDBOX/.claude/pr-reviewers.yml"
    # Make pr-state return nothing meaningful — but no state files exist so
    # stale_subscriptions short-circuits to "No state files yet" / "No stale".
    _prtend_forge_gh_pr_state() { printf '{"state":"open"}\n'; }
    out="$(prtend_cmd_doctor 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "checks length" 7 "$(jq '.checks | length' <<<"$out")"
    assert_eq "summary.pass" 7 "$(jq '.summary.pass' <<<"$out")"
    assert_eq "summary.warn" 0 "$(jq '.summary.warn' <<<"$out")"
    assert_eq "summary.fail" 0 "$(jq '.summary.fail' <<<"$out")"
    assert_eq "fixed empty" 0 "$(jq '.fixed | length' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 2 — Forge CLI missing.
# ----------------------------------------------------------------------------
case_forge_missing() {
  echo "case: forge CLI missing"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    # Deliberately don't install fake gh.
    load_libs
    # Force resolve_forge to fail.
    _doctor_resolve_forge() { return 1; }
    out="$(prtend_cmd_doctor 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 1 "$rc"
    assert_eq "installed status" '"fail"' \
      "$(jq -c '.checks[] | select(.name=="forge_cli_installed") | .status' <<<"$out")"
    assert_eq "authed status" '"warn"' \
      "$(jq -c '.checks[] | select(.name=="forge_cli_authed") | .status' <<<"$out")"
    assert_eq "version status" '"warn"' \
      "$(jq -c '.checks[] | select(.name=="forge_cli_version") | .status' <<<"$out")"
    assert_eq "stale status" '"warn"' \
      "$(jq -c '.checks[] | select(.name=="stale_subscriptions") | .status' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 3 — Forge CLI installed but unauthed.
# ----------------------------------------------------------------------------
case_forge_unauthed() {
  echo "case: forge CLI unauthed"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    install_fake_gh 2.62.0 0 ""
    load_libs
    out="$(prtend_cmd_doctor 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 1 "$rc"
    assert_eq "installed status" '"pass"' \
      "$(jq -c '.checks[] | select(.name=="forge_cli_installed") | .status' <<<"$out")"
    assert_eq "authed status" '"fail"' \
      "$(jq -c '.checks[] | select(.name=="forge_cli_authed") | .status' <<<"$out")"
    assert_eq "version status" '"pass"' \
      "$(jq -c '.checks[] | select(.name=="forge_cli_version") | .status' <<<"$out")"
    assert_eq "stale skipped" '"warn"' \
      "$(jq -c '.checks[] | select(.name=="stale_subscriptions") | .status' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 4 — Forge CLI below minimum version.
# ----------------------------------------------------------------------------
case_forge_old_version() {
  echo "case: forge CLI below minimum"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    install_fake_gh 1.50.0 1 alice
    load_libs
    out="$(prtend_cmd_doctor 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 1 "$rc"
    assert_eq "version status" '"fail"' \
      "$(jq -c '.checks[] | select(.name=="forge_cli_version") | .status' <<<"$out")"
    assert_contains "version message" "below minimum" \
      "$(jq -r '.checks[] | select(.name=="forge_cli_version") | .message' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 5 — Pre-release at the floor counts as meeting the floor.
# ----------------------------------------------------------------------------
case_forge_prerelease_at_floor() {
  echo "case: pre-release version at floor"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    install_fake_gh 2.62.0-rc.1 1 alice
    load_libs
    out="$(prtend_cmd_doctor --check forge_cli_version 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "version status" '"pass"' \
      "$(jq -c '.checks[0].status' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 6 — Config missing entirely.
# ----------------------------------------------------------------------------
case_config_missing() {
  echo "case: config missing"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    install_fake_gh 2.62.0 1 alice
    load_libs
    # No config file anywhere — both PRTEND_CONFIG and XDG dir empty.
    unset PRTEND_CONFIG
    out="$(prtend_cmd_doctor --check config_readable 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "status" '"warn"' "$(jq -c '.checks[0].status' <<<"$out")"
    assert_contains "message" "no config file found" "$(jq -r '.checks[0].message' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 7 — Config malformed (structural scan catches it).
# ----------------------------------------------------------------------------
case_config_malformed() {
  echo "case: config malformed"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    install_fake_gh 2.62.0 1 alice
    load_libs
    export PRTEND_CONFIG="$SANDBOX/broken.yml"
    cp "$FIXTURES/config.malformed.txt" "$PRTEND_CONFIG"
    out="$(prtend_cmd_doctor --check config_readable 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 1 "$rc"
    assert_eq "status" '"fail"' "$(jq -c '.checks[0].status' <<<"$out")"
    assert_contains "message" "malformed line" "$(jq -r '.checks[0].message' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 8 — State dir not writable.
# ----------------------------------------------------------------------------
case_state_dir_unwritable() {
  echo "case: state dir unwritable"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    install_fake_gh 2.62.0 1 alice
    load_libs
    # Override prtend_state_dir to point at a path whose parent is a regular
    # file, not a directory — mkdir -p cannot create children there regardless
    # of UID (root included). UID-independent failure trigger so the test
    # passes in CI containers running as root.
    : >"$SANDBOX/blocker"
    prtend_state_dir() { printf '%s/blocker/state-dir\n' "$SANDBOX"; }
    out="$(prtend_cmd_doctor --check state_dir_writable 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 1 "$rc"
    assert_eq "status" '"fail"' "$(jq -c '.checks[0].status' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 9 — Stale subscriptions: none stale.
# ----------------------------------------------------------------------------
case_stale_none() {
  echo "case: stale none"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    install_fake_gh 2.62.0 1 alice
    load_libs
    _prtend_forge_gh_pr_state() { cat "$FIXTURES/pr_state.open.json"; }
    # Seed two open state files.
    prtend_state_set_cursor 100 ""
    prtend_state_set_cursor 101 ""
    out="$(prtend_cmd_doctor --check stale_subscriptions 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "status" '"pass"' "$(jq -c '.checks[0].status' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 10 — Stale subscriptions: two stale, no --fix. PR with transient error
#           must NOT be classified as stale.
# ----------------------------------------------------------------------------
case_stale_two_no_fix() {
  echo "case: stale two, no --fix"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    install_fake_gh 2.62.0 1 alice
    load_libs
    _prtend_forge_gh_pr_state() {
      case "$1" in
        100) cat "$FIXTURES/pr_state.open.json" ;;
        101) cat "$FIXTURES/pr_state.closed.json" ;;
        102) cat "$FIXTURES/pr_state.merged.json" ;;
        103) return 1 ;; # transient error → must NOT be treated as stale
        *) return 1 ;;
      esac
    }
    prtend_state_set_cursor 100 ""
    prtend_state_set_cursor 101 ""
    prtend_state_set_cursor 102 ""
    prtend_state_set_cursor 103 ""
    out="$(prtend_cmd_doctor --check stale_subscriptions 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "status" '"warn"' "$(jq -c '.checks[0].status' <<<"$out")"
    assert_eq "fixable" 'true' "$(jq -c '.checks[0].fixable' <<<"$out")"
    msg="$(jq -r '.checks[0].message' <<<"$out")"
    assert_contains "two stale" "2 state files" "$msg"
    assert_contains "lists 101" "#101" "$msg"
    assert_contains "lists 102" "#102" "$msg"
    if [[ "$msg" == *"#103"* ]]; then
      assert_eq "PR 103 not in list" "absent" "present"
    else
      assert_eq "PR 103 not in list" "absent" "absent"
    fi
    # All four files still on disk.
    state_dir="$(prtend_state_dir)"
    for pr in 100 101 102 103; do
      if [[ -f "$state_dir/$pr.json" ]]; then
        assert_eq "file $pr present" "present" "present"
      else
        assert_eq "file $pr present" "present" "absent"
      fi
    done
  )
}

# ----------------------------------------------------------------------------
# Case 11 — Stale subscriptions: two stale, --fix removes them.
# ----------------------------------------------------------------------------
case_stale_two_fix() {
  echo "case: stale two, --fix"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    install_fake_gh 2.62.0 1 alice
    load_libs
    _prtend_forge_gh_pr_state() {
      case "$1" in
        100) cat "$FIXTURES/pr_state.open.json" ;;
        101) cat "$FIXTURES/pr_state.closed.json" ;;
        102) cat "$FIXTURES/pr_state.merged.json" ;;
        103) return 1 ;;
        *) return 1 ;;
      esac
    }
    prtend_state_set_cursor 100 ""
    prtend_state_set_cursor 101 ""
    prtend_state_set_cursor 102 ""
    prtend_state_set_cursor 103 ""
    out="$(prtend_cmd_doctor --check stale_subscriptions --fix 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "status post-fix" '"pass"' "$(jq -c '.checks[0].status' <<<"$out")"
    assert_eq "fixed length" 1 "$(jq '.fixed | length' <<<"$out")"
    assert_eq "fixed.check" '"stale_subscriptions"' "$(jq -c '.fixed[0].check' <<<"$out")"
    assert_eq "fixed.action" '"removed"' "$(jq -c '.fixed[0].action' <<<"$out")"
    assert_eq "fixed.details count" 2 "$(jq '.fixed[0].details | length' <<<"$out")"
    state_dir="$(prtend_state_dir)"
    for pr in 101 102; do
      if [[ -e "$state_dir/$pr.json" ]]; then
        assert_eq "file $pr removed" "absent" "present"
      else
        assert_eq "file $pr removed" "absent" "absent"
      fi
    done
    for pr in 100 103; do
      if [[ -e "$state_dir/$pr.json" ]]; then
        assert_eq "file $pr preserved" "present" "present"
      else
        assert_eq "file $pr preserved" "present" "absent"
      fi
    done
  )
}

# ----------------------------------------------------------------------------
# Case 12 — Stale subscriptions: --fix can't actually remove (rm fails).
# ----------------------------------------------------------------------------
case_stale_fix_failure() {
  echo "case: stale --fix partial failure"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    install_fake_gh 2.62.0 1 alice
    load_libs
    _prtend_forge_gh_pr_state() {
      case "$1" in
        101) cat "$FIXTURES/pr_state.closed.json" ;;
        102) cat "$FIXTURES/pr_state.merged.json" ;;
        *) return 1 ;;
      esac
    }
    prtend_state_set_cursor 101 ""
    prtend_state_set_cursor 102 ""
    state_dir="$(prtend_state_dir)"
    # Override prtend_state_clear so rm "fails" without actually mutating disk.
    prtend_state_clear() { return 1; }
    err_file="$(mktemp -t prtend-doctor-err.XXXXXX)"
    out="$(prtend_cmd_doctor --check stale_subscriptions --fix 2>"$err_file")"
    rc=$?
    err="$(cat "$err_file")"
    rm -f "$err_file"
    # surviving warn → no fail → exit 0
    assert_eq "exit code" 0 "$rc"
    assert_eq "status still warn" '"warn"' "$(jq -c '.checks[0].status' <<<"$out")"
    assert_eq "details empty" 0 "$(jq '.fixed[0].details | length' <<<"$out")"
    assert_contains "warn on stderr" "failed to remove state file" "$err"
    # Files still on disk.
    for pr in 101 102; do
      if [[ -e "$state_dir/$pr.json" ]]; then
        assert_eq "file $pr present" "present" "present"
      else
        assert_eq "file $pr present" "present" "absent"
      fi
    done
  )
}

# ----------------------------------------------------------------------------
# Case 13 — --check subset runs exactly the requested checks in canonical order.
# ----------------------------------------------------------------------------
case_check_subset() {
  echo "case: --check subset"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    install_fake_gh 2.62.0 1 alice
    load_libs
    # Pass in reverse order; expect canonical (config_readable, state_dir_writable).
    out="$(prtend_cmd_doctor --check state_dir_writable --check config_readable 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "checks length" 2 "$(jq '.checks | length' <<<"$out")"
    assert_eq "first check name" '"config_readable"' "$(jq -c '.checks[0].name' <<<"$out")"
    assert_eq "second check name" '"state_dir_writable"' "$(jq -c '.checks[1].name' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 14 — --check unknown name → exit 2, stderr, no stdout.
# ----------------------------------------------------------------------------
case_check_unknown() {
  echo "case: --check unknown"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    err_file="$(mktemp -t prtend-doctor-err.XXXXXX)"
    out="$(prtend_cmd_doctor --check bogus 2>"$err_file")"
    rc=$?
    err="$(cat "$err_file")"
    rm -f "$err_file"
    assert_eq "exit code" 2 "$rc"
    assert_eq "no stdout" "" "$out"
    assert_contains "stderr msg" "unknown check 'bogus'" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 15 — Marker version tautology (v1 → pass).
# ----------------------------------------------------------------------------
case_marker_v1() {
  echo "case: marker v1 pass"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    out="$(prtend_cmd_doctor --check marker_consistency 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "status" '"pass"' "$(jq -c '.checks[0].status' <<<"$out")"
    assert_contains "message" "Only marker v1 in use" "$(jq -r '.checks[0].message' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 16 — Marker version mismatch (override to v999 → warn).
# ----------------------------------------------------------------------------
case_marker_mismatch() {
  echo "case: marker mismatch warn"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    load_libs
    prtend_note_marker_version() { printf 'v999\n'; }
    out="$(prtend_cmd_doctor --check marker_consistency 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "status" '"warn"' "$(jq -c '.checks[0].status' <<<"$out")"
    assert_contains "message" "Unknown marker version v999" "$(jq -r '.checks[0].message' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 17 — Config with an orphaned `- item` under a scalar key is rejected.
# ----------------------------------------------------------------------------
case_forge_authed_account_format() {
  echo "case: forge authed account format"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    install_fake_gh 2.62.0 1 alice account
    load_libs
    out="$(prtend_cmd_doctor --check forge_cli_authed 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "status" '"pass"' "$(jq -c '.checks[0].status' <<<"$out")"
    assert_contains "message" "Authenticated as alice" "$(jq -r '.checks[0].message' <<<"$out")"
  )
}

case_config_orphan_list_item() {
  echo "case: config orphan list item"
  (
    new_sandbox
    cd "$SANDBOX" || exit
    install_fake_gh 2.62.0 1 alice
    load_libs
    export PRTEND_CONFIG="$SANDBOX/orphan.yml"
    cp "$FIXTURES/config.orphan_list.txt" "$PRTEND_CONFIG"
    out="$(prtend_cmd_doctor --check config_readable 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 1 "$rc"
    assert_eq "status" '"fail"' "$(jq -c '.checks[0].status' <<<"$out")"
    assert_contains "message" "outside a list block" "$(jq -r '.checks[0].message' <<<"$out")"
  )
}

case_all_pass
case_forge_missing
case_forge_unauthed
case_forge_old_version
case_forge_prerelease_at_floor
case_config_missing
case_config_malformed
case_state_dir_unwritable
case_stale_none
case_stale_two_no_fix
case_stale_two_fix
case_stale_fix_failure
case_check_subset
case_check_unknown
case_marker_v1
case_marker_mismatch
case_config_orphan_list_item
case_forge_authed_account_format

PASS="$(grep -c '^P' "$RESULTS" || true)"
FAIL="$(grep -c '^F' "$RESULTS" || true)"
echo
echo "passed: ${PASS:-0}    failed: ${FAIL:-0}"
if (( FAIL > 0 )); then exit 1; fi
