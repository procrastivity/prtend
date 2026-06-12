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
prtend — tend your PR while you pretend you're actually still there

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
  local url path
  if ! url="$(git remote get-url origin 2>/dev/null)"; then
    return 1
  fi
  url="${url%.git}"

  # Reduce to a "namespace/.../repo" path regardless of remote URL form, then
  # emit it with "/" replaced by "-" so nested GitLab groups (and GitHub
  # Enterprise nested orgs) don't collide on the leaf segment alone.
  if [[ "$url" == *"://"* ]]; then
    # Scheme URLs: https://host/owner/repo, http://..., ssh://git@host/owner/repo.
    path="${url#*://}"          # drop scheme
    path="${path#*@}"           # drop optional user@
    path="${path#*/}"           # drop host[:port]
  elif [[ "$url" == *:* ]]; then
    # scp-like: git@host:owner/repo (or git@host:group/subgroup/repo)
    path="${url#*:}"
  else
    path="$url"
  fi

  # Strip leading/trailing slashes, require at least one "/" separator.
  path="${path#/}"
  path="${path%/}"
  if [[ -z "$path" || "$path" != */* ]]; then
    return 1
  fi
  printf '%s\n' "${path//\//-}"
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

# Inverse of prtend_config_resolve: print the path that the given write-target
# WOULD write to, independent of whether a file is there yet. Used by
# `config init` to pick a destination and by `config show` to render the
# resolution chain. Never checks `-f`.
#
# env  → $PRTEND_CONFIG (return 1 if unset/empty)
# xdg  → $XDG_CONFIG_HOME/prtend/<slug>.yml (return 1 if XDG/HOME unset or
#        slug unresolvable)
# repo → <repo-root>/.claude/pr-reviewers.yml (return 1 if not in a git repo)
prtend_config_target_path() {
  local target="${1:-}" slug xdg repo_root
  if [[ -z "$target" ]]; then
    prtend_log_error "prtend_config_target_path: missing target argument"
    return 2
  fi
  case "$target" in
    env)
      if [[ -z "${PRTEND_CONFIG:-}" ]]; then
        return 1
      fi
      printf '%s\n' "$PRTEND_CONFIG"
      ;;
    xdg)
      if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
        xdg="$XDG_CONFIG_HOME"
      elif [[ -n "${HOME:-}" ]]; then
        xdg="$HOME/.config"
      else
        return 1
      fi
      if ! slug="$(prtend_repo_slug 2>/dev/null)"; then
        return 1
      fi
      printf '%s/prtend/%s.yml\n' "$xdg" "$slug"
      ;;
    repo)
      if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        return 1
      fi
      printf '%s/.claude/pr-reviewers.yml\n' "$repo_root"
      ;;
    *)
      prtend_log_error "prtend_config_target_path: unknown target '$target' (expected env|xdg|repo)"
      return 2
      ;;
  esac
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
  # `grep` exits 1 on no-match, which under `set -euo pipefail` would abort
  # the caller. Treat no-match as a normal empty result.
  local raw
  raw="$(grep -E -- "^${key}:" "$path" || true)"
  if [[ -z "$raw" ]]; then
    return 0
  fi
  value="$(printf '%s\n' "$raw" | head -n1 | sed -E "s/^${key}:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^['\"]//; s/['\"]$//")"
  printf '%s\n' "$value"
}

# Naive list reader for block-style YAML lists. Matches the scope choice of
# prtend_config_get above; flow-style lists (`[a, b]`) are not supported. The
# config writer (a future `config init`) always emits block-style.
prtend_config_list_get() {
  local key="${1:-}" path env_key
  if [[ -z "$key" ]]; then
    prtend_log_error "prtend_config_list_get: missing key argument"
    return 2
  fi
  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    prtend_log_error "prtend_config_list_get: invalid key '$key' (must match [A-Za-z_][A-Za-z0-9_]*)"
    return 2
  fi
  env_key="PRTEND_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  if [[ -n "${!env_key:-}" ]]; then
    local IFS=','
    # Split env var on commas; trim surrounding whitespace per item.
    local item
    for item in ${!env_key}; do
      item="${item#"${item%%[![:space:]]*}"}"
      item="${item%"${item##*[![:space:]]}"}"
      [[ -n "$item" ]] && printf '%s\n' "$item"
    done
    return 0
  fi
  path="$(prtend_config_resolve)"
  if [[ -z "$path" || ! -f "$path" ]]; then
    return 0
  fi
  # Pure-bash parser: walk the file, find the `<key>:` line, then collect
  # subsequent indented `- value` items until a non-list line or another
  # top-level key.
  local in_key=0 line v
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( in_key == 0 )); then
      if [[ "$line" =~ ^${key}:[[:space:]]*$ ]]; then
        in_key=1
      fi
      continue
    fi
    # Next top-level key (identifier at column 0 followed by `:`).
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*: ]]; then
      break
    fi
    # Blank line — tolerated; stay in the list block.
    if [[ "$line" =~ ^[[:space:]]*$ ]]; then
      continue
    fi
    # Indented `- value`.
    if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+(.+)$ ]]; then
      v="${BASH_REMATCH[1]}"
      # Strip surrounding quotes if matched (before comment stripping, so
      # that a `#` inside a quoted value isn't mistaken for a YAML comment).
      if [[ "$v" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]] || [[ "$v" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
        v="${BASH_REMATCH[1]}"
      else
        # Strip trailing comment.
        v="${v%%#*}"
        # Trim trailing whitespace.
        v="${v%"${v##*[![:space:]]}"}"
      fi
      if [[ -n "$v" ]]; then
        printf '%s\n' "$v"
      fi
      continue
    fi
    # Indented non-list content — list block ended.
    break
  done <"$path"
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
