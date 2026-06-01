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
  if ! prtend_forge_detect >/dev/null; then
    return 3
  fi
  prtend_forge_dispatch cli_ready
}

# -- branch ----------------------------------------------------------------

prtend_forge_current_branch() {
  git rev-parse --abbrev-ref HEAD
}
