# Step 03 — Forge detection and readiness

## Context

Create `prtend-forge-lib.bash`, the single module that knows about `gh` vs `glab`. This step lands only the detection + readiness + current-branch surface; the read/mutation operations come in steps 04 and 09. Every other prtend module will eventually call through this lib instead of shelling out to a forge CLI directly. See `../forge-mapping.md` § "Detect forge from repo" and § "Authentication", and `../repo-bootstrap.md` § "Forge abstraction — `prtend-forge-lib.bash`".

## Prerequisites

- Step 01 (`scaffold`) complete — `lib/prtend/` exists.
- Step 02 (`dispatcher`) complete — `prtend-lib.bash` provides `prtend_log_*` helpers; `bin/prtend` knows how to source libs.

Required on the host for smoke tests: `gh` (with at least `--version` working), `glab` (with at least `--version` working), and a git checkout pointing at either a GitHub or GitLab remote.

## Goal

After this step:

- `lib/prtend/prtend-forge-lib.bash` exists and is sourceable from `bin/prtend`.
- `prtend_forge_detect` prints `github` or `gitlab` (or empty + exit 1) based on the current repo's origin and caches the result in `$PRTEND_FORGE` for the rest of the dispatcher's lifetime.
- `prtend_forge_cli_ready` returns 0 (ready), 1 (installed but not authed), or 3 (CLI not installed) for whichever forge is active.
- `prtend_forge_current_branch` prints the current branch via `git rev-parse --abbrev-ref HEAD`.
- The dispatcher (`bin/prtend`) sources the forge lib alongside the core lib so that subcommands can use these functions when they land.
- No subcommand uses these yet; this step is library-only.

## Files to create or modify

- `lib/prtend/prtend-forge-lib.bash` (NEW)
- `bin/prtend` (MODIFY — source the new lib)

## Implementation

### `lib/prtend/prtend-forge-lib.bash`

Public surface for this step (the rest of the public functions in `repo-bootstrap.md` § "Forge abstraction" are stubbed in later steps — do not implement them yet):

```bash
prtend_forge_detect()           # echoes "github" | "gitlab"; sets $PRTEND_FORGE; exit 1 if neither
prtend_forge_cli_ready()        # 0 ready / 1 not authed / 3 not installed for the active forge
prtend_forge_current_branch()   # echoes current branch name
```

Plus the internal dispatch scaffold from `repo-bootstrap.md` § "Internal dispatch helper":

```bash
prtend_forge_dispatch <suffix> "$@"   # calls _prtend_forge_gh_<suffix> or _prtend_forge_gl_<suffix>
```

Wire `prtend_forge_cli_ready` through `prtend_forge_dispatch cli_ready` so the pattern is established before step 04 piles on more operations.

### Detection algorithm

Per `../forge-mapping.md` § "Detect forge from repo":

1. If `$PRTEND_FORGE` is already set and non-empty, echo it and return 0 (cache hit).
2. Try `gh repo view --json url >/dev/null 2>&1`. On exit 0, set `PRTEND_FORGE=github` and return.
3. Else try `glab repo view --output json >/dev/null 2>&1`. On exit 0, set `PRTEND_FORGE=gitlab` and return.
4. Else fall back to URL sniffing on `git remote get-url origin` — `github.com` / GHE hostnames → `github`; `gitlab.com` / self-hosted GitLab hostnames → `gitlab`. This covers the "CLI not installed but we still want a hint" case.
5. If nothing matches, echo nothing, return 1.

The cache check at step 1 is what makes the dispatcher's lifetime caching work — every call after the first is free.

For the "both `gh` and `glab` succeed" case (a repo with both GitHub origin and a GitLab mirror), prefer the remote pointed at by the upstream tracking branch (`git rev-parse --abbrev-ref --symbolic-full-name @{u}` → take its remote prefix → resolve via `git remote get-url <remote>` → sniff host). If no upstream is configured, prefer `github` (matches the order of the probe).

### Readiness algorithm

Per `../forge-mapping.md` § "Authentication":

- `_prtend_forge_gh_cli_ready`: `command -v gh >/dev/null || return 3`; then `gh auth status >/dev/null 2>&1`. Exit 0 if authed, 1 otherwise.
- `_prtend_forge_gl_cli_ready`: `command -v glab >/dev/null || return 3`; then `glab auth status >/dev/null 2>&1`. Exit 0 if authed, 1 otherwise.

`prtend_forge_cli_ready` calls `prtend_forge_detect` first (to populate `$PRTEND_FORGE`) then `prtend_forge_dispatch cli_ready`. If detection fails, return 3.

### Key decisions

- **No other public forge functions yet.** Resist the urge to add `prtend_forge_pr_for_branch` here — step 04 owns that. Step 03 is "the lib exists, detection works, the dispatch pattern is established."
- **Private functions follow the `_prtend_forge_<gh|gl>_<suffix>` naming.** The leading underscore signals "internal to this file." Public functions are `prtend_forge_<name>` (no underscore prefix).
- **URL sniffing is a fallback, not the primary path.** The forge CLI's own probe is more reliable (it picks up enterprise hostnames, SSO sessions, etc.). URL sniffing exists so `doctor` can still report "this looks like a GitHub repo but `gh` isn't installed" instead of giving up.
- **Never call `prtend_forge_cli_ready` from `prtend_forge_detect`.** Detection should work even when the user has neither CLI installed (so `doctor` can complain coherently). Authentication is a separate concern.
- **Exit codes are part of the contract** — `cli_ready` callers (notably step 11's `doctor`) branch on 0/1/3. Don't repurpose them.

### `bin/prtend` change

Add a single line next to the existing `source "$PRTEND_LIB/prtend-lib.bash"`:

```bash
source "$PRTEND_LIB/prtend-forge-lib.bash"
```

The forge lib must source cleanly even when neither `gh` nor `glab` is installed — sourcing just defines functions; it must not probe anything at source time. Verify by sourcing in a subshell with `PATH=/usr/bin:/bin`.

## Verification

```bash
shellcheck bin/prtend lib/prtend/prtend-lib.bash lib/prtend/prtend-forge-lib.bash
# → no output, exit 0

# Lib sources cleanly even with no forge CLIs available.
env -i PATH=/usr/bin:/bin HOME="$HOME" bash -c 'source lib/prtend/prtend-forge-lib.bash && declare -F prtend_forge_detect'
# → "prtend_forge_detect" on stdout; exit 0

# Detection in this repo (origin is github.com/dflydev/prtend or similar GitHub URL).
bash -c 'source lib/prtend/prtend-lib.bash; source lib/prtend/prtend-forge-lib.bash; prtend_forge_detect'
# → "github"; exit 0

# Cache hit: second call uses $PRTEND_FORGE.
bash -c 'source lib/prtend/prtend-lib.bash; source lib/prtend/prtend-forge-lib.bash; PRTEND_FORGE=gitlab prtend_forge_detect'
# → "gitlab"; exit 0 (cache wins over probing)

# Readiness, assuming gh is installed and authed in the dev environment.
bash -c 'source lib/prtend/prtend-lib.bash; source lib/prtend/prtend-forge-lib.bash; prtend_forge_cli_ready; echo "exit=$?"'
# → exit=0 (or exit=1 if gh is installed but not authed; exit=3 if not installed)

# Current branch matches git.
bash -c 'source lib/prtend/prtend-lib.bash; source lib/prtend/prtend-forge-lib.bash; prtend_forge_current_branch'
# → same as `git rev-parse --abbrev-ref HEAD`

# Dispatcher still healthy after sourcing the new lib.
bin/prtend --help
# → exit 0, prints usage
bin/prtend --version
# → "prtend 0.1.0"; exit 0
```

If a GitLab remote is available in another checkout, repeat the detection test there and confirm `gitlab` is printed. Otherwise, simulate by exporting `PRTEND_FORGE=gitlab` and verifying the cache path returns the override.

## Done

- [ ] `lib/prtend/prtend-forge-lib.bash` exists and defines `prtend_forge_detect`, `prtend_forge_cli_ready`, `prtend_forge_current_branch`, and `prtend_forge_dispatch` (plus the two `_prtend_forge_<gh|gl>_cli_ready` privates)
- [ ] `bin/prtend` sources the new lib alongside `prtend-lib.bash`
- [ ] `shellcheck` is clean on both lib files and the dispatcher
- [ ] Detection probes `gh` then `glab`, falls back to URL sniffing, caches via `$PRTEND_FORGE`
- [ ] Readiness returns the documented 0/1/3 exit codes per forge
- [ ] Lib sources without side effects under a minimal `PATH`
- [ ] One commit on a feature branch: `feat(forge): add detection and readiness lib`
