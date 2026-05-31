#!/usr/bin/env bash
# prtend-lib.bash — core helpers: version, usage, logging, config, atomic write.
# Sourced by bin/prtend and every subcommand. Never executed directly.

# Guard against double-source.
if [[ -n "${PRTEND_LIB_LOADED:-}" ]]; then
  return 0
fi
PRTEND_LIB_LOADED=1

# Defensive: callers should source under strict mode, but enable here too so
# that ad-hoc `bash -c 'source lib; fn'` callers get the same safety.
set -euo pipefail

PRTEND_VERSION="0.1.0"
PRTEND_VERBOSE="${PRTEND_VERBOSE:-0}"

prtend_version() {
  printf '%s\n' "$PRTEND_VERSION"
}

prtend_usage() {
  cat <<'EOF'
prtend — tend your PR while you pretend you're not procrastinating

Usage:
  prtend <subcommand> [options]
  prtend --help
  prtend --version

Subcommands:
  detect         Print JSON { forge, branch, pr, pr_state }
  pr-open        Ensure branch pushed; create PR if absent; run reviewer flow
  ci-watch       Watch CI for a PR; emit one event as JSON and exit
  reviews-poll   Poll review batches for a PR; emit new batches as JSON
  watch          Multiplex ci-watch and reviews-poll; one event per call
  note-post      Post a resolution note (with marker) to a review comment
  defer-write    Write a defer Markdown doc; print its path
  config         Manage config (init | show | get | set)
  doctor         Preconditions check; optional --fix

Environment:
  PRTEND_CONFIG          Explicit path to a config file (highest precedence)
  PRTEND_LIB             Override lib directory (default: ../lib/prtend)
  PRTEND_VERBOSE         Set to 1 for verbose info logging

See docs/cli-contract.md for the full subcommand reference.
EOF
}

# -- logging ---------------------------------------------------------------

prtend_log_info() {
  if [[ "${PRTEND_VERBOSE:-0}" == "1" ]]; then
    printf 'info: %s\n' "$*" >&2
  fi
}

prtend_log_warn() {
  printf 'warn: %s\n' "$*" >&2
}

prtend_log_error() {
  printf 'error: %s\n' "$*" >&2
}

# -- repo identity ---------------------------------------------------------

prtend_repo_slug() {
  local url path repo owner
  if ! url="$(git remote get-url origin 2>/dev/null)"; then
    return 1
  fi
  url="${url%.git}"

  # Reduce to an "<owner>/<repo>" intermediate regardless of remote URL form,
  # then emit "<owner>-<repo>" so the slug is safe to use in filenames.
  if [[ "$url" == *"://"* ]]; then
    # Scheme URLs: https://host/owner/repo, http://..., ssh://git@host/owner/repo.
    path="${url#*://}"          # drop scheme
    path="${path#*@}"           # drop optional user@
    path="${path#*/}"           # drop host[:port]
  elif [[ "$url" == *:* ]]; then
    # scp-like: git@host:owner/repo
    path="${url#*:}"
  else
    path="$url"
  fi

  repo="${path##*/}"
  path="${path%/"$repo"}"
  owner="${path##*/}"
  if [[ -z "$owner" || -z "$repo" ]]; then
    return 1
  fi
  printf '%s-%s\n' "$owner" "$repo"
}

# -- config ----------------------------------------------------------------

# Walk the resolution chain; print the first existing config path, or empty.
# Order: $PRTEND_CONFIG → $XDG_CONFIG_HOME/prtend/<slug>.yml → <repo>/.claude/pr-reviewers.yml
prtend_config_resolve() {
  local slug xdg repo_root candidate

  if [[ -n "${PRTEND_CONFIG:-}" && -f "$PRTEND_CONFIG" ]]; then
    printf '%s\n' "$PRTEND_CONFIG"
    return 0
  fi

  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    xdg="$XDG_CONFIG_HOME"
  elif [[ -n "${HOME:-}" ]]; then
    xdg="$HOME/.config"
  else
    xdg=""
  fi
  if [[ -n "$xdg" ]] && slug="$(prtend_repo_slug 2>/dev/null)"; then
    candidate="$xdg/prtend/${slug}.yml"
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    candidate="$repo_root/.claude/pr-reviewers.yml"
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  # No config found — exit successfully with no output.
  return 0
}

# Naive scalar lookup against the resolved YAML. Sufficient for v0 flat-scalar
# keys (watch_strategy, poll_interval_seconds, ci_retry_limit). Returns only the
# first matching scalar value; list-valued keys (system_reviewers,
# optional_reviewers) are not handled here and must be read by the caller.
prtend_config_get() {
  local key="${1:-}" path env_key value
  if [[ -z "$key" ]]; then
    prtend_log_error "prtend_config_get: missing key argument"
    return 2
  fi
  # Reject keys that aren't safe identifiers — the value is interpolated into a
  # grep regex and an env-var name below, so metacharacters or leading dashes
  # would be unsafe or could be mistaken for flags.
  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    prtend_log_error "prtend_config_get: invalid key '$key' (must match [A-Za-z_][A-Za-z0-9_]*)"
    return 2
  fi
  env_key="PRTEND_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  if [[ -n "${!env_key:-}" ]]; then
    printf '%s\n' "${!env_key}"
    return 0
  fi
  path="$(prtend_config_resolve)"
  if [[ -z "$path" || ! -f "$path" ]]; then
    return 0
  fi
  value="$(grep -E -- "^${key}:" "$path" | head -n1 | sed -E "s/^${key}:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^['\"]//; s/['\"]$//")"
  printf '%s\n' "$value"
}

# -- state dir -------------------------------------------------------------

prtend_state_dir() {
  local cfg slug repo_root xdg_state
  cfg="$(prtend_config_resolve)"
  if [[ -n "$cfg" && "$cfg" == */.claude/pr-reviewers.yml ]]; then
    repo_root="${cfg%/.claude/pr-reviewers.yml}"
    printf '%s/.claude/prtend-state\n' "$repo_root"
    return 0
  fi
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    xdg_state="$XDG_STATE_HOME"
  elif [[ -n "${HOME:-}" ]]; then
    xdg_state="$HOME/.local/state"
  else
    xdg_state=""
  fi
  if [[ -n "$xdg_state" ]] && slug="$(prtend_repo_slug 2>/dev/null)"; then
    printf '%s/prtend/%s\n' "$xdg_state" "$slug"
    return 0
  fi
  # Fall back to repo-local state directory when slug is unavailable.
  if repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s/.claude/prtend-state\n' "$repo_root"
    return 0
  fi
  return 1
}

# -- atomic write ----------------------------------------------------------

# Reads stdin, writes to <path> via tempfile + rename. Creates the parent
# directory if missing.
prtend_atomic_write() {
  local path="${1:-}" dir tmp
  if [[ -z "$path" ]]; then
    prtend_log_error "prtend_atomic_write: missing path argument"
    return 2
  fi
  dir="$(dirname "$path")"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
  fi
  if ! tmp="$(mktemp "${dir}/.prtend.XXXXXX")"; then
    prtend_log_error "prtend_atomic_write: mktemp failed in $dir"
    return 1
  fi
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    prtend_log_error "prtend_atomic_write: mv failed for $path"
    return 1
  fi
}

# -- json convenience ------------------------------------------------------

prtend_json_get() {
  local expr="${1:-}"
  if [[ -z "$expr" ]]; then
    prtend_log_error "prtend_json_get: missing jq expression"
    return 2
  fi
  jq -r -- "$expr"
}
