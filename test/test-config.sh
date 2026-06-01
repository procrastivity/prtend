#!/usr/bin/env bash
# test-config.sh — covers `prtend config` (init|show|get|set|path).
# Same harness style as test-defer-write.sh: subshell isolation, no real
# network. No forge mocking needed; `config` never calls gh/glab.
#
# shellcheck disable=SC2030,SC2031,SC2329

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_ROOT/test/fixtures/config"
BIN="$REPO_ROOT/bin/prtend"

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

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'P\n' >>"$RESULTS"
    printf '  ok    %s\n' "$label"
  else
    printf 'F\n' >>"$RESULTS"
    printf '  FAIL  %s\n        needle (should be absent): %q\n        haystack: %q\n' "$label" "$needle" "$haystack"
  fi
}

new_sandbox() {
  SANDBOX="$(mktemp -d -t prtend-test.XXXXXX)"
  XDG_ROOT="$(mktemp -d -t prtend-xdg.XXXXXX)"
  (
    cd "$SANDBOX" || return
    git init -q
    git remote add origin https://github.com/foo/bar.git
    git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  )
  unset PRTEND_CONFIG
  export XDG_CONFIG_HOME="$XDG_ROOT"
  export HOME="$XDG_ROOT"  # for safety; resolver falls back to HOME if XDG unset
}

# ----------------------------------------------------------------------------
# Case 1 — init happy path, xdg target; byte-matches expected fixture
# ----------------------------------------------------------------------------
case_init_xdg() {
  echo "case: init happy path xdg"
  (
    new_sandbox
    cd "$SANDBOX" || return
    out="$("$BIN" config init --watch-strategy blocking --write-target xdg 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    p="$(jq -r .written_to <<<"$out")"
    assert_contains "written_to ends at /prtend/foo-bar.yml" "/prtend/foo-bar.yml" "$p"
    assert_eq "write_target" '"xdg"' "$(jq -c .write_target <<<"$out")"
    keys="$(jq -c .keys_set <<<"$out")"
    assert_eq "keys_set fixed array" \
      '["system_reviewers","optional_reviewers","watch_strategy","write_target","poll_interval_seconds","ci_retry_limit"]' \
      "$keys"
    if diff -q "$p" "$FIXTURES/expected_init.minimal.yml" >/dev/null; then
      assert_eq "byte-matches expected fixture" 0 0
    else
      assert_eq "byte-matches expected fixture" 0 1
      diff "$p" "$FIXTURES/expected_init.minimal.yml" || true
    fi
  )
}

# ----------------------------------------------------------------------------
# Case 2 — init happy path, repo target
# ----------------------------------------------------------------------------
case_init_repo() {
  echo "case: init happy path repo"
  (
    new_sandbox
    cd "$SANDBOX" || return
    out="$("$BIN" config init --watch-strategy blocking --write-target repo 2>/dev/null)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    p="$(jq -r .written_to <<<"$out")"
    assert_contains "path is repo .claude" "/.claude/pr-reviewers.yml" "$p"
    if [[ -f "$p" ]]; then assert_eq "file exists" 0 0; else assert_eq "file exists" 0 1; fi
  )
}

# ----------------------------------------------------------------------------
# Case 3 — init happy path, env target
# ----------------------------------------------------------------------------
case_init_env() {
  echo "case: init happy path env"
  (
    new_sandbox
    cd "$SANDBOX" || return
    target="$SANDBOX/custom.yml"
    PRTEND_CONFIG="$target" "$BIN" config init --watch-strategy blocking --write-target env >/dev/null
    rc=$?
    assert_eq "exit code" 0 "$rc"
    if [[ -f "$target" ]]; then assert_eq "file at PRTEND_CONFIG" 0 0; else assert_eq "file at PRTEND_CONFIG" 0 1; fi
  )
}

# ----------------------------------------------------------------------------
# Case 4 — init env target without $PRTEND_CONFIG
# ----------------------------------------------------------------------------
case_init_env_missing() {
  echo "case: init env target without PRTEND_CONFIG"
  (
    new_sandbox
    cd "$SANDBOX" || return
    err="$("$BIN" config init --watch-strategy blocking --write-target env 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 2 "$rc"
    assert_contains "stderr message" "PRTEND_CONFIG to be set" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 5 — init invalid --watch-strategy
# ----------------------------------------------------------------------------
case_init_bad_strategy() {
  echo "case: init invalid --watch-strategy"
  (
    new_sandbox
    cd "$SANDBOX" || return
    "$BIN" config init --watch-strategy nonsense --write-target xdg >/dev/null 2>&1
    assert_eq "exit code" 2 "$?"
  )
}

# ----------------------------------------------------------------------------
# Case 6 — init invalid --write-target
# ----------------------------------------------------------------------------
case_init_bad_target() {
  echo "case: init invalid --write-target"
  (
    new_sandbox
    cd "$SANDBOX" || return
    "$BIN" config init --watch-strategy blocking --write-target nope >/dev/null 2>&1
    assert_eq "exit code" 2 "$?"
  )
}

# ----------------------------------------------------------------------------
# Case 7 — init invalid --poll-interval-seconds 0
# ----------------------------------------------------------------------------
case_init_bad_poll_zero() {
  echo "case: init --poll-interval-seconds 0"
  (
    new_sandbox
    cd "$SANDBOX" || return
    "$BIN" config init --watch-strategy blocking --write-target xdg --poll-interval-seconds 0 >/dev/null 2>&1
    assert_eq "exit code" 2 "$?"
  )
}

# ----------------------------------------------------------------------------
# Case 8 — init non-numeric --ci-retry-limit
# ----------------------------------------------------------------------------
case_init_bad_retry() {
  echo "case: init non-numeric --ci-retry-limit"
  (
    new_sandbox
    cd "$SANDBOX" || return
    "$BIN" config init --watch-strategy blocking --write-target xdg --ci-retry-limit abc >/dev/null 2>&1
    assert_eq "exit code" 2 "$?"
  )
}

# ----------------------------------------------------------------------------
# Case 9 — init overwrite refusal
# ----------------------------------------------------------------------------
case_init_overwrite_refused() {
  echo "case: init overwrite refusal"
  (
    new_sandbox
    cd "$SANDBOX" || return
    "$BIN" config init --watch-strategy blocking --write-target xdg >/dev/null
    before="$(cat "$XDG_ROOT/prtend/foo-bar.yml")"
    err="$("$BIN" config init --watch-strategy poll-on-resume --write-target xdg 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 4 "$rc"
    assert_contains "stderr message" "pass --force to overwrite" "$err"
    after="$(cat "$XDG_ROOT/prtend/foo-bar.yml")"
    assert_eq "file unchanged" "$before" "$after"
  )
}

# ----------------------------------------------------------------------------
# Case 10 — init --force overwrites
# ----------------------------------------------------------------------------
case_init_force_overwrite() {
  echo "case: init --force overwrite"
  (
    new_sandbox
    cd "$SANDBOX" || return
    "$BIN" config init --watch-strategy blocking --write-target xdg >/dev/null
    "$BIN" config init --watch-strategy poll-on-resume --write-target xdg --force >/dev/null
    rc=$?
    assert_eq "exit code" 0 "$rc"
    ws="$("$BIN" config get watch_strategy)"
    assert_eq "value is rewritten" "poll-on-resume" "$ws"
  )
}

# ----------------------------------------------------------------------------
# Case 11 — init writes empty list keys when no reviewers passed
# ----------------------------------------------------------------------------
case_init_empty_lists() {
  echo "case: init writes empty list keys"
  (
    new_sandbox
    cd "$SANDBOX" || return
    "$BIN" config init --watch-strategy blocking --write-target xdg >/dev/null
    body="$(cat "$XDG_ROOT/prtend/foo-bar.yml")"
    assert_contains "bare system_reviewers:" $'\nsystem_reviewers:\n' "$body"
    # optional_reviewers is the last line of the file; command substitution
    # stripped the trailing newline so we only assert the leading boundary.
    assert_contains "bare optional_reviewers:" $'\noptional_reviewers:' "$body"
    assert_not_contains "no flow-style brackets" "[]" "$body"
  )
}

# ----------------------------------------------------------------------------
# Case 12 — init quotes a login containing '#'; get round-trips unquoted
# ----------------------------------------------------------------------------
case_init_quoted_reviewer() {
  echo "case: init quotes # in login; get unquotes"
  (
    new_sandbox
    cd "$SANDBOX" || return
    "$BIN" config init --watch-strategy blocking --write-target xdg --system-reviewer 'bot#1' >/dev/null
    body="$(cat "$XDG_ROOT/prtend/foo-bar.yml")"
    # shellcheck disable=SC2016
    assert_contains "yaml emits quoted form" '- "bot#1"' "$body"
    val="$("$BIN" config get system_reviewers)"
    assert_eq "get returns unquoted" "bot#1" "$val"
  )
}

# ----------------------------------------------------------------------------
# Case 13 — show with populated.yml as the active xdg config
# ----------------------------------------------------------------------------
case_show_populated() {
  echo "case: show with populated active config"
  (
    new_sandbox
    cd "$SANDBOX" || return
    mkdir -p "$XDG_ROOT/prtend"
    cp "$FIXTURES/populated.yml" "$XDG_ROOT/prtend/foo-bar.yml"
    out="$("$BIN" config show)"
    assert_eq "active path matches"   "$XDG_ROOT/prtend/foo-bar.yml" "$(jq -r .active_config_path <<<"$out")"
    assert_eq "xdg entry is active"   'true'  "$(jq -c '.resolution_chain[] | select(.source=="xdg") | .active' <<<"$out")"
    assert_eq "env entry not active"  'false' "$(jq -c '.resolution_chain[] | select(.source=="env") | .active' <<<"$out")"
    assert_eq "system_reviewers"      '["copilot","duo"]'   "$(jq -c .values.system_reviewers <<<"$out")"
    assert_eq "optional_reviewers"    '["alice","bob"]'     "$(jq -c .values.optional_reviewers <<<"$out")"
    assert_eq "poll_interval is int"  '30'                  "$(jq -c .values.poll_interval_seconds <<<"$out")"
    assert_eq "ci_retry_limit is int" '5'                   "$(jq -c .values.ci_retry_limit <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 14 — show with no active config
# ----------------------------------------------------------------------------
case_show_no_config() {
  echo "case: show with no active config"
  (
    new_sandbox
    cd "$SANDBOX" || return
    out="$("$BIN" config show)"
    assert_eq "active_config_path null" 'null' "$(jq -c .active_config_path <<<"$out")"
    assert_eq "all entries inactive"    '[false,false,false]' "$(jq -c '[.resolution_chain[].active]' <<<"$out")"
    assert_eq "all entry paths null"    '[null,null,null]'    "$(jq -c '[.resolution_chain[].path]' <<<"$out")"
    assert_eq "values empty"            '{}' "$(jq -c .values <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 15 — show with PRTEND_CONFIG set but missing file
# ----------------------------------------------------------------------------
case_show_env_missing_file() {
  echo "case: show with PRTEND_CONFIG set but missing"
  (
    new_sandbox
    cd "$SANDBOX" || return
    mkdir -p "$XDG_ROOT/prtend"
    cp "$FIXTURES/populated.yml" "$XDG_ROOT/prtend/foo-bar.yml"
    export PRTEND_CONFIG="$SANDBOX/nope.yml"
    out="$("$BIN" config show)"
    assert_eq "env path reported"       "\"$SANDBOX/nope.yml\"" "$(jq -c '.resolution_chain[] | select(.source=="env") | .path' <<<"$out")"
    assert_eq "env not active"          'false' "$(jq -c '.resolution_chain[] | select(.source=="env") | .active' <<<"$out")"
    assert_eq "xdg active"              'true'  "$(jq -c '.resolution_chain[] | select(.source=="xdg") | .active' <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 16 — show defaults appear in `values` when file omits them
# ----------------------------------------------------------------------------
case_show_defaults() {
  echo "case: show defaults appear in values"
  (
    new_sandbox
    cd "$SANDBOX" || return
    mkdir -p "$XDG_ROOT/prtend"
    cp "$FIXTURES/minimal.yml" "$XDG_ROOT/prtend/foo-bar.yml"
    out="$("$BIN" config show)"
    assert_eq "poll default is 15"   '15' "$(jq -c .values.poll_interval_seconds <<<"$out")"
    assert_eq "retry default is 3"   '3'  "$(jq -c .values.ci_retry_limit <<<"$out")"
  )
}

# ----------------------------------------------------------------------------
# Case 17 — get scalar present
# ----------------------------------------------------------------------------
case_get_scalar_present() {
  echo "case: get scalar present"
  (
    new_sandbox
    cd "$SANDBOX" || return
    mkdir -p "$XDG_ROOT/prtend"
    cp "$FIXTURES/populated.yml" "$XDG_ROOT/prtend/foo-bar.yml"
    out="$("$BIN" config get watch_strategy)"
    assert_eq "value" "blocking" "$out"
  )
}

# ----------------------------------------------------------------------------
# Case 18 — get scalar absent → empty stdout, exit 0
# ----------------------------------------------------------------------------
case_get_scalar_absent() {
  echo "case: get scalar absent"
  (
    new_sandbox
    cd "$SANDBOX" || return
    mkdir -p "$XDG_ROOT/prtend"
    cp "$FIXTURES/minimal.yml" "$XDG_ROOT/prtend/foo-bar.yml"
    out="$("$BIN" config get poll_interval_seconds)"
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "empty stdout" "" "$out"
  )
}

# ----------------------------------------------------------------------------
# Case 19 — get list present (one per line)
# ----------------------------------------------------------------------------
case_get_list_present() {
  echo "case: get list present"
  (
    new_sandbox
    cd "$SANDBOX" || return
    mkdir -p "$XDG_ROOT/prtend"
    cp "$FIXTURES/populated.yml" "$XDG_ROOT/prtend/foo-bar.yml"
    out="$("$BIN" config get system_reviewers)"
    assert_eq "two entries" $'copilot\nduo' "$out"
  )
}

# ----------------------------------------------------------------------------
# Case 20 — get list with quoted entry → unquoted on stdout
# ----------------------------------------------------------------------------
case_get_list_quoted() {
  echo "case: get list with quoted entry"
  (
    new_sandbox
    cd "$SANDBOX" || return
    mkdir -p "$XDG_ROOT/prtend"
    cp "$FIXTURES/with_quoted.yml" "$XDG_ROOT/prtend/foo-bar.yml"
    out="$("$BIN" config get system_reviewers)"
    assert_eq "unquoted output" $'bot#1\ncopilot' "$out"
  )
}

# ----------------------------------------------------------------------------
# Case 21 — get unknown key
# ----------------------------------------------------------------------------
case_get_unknown_key() {
  echo "case: get unknown key"
  (
    new_sandbox
    cd "$SANDBOX" || return
    err="$("$BIN" config get nonsense 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 2 "$rc"
    assert_contains "stderr" "unknown key" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 22 — get invalid key format
# ----------------------------------------------------------------------------
case_get_bad_key_format() {
  echo "case: get invalid key format"
  (
    new_sandbox
    cd "$SANDBOX" || return
    "$BIN" config get '1bad' >/dev/null 2>&1
    assert_eq "exit code" 2 "$?"
  )
}

# ----------------------------------------------------------------------------
# Case 23 — set scalar; other keys preserved
# ----------------------------------------------------------------------------
case_set_scalar_preserves() {
  echo "case: set scalar preserves other keys"
  (
    new_sandbox
    cd "$SANDBOX" || return
    mkdir -p "$XDG_ROOT/prtend"
    cp "$FIXTURES/populated.yml" "$XDG_ROOT/prtend/foo-bar.yml"
    "$BIN" config set watch_strategy background
    rc=$?
    assert_eq "exit code" 0 "$rc"
    assert_eq "watch_strategy updated" "background" "$("$BIN" config get watch_strategy)"
    assert_eq "write_target preserved" "xdg"        "$("$BIN" config get write_target)"
    assert_eq "system_reviewers preserved" $'copilot\nduo' "$("$BIN" config get system_reviewers)"
    assert_eq "poll preserved" "30" "$("$BIN" config get poll_interval_seconds)"
  )
}

# ----------------------------------------------------------------------------
# Case 24 — set invalid scalar value
# ----------------------------------------------------------------------------
case_set_bad_scalar() {
  echo "case: set invalid scalar value"
  (
    new_sandbox
    cd "$SANDBOX" || return
    mkdir -p "$XDG_ROOT/prtend"
    cp "$FIXTURES/populated.yml" "$XDG_ROOT/prtend/foo-bar.yml"
    "$BIN" config set watch_strategy nonsense >/dev/null 2>&1
    assert_eq "exit code" 2 "$?"
  )
}

# ----------------------------------------------------------------------------
# Case 25 — set list (comma-separated)
# ----------------------------------------------------------------------------
case_set_list() {
  echo "case: set list comma-separated"
  (
    new_sandbox
    cd "$SANDBOX" || return
    mkdir -p "$XDG_ROOT/prtend"
    cp "$FIXTURES/populated.yml" "$XDG_ROOT/prtend/foo-bar.yml"
    "$BIN" config set system_reviewers "a,b,c"
    assert_eq "list updated" $'a\nb\nc' "$("$BIN" config get system_reviewers)"
    # Adjacent key still readable.
    assert_eq "optional_reviewers preserved" $'alice\nbob' "$("$BIN" config get optional_reviewers)"
  )
}

# ----------------------------------------------------------------------------
# Case 26 — set list with empty element
# ----------------------------------------------------------------------------
case_set_list_empty_elem() {
  echo "case: set list with empty element"
  (
    new_sandbox
    cd "$SANDBOX" || return
    mkdir -p "$XDG_ROOT/prtend"
    cp "$FIXTURES/populated.yml" "$XDG_ROOT/prtend/foo-bar.yml"
    err="$("$BIN" config set system_reviewers 'a,,b' 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 2 "$rc"
    assert_contains "stderr" "empty list element" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 27 — set without active config
# ----------------------------------------------------------------------------
case_set_no_config() {
  echo "case: set without active config"
  (
    new_sandbox
    cd "$SANDBOX" || return
    err="$("$BIN" config set watch_strategy blocking 2>&1 1>/dev/null)"
    rc=$?
    assert_eq "exit code" 4 "$rc"
    assert_contains "stderr" "no active config" "$err"
  )
}

# ----------------------------------------------------------------------------
# Case 28 — set unknown key
# ----------------------------------------------------------------------------
case_set_unknown_key() {
  echo "case: set unknown key"
  (
    new_sandbox
    cd "$SANDBOX" || return
    mkdir -p "$XDG_ROOT/prtend"
    cp "$FIXTURES/populated.yml" "$XDG_ROOT/prtend/foo-bar.yml"
    "$BIN" config set nonsense whatever >/dev/null 2>&1
    assert_eq "exit code" 2 "$?"
  )
}

# ----------------------------------------------------------------------------
# Case 29 — path with active config
# ----------------------------------------------------------------------------
case_path_active() {
  echo "case: path with active config"
  (
    new_sandbox
    cd "$SANDBOX" || return
    mkdir -p "$XDG_ROOT/prtend"
    cp "$FIXTURES/populated.yml" "$XDG_ROOT/prtend/foo-bar.yml"
    out="$("$BIN" config path)"
    assert_eq "exit code" 0 "$?"
    assert_eq "prints active path" "$XDG_ROOT/prtend/foo-bar.yml" "$out"
  )
}

# ----------------------------------------------------------------------------
# Case 30 — path with no active config
# ----------------------------------------------------------------------------
case_path_no_config() {
  echo "case: path with no active config"
  (
    new_sandbox
    cd "$SANDBOX" || return
    out="$("$BIN" config path)"
    assert_eq "exit code" 0 "$?"
    assert_eq "empty stdout" "" "$out"
  )
}

# ----------------------------------------------------------------------------
# Case 31 — unknown sub-subcommand
# ----------------------------------------------------------------------------
case_unknown_sub() {
  echo "case: unknown sub-subcommand"
  (
    new_sandbox
    cd "$SANDBOX" || return
    "$BIN" config bogus >/dev/null 2>&1
    assert_eq "exit code" 2 "$?"
  )
}

# ----------------------------------------------------------------------------
# Case 32 — sub-help
# ----------------------------------------------------------------------------
case_sub_help() {
  echo "case: sub-help"
  (
    new_sandbox
    cd "$SANDBOX" || return
    out="$("$BIN" config --help)"
    assert_eq "exit code" 0 "$?"
    assert_contains "lists init"  "init"  "$out"
    assert_contains "lists show"  "show"  "$out"
    assert_contains "lists get"   "get"   "$out"
    assert_contains "lists set"   "set"   "$out"
    assert_contains "lists path"  "path"  "$out"
  )
}

case_init_xdg
case_init_repo
case_init_env
case_init_env_missing
case_init_bad_strategy
case_init_bad_target
case_init_bad_poll_zero
case_init_bad_retry
case_init_overwrite_refused
case_init_force_overwrite
case_init_empty_lists
case_init_quoted_reviewer
case_show_populated
case_show_no_config
case_show_env_missing_file
case_show_defaults
case_get_scalar_present
case_get_scalar_absent
case_get_list_present
case_get_list_quoted
case_get_unknown_key
case_get_bad_key_format
case_set_scalar_preserves
case_set_bad_scalar
case_set_list
case_set_list_empty_elem
case_set_no_config
case_set_unknown_key
case_path_active
case_path_no_config
case_unknown_sub
case_sub_help

PASS="$(grep -c '^P' "$RESULTS" || true)"
FAIL="$(grep -c '^F' "$RESULTS" || true)"
echo
echo "passed: ${PASS:-0}    failed: ${FAIL:-0}"
if (( FAIL > 0 )); then exit 1; fi
