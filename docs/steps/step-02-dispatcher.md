# Step 02 — Dispatcher and core lib

## Context

Build the thin dispatcher and the shared helpers every subcommand uses. After this step, `prtend --help` and `prtend --version` work; subcommands don't exist yet but the framework for adding them does. See `../repo-bootstrap.md` § "Dispatcher" and § "Config — handled in `prtend-lib.bash`".

## Prerequisites

- Step 01 (`scaffold`) complete — directory tree and tooling in place.

## Goal

After this step:

- `bin/prtend --help` prints usage listing all subcommands (even those not yet implemented) and exits 0.
- `bin/prtend --version` prints `prtend 0.1.0` and exits 0.
- `bin/prtend <unknown-subcommand>` exits 2 with a usage hint on stderr.
- `lib/prtend/prtend-lib.bash` exports logging helpers (`prtend_log_info`, `prtend_log_warn`, `prtend_log_error`), config-resolution functions, and atomic-write helpers used by every later step.

## Files to create or modify

- `bin/prtend` (NEW, executable)
- `lib/prtend/prtend-lib.bash` (NEW)

## Implementation

### `bin/prtend`

Exact content from `../repo-bootstrap.md` § "Dispatcher". The case statement lists every subcommand from the spec — `detect`, `pr-open`, `ci-watch`, `reviews-poll`, `watch`, `note-post`, `defer-write`, `config`, `doctor`. Each subcommand source file is loaded lazily when invoked.

Until later steps build the subcommand files, invoking a known subcommand will fail at `source "$PRTEND_LIB/prtend-subcommands/${fn}.bash"`. This is expected — the dispatcher is "done" when `--help` and `--version` work and unknown subcommands exit 2.

Make the file executable: `chmod +x bin/prtend`.

### `lib/prtend/prtend-lib.bash`

Functions to provide:

```bash
prtend_version()               # echoes "0.1.0"
prtend_usage()                 # prints help text to stdout

prtend_log_info()              # echoes to stderr, with "info: " prefix if --verbose
prtend_log_warn()              # echoes to stderr, with "warn: " prefix
prtend_log_error()             # echoes to stderr, with "error: " prefix

prtend_config_resolve()        # walks the resolution chain, prints the active config path
prtend_config_get <key>        # prints value or empty
prtend_repo_slug()             # derives "<owner>-<repo>" from `git remote get-url origin`

prtend_atomic_write <path>     # reads from stdin, writes via temp + rename
prtend_state_dir()             # returns the state directory path per config location

prtend_json_get <jq-expr>      # convenience wrapper around `jq -r`
```

Config resolution chain order: `$PRTEND_CONFIG` → `$XDG_CONFIG_HOME/prtend/<slug>.yml` → `<repo>/.claude/pr-reviewers.yml` → empty defaults. See `../repo-bootstrap.md` § "Config".

### Key decisions

- **No subcommand implementations yet.** This step builds infrastructure only.
- **Functions echo to stdout vs stderr deliberately.** Logging helpers always go to stderr. Data goes to stdout. Mixing breaks JSON-parsing callers.
- **`prtend_atomic_write` is the single point** where files get written. State files, config files, and defer docs all go through it. Never use direct `>` redirect for writes.
- **The dispatcher trusts the subcommand file naming convention.** External `pr-open` → internal `pr_open.bash` → function `prtend_cmd_pr_open`. Don't deviate.

## Verification

```bash
shellcheck bin/prtend lib/prtend/prtend-lib.bash
# → no output, exit 0

bin/prtend --help
# → prints multi-line usage to stdout including all 9 subcommand names; exit 0

bin/prtend --version
# → "prtend 0.1.0"; exit 0

bin/prtend bogus-subcommand
# → "prtend: unknown subcommand 'bogus-subcommand'" on stderr, exit 2

bin/prtend
# → prints usage; exit 0
```

## Done

- [ ] `bin/prtend` exists and is executable
- [ ] `lib/prtend/prtend-lib.bash` exists with all functions listed above
- [ ] All verification commands behave as expected
- [ ] `shellcheck` clean
- [ ] One commit on a feature branch: `feat(cli): add dispatcher and core lib`
