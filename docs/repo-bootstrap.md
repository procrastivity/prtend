# `prtend` — Repo Bootstrap

> Reference doc. Read `overview.md` first for the workflow spec (trigger model, watch session, CI loop, comment decision tree, note templates). This doc specs the repo layout, CLI surface, distribution, and CI for `prtend`.

Models the hybrid of [direnv-session-loader](https://github.com/procrastivity/direnv-session-loader) (plugin scaffolding + Nix flake) and [clast](https://github.com/procrastivity/clast) (CLI bins + lib + skill), pared down where the heavier scaffolding doesn't earn its keep at v0.

---

## Naming and scope

`prtend` ships two artifacts from one repo:

1. **A CLI** (`prtend`) that does all the deterministic forge work — detecting `gh` vs `glab`, opening PRs, polling CI, fetching review batches, posting resolution notes, writing defer docs.
2. **A Claude Code plugin** that ships one skill (`prtend`) which carries the judgment — evaluating CI failures, deciding on review comments, composing fixes.

Same principle as clast: **the CLI never calls an LLM**; all LLM work lives in the skill.

---

## Directory tree

```
prtend/
├── .claude-plugin/
│   ├── plugin.json
│   └── skills/
│       └── prtend/
│           └── SKILL.md
├── bin/
│   └── prtend                                # thin dispatcher; sources libs
├── lib/prtend/
│   ├── prtend-lib.bash                       # logging, config resolution, atomic write
│   ├── prtend-forge-lib.bash                 # gh/glab dispatch — the key abstraction
│   ├── prtend-state-lib.bash                 # subscription markers, retry counters, cursors
│   ├── prtend-notes-lib.bash                 # marker insertion + resolution-note templates
│   └── prtend-subcommands/
│       ├── detect.bash
│       ├── pr_open.bash
│       ├── ci_watch.bash
│       ├── reviews_poll.bash
│       ├── watch.bash
│       ├── note_post.bash
│       ├── defer_write.bash
│       ├── config.bash
│       └── doctor.bash
├── test/
│   ├── test-prtend.sh                        # top-level runner
│   ├── helpers.sh
│   └── fixtures/                             # mock gh/glab JSON outputs
│       ├── gh-pr-list-empty.json
│       ├── gh-pr-list-one-open.json
│       ├── gh-pr-list-closed.json
│       ├── gh-reviews-batch.json
│       ├── gh-ci-failure.json
│       ├── glab-mr-list-one-open.json
│       └── glab-mr-discussions.json
├── docs/
│   ├── overview.md                           # workflow spec from the design conversation
│   ├── cli-contract.md                       # full subcommand reference
│   ├── skill-prompts.md                      # SKILL.md content, decision logic, examples
│   ├── forge-mapping.md                      # GH↔GL term and command table
│   └── repo-bootstrap.md                     # this doc
├── examples/
│   └── pr-reviewers.yml.sample
├── flake.nix                                 # devShell only at v0; package added later
├── .envrc
├── .pre-commit-config.yaml
├── Makefile
├── README.md
├── LICENSE                                   # MIT
├── CHANGELOG.md
├── cliff.toml
├── AGENTS.md
└── CLAUDE.md
```

Distribution stack (npm, install.sh, docker, multi-bash CI matrix, large fixture trees) is deliberately omitted at v0. Add if and when it earns its place.

---

## Plugin manifest

`.claude-plugin/plugin.json`:

```json
{
  "name": "prtend",
  "version": "0.1.0",
  "description": "Tend your PR while you pretend you're not procrastinating. Subscribes to CI and review events after a push, fixes what can be fixed, resolves review comments deterministically.",
  "homepage": "https://github.com/procrastivity/prtend",
  "author": {
    "name": "Beau",
    "url": "https://github.com/procrastivity"
  },
  "license": "MIT"
}
```

Only `name` is strictly required per direnv-session-loader's reference; the rest is good-citizen metadata.

---

## Dispatcher

`bin/prtend`:

```bash
#!/usr/bin/env bash
# prtend — main dispatcher
set -euo pipefail

PRTEND_LIB="${PRTEND_LIB:-$(dirname "$(realpath "$0")")/../lib/prtend}"

# shellcheck source=lib/prtend/prtend-lib.bash
source "$PRTEND_LIB/prtend-lib.bash"

case "${1:-}" in
  detect|pr-open|ci-watch|reviews-poll|watch|note-post|defer-write|config|doctor)
    cmd="$1"; shift
    fn="${cmd//-/_}"
    # shellcheck disable=SC1090
    source "$PRTEND_LIB/prtend-subcommands/${fn}.bash"
    "prtend_cmd_${fn}" "$@"
    ;;
  -h|--help|help|"")
    prtend_usage; exit 0 ;;
  --version)
    echo "prtend $(prtend_version)"; exit 0 ;;
  *)
    echo "prtend: unknown subcommand '$1'" >&2
    prtend_usage >&2; exit 2 ;;
esac
```

Convention: subcommands are hyphenated externally (`pr-open`), underscored internally (`pr_open.bash`, `prtend_cmd_pr_open`).

---

## Subcommand cheatsheet

Full details in `docs/cli-contract.md`. One-liner each:

| Command | Purpose |
|---|---|
| `prtend detect` | Print JSON `{ forge, branch, pr, pr_state }`. The skill's first call on every invocation. |
| `prtend pr-open` | Ensure branch on remote, create PR if absent, run reviewer flow. Print resulting PR number. |
| `prtend ci-watch --pr N [flags]` | Watch CI for PR N. Emit one CI event as JSON, exit. |
| `prtend reviews-poll --pr N [flags]` | Poll review batches for PR N. Emit new batches as JSON, exit. |
| `prtend watch --pr N [flags]` | Multiplex ci-watch and reviews-poll; one event per call. |
| `prtend note-post --pr N --comment C --kind K --body B` | Post resolution note with marker to a review comment. |
| `prtend defer-write --pr N --comment C --reason R` | Write the defer Markdown doc, print its path. |
| `prtend config init\|show\|get\|set` | Manage config (first-run init, read, mutate). |
| `prtend doctor [--fix]` | Preconditions check: CLI install + auth, stale state, config readability. |

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Success (including idempotent no-ops and clean timeouts) |
| 1 | General error |
| 2 | Invalid arguments / usage |
| 3 | Missing dependency or environment problem |
| 4 | Data integrity / state issue |

---

## Block / once / timeout

`ci-watch`, `reviews-poll`, and `watch` all accept the same trio of flags:

| Flag | Behavior |
|---|---|
| `--block` (default) | Block until an event, emit one JSON line on stdout, exit 0. |
| `--once` | Emit any pending events (zero or more JSON lines), exit 0 immediately. |
| `--timeout S` | Like `--block` but bounded; exit 0 with no output if S seconds pass without an event. |

This maps cleanly to the watch strategy chosen at first-run init:

| Watch strategy | Skill invocation pattern |
|---|---|
| Blocking | `prtend watch --pr N --block` in a turn-local loop |
| Poll-on-resume | `prtend watch --pr N --once` at each agent turn start |
| Background-with-cleanup | `prtend watch --pr N --block --timeout 60` in a loop, plus a state-file marker the cleanup hook tears down |

The forge-lib doesn't need to know which mode the skill is in — it implements the polling primitive once, and the subcommand wraps it with the flag handling.

---

## Forge abstraction — `prtend-forge-lib.bash`

The only place that knows about `gh` vs `glab`. Every other module calls forge functions; forge functions dispatch internally based on `prtend_forge_detect`.

### Detection and readiness

```bash
prtend_forge_detect()
  # Print "github" | "gitlab" | "" (exit 1 if neither)
  # Order: try `gh repo view` then `glab repo view`; cache in $PRTEND_FORGE

prtend_forge_cli_ready()
  # Verify the active forge CLI is installed and authenticated.
  # Exit 0 ready, 3 missing dep, 1 not authed.
```

### Branch and PR

```bash
prtend_forge_current_branch()
  # `git rev-parse --abbrev-ref HEAD` (forge-agnostic; lives here for cohesion)

prtend_forge_pr_for_branch <branch>
  # Print PR/MR number for the branch, or empty.
  # Exit 0 found, 1 none, 2 multiple (refuse-and-surface case)

prtend_forge_pr_state <pr>
  # Print "open" | "closed" | "merged" | "draft"

prtend_forge_push_branch <branch>
  # Push with upstream tracking. Pure git — same on both forges.

prtend_forge_pr_create <branch> [--title T] [--body B] [--draft]
  # Create PR/MR. Print the new PR number.
```

### Reviewers

```bash
prtend_forge_add_reviewer <pr> <login>
prtend_forge_list_reviewers <pr>      # JSON list
```

### CI

```bash
prtend_forge_ci_status <pr>
  # JSON: { state, checks: [{ name, conclusion, url }] }

prtend_forge_ci_failures <pr>
  # JSON list of failure objects: { check_name, conclusion, log_url, summary }

prtend_forge_ci_wait <pr> [--timeout S]
  # Block until CI state changes. Emit one event as JSON on change.
  # gh: leverage `gh pr checks --watch` underneath
  # glab: poll `glab ci status` at PRTEND_POLL_INTERVAL (default 15s)
```

### Reviews

```bash
prtend_forge_reviews_since <pr> <cursor>
  # JSON list of review batches submitted after cursor.
  # cursor is opaque: gh = review ID, glab = ISO timestamp.

prtend_forge_review_comments <pr> <review-id>
  # JSON list of comments in a review batch.

prtend_forge_comment_body <pr> <comment-id>
  # Raw body of one comment. Used by the skill to detect existing marker.
```

### Posting

```bash
prtend_forge_post_review_reply <pr> <comment-id> <body>
  # Reply to a review comment thread. Does NOT resolve the thread (per spec).
```

There is intentionally no `prtend_forge_resolve_thread`. Humans confirm; the agent never marks resolved.

### Internal dispatch helper

```bash
prtend_forge_dispatch <function-suffix> "$@"
  # Reads $PRTEND_FORGE and calls _gh_<suffix> or _gl_<suffix>.
  # Each public function above is a one-liner that calls this.
```

Pattern: every public `prtend_forge_X` has private siblings `prtend_forge_gh_X` and `prtend_forge_gl_X`. The dispatcher picks based on detection. This keeps the gh/glab branching localized — every forge-specific call lives in exactly one named function.

---

## Notes & marker — `prtend-notes-lib.bash`

Marker (idempotency signal — the skill scans for this to know a comment has been handled):

```
<!-- prtend: handled v1 -->
```

Template functions render to stdout:

```bash
prtend_note_reject  <reason>          # → "Resolution: Reject — <reason>"
prtend_note_accept  <commit-hash>     # → "Resolution: Accept — fixed in <hash>"
prtend_note_halt    <reason>          # → "Resolution: Halt — <reason>; no further work pending research"
prtend_note_defer   <doc-path>        # → "Resolution: Defer — tracked at <path>"
```

Each prepends the marker. Full body shape:

```
<!-- prtend: handled v1 -->
Resolution: Accept — fixed in 4f7a2c1
```

Detection:

```bash
prtend_note_is_handled <comment-body>
  # grep for marker. Exit 0 if present, 1 if not.
```

`note-post` subcommand composition:

```
prtend note-post --pr N --comment C --kind {reject|accept|halt|defer} \
  [--reason R] [--commit H] [--doc P]
```

Validates kind/parameter pairing, renders body, calls `prtend_forge_post_review_reply`. `--kind ignore` is not a valid input — Ignore by definition posts no note.

---

## State — `prtend-state-lib.bash`

State files live alongside config, in a directory chosen at first-run init:

- If config is at `<repo>/.claude/pr-reviewers.yml` → state at `<repo>/.claude/prtend-state/<pr>.json`
- If config is at `$XDG_CONFIG_HOME/prtend/<repo-slug>.yml` → state at `$XDG_STATE_HOME/prtend/<repo-slug>/<pr>.json`

State file shape:

```json
{
  "pr": 123,
  "forge": "github",
  "subscribed_at": "2026-05-31T19:42:00Z",
  "ci_attempts": {
    "jest:reducer-spec:NaN-NaN": 1,
    "eslint:src-utils-time:no-unused-vars": 2
  },
  "last_review_cursor": "RR_kwDOAbc123",
  "last_review_at": "2026-05-31T19:48:13Z"
}
```

Functions:

```bash
prtend_state_path <pr>                              # absolute path for the PR's state file
prtend_state_read <pr>                              # print JSON, empty if absent
prtend_state_write <pr> <json>                      # atomic write via temp + rename
prtend_state_increment_ci_attempt <pr> <signature>
prtend_state_ci_attempts <pr> <signature>           # print count
prtend_state_set_cursor <pr> <cursor>
prtend_state_get_cursor <pr>                         # print cursor, empty if first poll
prtend_state_clear <pr>                              # for PR close / explicit halt
```

CI signature format is `<tool>:<scope>:<short-rule>` — stable enough that successive failures of the same kind increment a counter, distinct enough that unrelated failures get independent counters.

---

## Config — handled in `prtend-lib.bash`

Resolution chain (first hit wins):

1. `$PRTEND_CONFIG` env override
2. `$XDG_CONFIG_HOME/prtend/<repo-slug>.yml`
3. `<repo>/.claude/pr-reviewers.yml`
4. Built-in defaults (empty)

Config file shape (`examples/pr-reviewers.yml.sample`):

```yaml
# prtend config for <repo-slug>
system_reviewers:
  - copilot
optional_reviewers:
  - alice
  - bob
watch_strategy: blocking           # blocking | poll-on-resume | background
poll_interval_seconds: 15
ci_retry_limit: 3
```

`prtend config init` interactively prompts for each key, capability-pruning the watch-strategy options based on which forge CLI is detected. The chosen target slot in the resolution chain is also asked at init.

Env var overrides for every key: `PRTEND_WATCH_STRATEGY`, `PRTEND_POLL_INTERVAL_SECONDS`, `PRTEND_CI_RETRY_LIMIT`, etc.

---

## SKILL.md stub

`.claude-plugin/skills/prtend/SKILL.md` — frontmatter and skeleton; full body in `docs/skill-prompts.md`:

```markdown
---
name: prtend
description: When the user pushes commits to a branch with an open PR, or asks to submit a PR/MR, watches the resulting PR for CI events and review comments. Auto-fixes fixable CI failures (up to 3 attempts per signature, then escalates), evaluates review comments using the Reject/Accept/Ignore/Ask decision frame, and posts resolution notes. Use whenever the user runs `git push`, says "submit a PR", "open a PR", "commit and push", or similar.
---

# prtend

prtend automates the post-push lifecycle of a PR: subscribe to CI and review events, fix what can be fixed, resolve review comments with explicit notes. Never marks threads resolved — humans confirm.

## When this skill applies

[Decision rules from `docs/overview.md` truth table.]

## CLI reference

All deterministic work goes through `prtend`. The skill never invokes `gh` or `glab` directly:

- `prtend detect` — current forge, branch, and PR state
- `prtend pr-open` — push if needed, create PR, run reviewer flow
- `prtend watch --pr N --block` — block for one event (CI or review batch), return JSON
- `prtend note-post --pr N --comment C --kind K …` — post resolution note
- `prtend defer-write --pr N --comment C --reason R` — write defer doc, print path

[Full CLI mapping in `docs/cli-contract.md`.]

## Entry decision

[Truth table from `docs/overview.md`.]

## Watch loop

[Block-emit-loop pattern; how the skill interprets event JSON.]

## CI failure handling

[Inspect → fixable? → fix + commit + push, or escalate. 3-retry cap per signature.]

## Review comment handling

[Per-comment Reject/Accept/Ignore/Ask; Ask resolution to {Reject, Accept, Ignore, Halt, Defer}; note posting; never resolve threads.]

## Note templates

[Marker `<!-- prtend: handled v1 -->`, body shapes per kind.]
```

---

## Distribution

### Nix flake (v0: devShell only)

```nix
{
  description = "prtend — Claude Code plugin to tend your PRs";
  inputs.nixpkgs.url     = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system}; in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.bash
            pkgs.jq
            pkgs.gh
            pkgs.glab
            pkgs.git
            pkgs.shellcheck
            pkgs.pre-commit
          ];
        };
      });
}
```

Package output (with `pkgs.makeWrapper` baking `PRTEND_LIB` and adding `gh`, `glab`, `jq` to PATH) is added later — same pattern as clast's stage-2 flake.

### Marketplace

Register `prtend` in the `procrastivity` org's marketplace repo alongside `clast` and `direnv-session-loader`. Plugin install via `claude plugin install prtend@procrastivity`.

---

## Tooling files

`.envrc`:

```bash
use flake
PATH_add bin
```

`.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/koalaman/shellcheck-precommit
    rev: v0.9.0
    hooks:
      - id: shellcheck
        files: '\.(sh|bash)$'
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.5.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-json
```

`Makefile`:

```makefile
.PHONY: test lint clean

test:
	./test/test-prtend.sh

lint:
	shellcheck bin/prtend lib/prtend/*.bash lib/prtend/prtend-subcommands/*.bash test/*.sh

clean:
	rm -rf .test-tmp result result-*
```

`cliff.toml`: standard git-cliff config with conventional commits (matches `clast` and `direnv-session-loader`).

---

## Test strategy

`test/test-prtend.sh` runs each subcommand end-to-end against mock forge outputs in `test/fixtures/`. Each subcommand gets one focused test that:

1. Sets `PRTEND_FORGE=github` (or `gitlab`).
2. Stubs `gh` / `glab` via `PATH` prepend pointing at a fake CLI that reads its expected response from the fixture matching the invocation.
3. Asserts the subcommand's stdout JSON against an expected shape.
4. For state-mutating subcommands (`note-post`, `defer-write`), asserts the resulting state-file contents.

Tests run against `bash 5.x` only at v0; matrix expansion is post-v0.

---

## Suggested build order

Each step is its own commit so progress is visible and reviewable:

1. **Repo scaffold** — directory tree, README, LICENSE, CLAUDE.md, `.envrc`, `.gitignore`, `.editorconfig`, `flake.nix` devShell, pre-commit config.
2. **Dispatcher + core lib** — `bin/prtend` with `--help` and `--version` working; `lib/prtend/prtend-lib.bash` with logging, config-resolution, atomic-write.
3. **Forge lib (detection only)** — `prtend_forge_detect`, `prtend_forge_cli_ready`; `prtend detect` subcommand. Verify against both `gh` and `glab` in your real repos.
4. **Forge lib (read-only forge ops)** — `pr_for_branch`, `pr_state`, `ci_status`, `reviews_since`, `review_comments`, `comment_body`. No mutations yet.
5. **State lib** — full read/write of `prtend-state/<pr>.json`, cursor + counter functions.
6. **Notes lib + `note-post`** — marker, templates, idempotency check, post-reply call.
7. **Watch primitives** — `ci-watch`, `reviews-poll`, `watch` with all three flag modes.
8. **Config subcommand + first-run init** — interactive prompts with capability detection.
9. **Forge lib (mutations)** — `pr_create`, `add_reviewer`, `push_branch`; `pr-open` subcommand.
10. **Defer + doctor** — `defer-write`, `doctor` (preconditions, stale-state cleanup).
11. **SKILL.md** — flesh out the stub against the now-locked CLI surface.
12. **Test harness + fixtures** — `test/test-prtend.sh`, mock CLIs, fixture set.
13. **Marketplace registration** — add `prtend` to the `procrastivity` marketplace entry.

Steps 1–6 give you a usable foundation for the skill even before the watch primitives land; the skill could be developed against the read-only CLI first to validate the interface shape, then extended as more subcommands ship.

---

## Open decisions

| # | Question | Default |
|---|---|---|
| 1 | Single dispatcher vs separate bins | Single (resolved) |
| 2 | Test framework | Handwritten bash (matches clast and direnv-session-loader) |
| 3 | Config format | YAML (matches existing pr-reviewers.yml convention) |
| 4 | License | MIT |
| 5 | Initial version | 0.1.0 |
| 6 | Bash version target | 4.4+ (assoc arrays, mapfile) — same line as clast |
| 7 | First distribution channels | Nix flake devShell + procrastivity marketplace |
| 8 | `pr-open` title/body composition | Out of scope; the agent/user supplies title and body via flags |
| 9 | Auto-trigger hook on push | Deferred post-v0; skill is manually invoked first |
| 10 | Forges beyond `gh` / `glab` | Out of scope for v1 |
| 11 | Repo slug derivation | `git remote get-url origin` → sanitize `<owner>/<repo>` → `<owner>-<repo>` |
| 12 | What counts as "the same CI failure signature" | `<tool>:<scope>:<short-rule>` — to be refined as real failures land |
