# `prtend` — Build Steps (meta)

> Reference doc. Read `overview.md` for workflow, `repo-bootstrap.md` for layout, `cli-contract.md` for CLI shape, `forge-mapping.md` for forge translations, `skill-prompts.md` for skill content.

This doc is the **meta** for generating self-executing `step-NN.md` build prompts that live in `docs/steps/`. Each step file is a complete, scoped prompt that an agent (or focused human session) can read and execute end-to-end without needing the rest of this doc set in working memory — it pulls what it needs by reference.

The pattern matches clast's `build-steps.md`. The goal is that a green-field agent run, handed `step-01-scaffold.md`, can produce a usable scaffold commit and stop. Handed `step-02-dispatcher.md` next, it produces a working dispatcher and stops. And so on, until the project is built.

---

## Why step files

Three reasons over a single monolithic plan:

1. **Bounded context.** Each step has narrow scope; an agent doesn't need to load 30k tokens of design docs to make one commit.
2. **Stop points.** Steps are commit-sized. Visible progress on the git log; each step is reviewable and reversible in isolation.
3. **Repeatable.** If a step's output isn't right, re-run that one step. No "re-do everything from scratch."

A step file is therefore not "advice on how to build X" but a directive: here's the goal, here are the files to create, here's how you know you're done.

---

## Step file conventions

### Naming

```
docs/steps/step-NN-<short-slug>.md
```

Two-digit zero-padded number; short slug describing the step. Examples:

- `step-01-scaffold.md`
- `step-02-dispatcher.md`
- `step-09-forge-mutations.md`

Numbers don't have to be contiguous if a step is later inserted or split, but stay monotonic.

### Required sections

Every step file has these sections, in this order:

```markdown
# Step NN — <title>

## Context
[1–3 sentences. What this step contributes to the project. Pointer to the relevant docs for source-of-truth.]

## Prerequisites
[List of earlier steps that must be complete. State explicitly which files from earlier steps this step reads or builds on.]

## Goal
[A single short paragraph or bullet list: what exists when this step is done that didn't exist before.]

## Files to create or modify
[Path-by-path list with one line each. New files marked NEW; modified files marked MODIFY. No content yet.]

## Implementation
[The substance. Code skeletons, key design decisions, gotchas, what NOT to do. Reference the canonical docs (`cli-contract.md`, `forge-mapping.md`) for shapes rather than re-stating them.]

## Verification
[Concrete commands the agent runs to confirm the step worked. Each command's expected outcome stated explicitly. Include shellcheck, manual smoke tests, and any structural assertions.]

## Done
[Checklist of binary done/not-done conditions. The step is complete iff every box is checked.]
```

### What does NOT belong in a step file

- **Re-stated design rationale.** Reference the relevant doc instead. If a step needs to explain *why* the marker is `<!-- prtend: handled v1 -->`, point at `overview.md`.
- **Full CLI specs.** Reference `cli-contract.md`. Step files give the agent enough to implement; the doc has the contract.
- **Cross-step refactoring.** Each step lands its own changes. If implementing step N reveals a problem in step M, fix M in a follow-up commit, don't tangle them.
- **Speculative work.** If a step file mentions "and while you're at it, also…", that's a separate step.

### What an agent should expect

- Read the step file.
- Read the linked sections of the referenced docs.
- Implement.
- Run the verification commands.
- Commit when the Done checklist is satisfied.
- Stop. Don't proceed to step N+1 in the same session.

---

## Step file template

A blank template a step file can be filled in from. Save as `docs/steps/_template.md`:

```markdown
# Step NN — <title>

## Context

<1–3 sentences placing this step in the project. Link to relevant docs:>
- See `../overview.md` § "<section>"
- See `../cli-contract.md` § "<subcommand>"
- See `../forge-mapping.md` § "<operation>"

## Prerequisites

- Step NN-1 (`<slug>`) complete
- Step NN-2 (`<slug>`) complete (provides `<lib or fn>`)
- Local: `bash 4.4+`, `jq`, `gh` and/or `glab` for smoke tests

## Goal

After this step:

- `<artifact 1>` exists and `<behavior>`
- `<artifact 2>` exists and `<behavior>`

## Files to create or modify

- `path/to/new/file` (NEW)
- `path/to/existing/file` (MODIFY)

## Implementation

### `path/to/new/file`

<Skeleton, key functions, gotchas. Show enough that the agent can fill in
the rest from the referenced doc; don't reproduce the full file unless
it's small and self-contained.>

### Key decisions

<Things the agent must NOT do, or specific design choices that need to be respected.>

## Verification

```bash
# Each command with expected outcome.
shellcheck bin/prtend lib/prtend/*.bash
# → no output, exit 0

bin/prtend --help
# → prints usage; exit 0

bin/prtend --version
# → prints "prtend 0.1.0"; exit 0
```

## Done

- [ ] Files exist at the paths above
- [ ] All verification commands pass
- [ ] `git status` shows only the intended changes
- [ ] One commit on a feature branch, conventional-commits format
```

---

## Step inventory

Thirteen steps. Each row links to the file under `docs/steps/`. Status column tracks progress.

| # | Slug | Depends on | Summary | Status |
|---|---|---|---|---|
| 01 | `scaffold` | — | Directory tree, `README.md`, `LICENSE`, `.gitignore`, `.editorconfig`, `.envrc`, `flake.nix` devShell, `.pre-commit-config.yaml`, `Makefile`, `CLAUDE.md`, `AGENTS.md` | TODO |
| 02 | `dispatcher` | 01 | `bin/prtend` with `--help` / `--version`; `lib/prtend/prtend-lib.bash` with logging, config resolution, atomic-write helpers | TODO |
| 03 | `forge-detect` | 02 | `prtend_forge_detect`, `prtend_forge_cli_ready`, `prtend_forge_current_branch` in `prtend-forge-lib.bash` | TODO |
| 04 | `forge-read` | 03 | Read-only forge ops: `pr_for_branch`, `pr_state`, `ci_status`, `ci_failures`, `reviews_since`, `review_comments`, `comment_body` | TODO |
| 05 | `state` | 02 | `prtend-state-lib.bash` — state-file read/write, cursor and per-signature retry counter functions | TODO |
| 06 | `notes` | 02 | `prtend-notes-lib.bash` — marker constant, template renderers, `prtend_note_is_handled` | TODO |
| 07 | `detect-subcmd` | 03, 04 | `prtend detect` subcommand emitting the canonical JSON from `cli-contract.md` | TODO |
| 08 | `watch-primitives` | 04, 05 | `ci-watch`, `reviews-poll`, `watch` subcommands with `--block` / `--once` / `--timeout` flags | TODO |
| 09 | `forge-mutations` | 04 | `push_branch`, `pr_create`, `add_reviewer`, `post_review_reply` in `prtend-forge-lib.bash` | TODO |
| 10 | `note-post-and-pr-open` | 06, 09 | `note-post` and `pr-open` subcommands | TODO |
| 11 | `defer-and-doctor` | 04, 05, 09 | `defer-write` and `doctor` subcommands | TODO |
| 12 | `config-subcmd` | 02 | `config init/show/get/set/path` subcommand | TODO |
| 13 | `skill-and-marketplace` | 07, 08, 10, 11, 12 | `.claude-plugin/skills/prtend/SKILL.md` and reference files; marketplace registration | TODO |

Test fixtures and a basic test harness get built incrementally — each subcommand step adds the fixture files and a focused test for that subcommand to `test/`. A standalone "test harness" step isn't needed if each subcommand step includes its own tests.

### Dependency notes

- Step 05 (`state`) is independent of forge work and could be done in parallel with steps 03–04 if you wanted to fan out. Keeping it sequential keeps the git log linear.
- Step 06 (`notes`) builds only the lib — no posting. The CLI subcommand `note-post` lands in step 10 once mutations exist.
- Step 08 (`watch-primitives`) is the largest single step in surface area. If it grows unwieldy, split into 08a (`ci-watch`), 08b (`reviews-poll`), 08c (`watch` multiplexer). The `cli-contract.md` shapes are the same for all three.
- Step 13 lands SKILL.md last so it's written against the fully-locked CLI surface. Don't write SKILL.md against a partial CLI — the result drifts.

### Order differs slightly from `repo-bootstrap.md`

The bootstrap doc lists 13 steps in a slightly different order — specifically, it groups "Notes lib + note-post" as a single step, which creates a dependency on mutations not yet built. This doc's order separates the notes lib (step 06, lib only) from the note-post subcommand (step 10, after mutations land). When the docs disagree, this doc is the working build plan; the bootstrap is the structural reference.

---

## Worked example: `step-01-scaffold.md`

This is what the first step file looks like fully written out. Use it as the pattern for the rest.

```markdown
# Step 01 — Scaffold

## Context

Bootstrap the empty repo with directory tree, license, tooling files, and a working Nix devShell. No prtend code yet — just the floor everything else stands on. See `../repo-bootstrap.md` § "Directory tree".

## Prerequisites

None. This is the first step.

Required on the host: `nix` with flakes enabled (or willingness to skip the devShell verification), `git`.

## Goal

After this step:

- The repo has the full directory tree from `repo-bootstrap.md`, with empty placeholder files where appropriate.
- `nix develop` (or `direnv allow`) drops into a shell with `bash`, `jq`, `gh`, `glab`, `git`, `shellcheck`, and `pre-commit` on PATH.
- `pre-commit install` succeeds and the hooks run cleanly on the empty repo.
- A `README.md` exists with a one-paragraph project description and a "this is pre-release" warning.

## Files to create or modify

- `.claude-plugin/plugin.json` (NEW)
- `.claude-plugin/skills/prtend/.gitkeep` (NEW)
- `bin/.gitkeep` (NEW)
- `lib/prtend/.gitkeep` (NEW)
- `lib/prtend/prtend-subcommands/.gitkeep` (NEW)
- `test/.gitkeep` (NEW)
- `test/fixtures/.gitkeep` (NEW)
- `docs/.gitkeep` (NEW) — once the design docs land, the .gitkeep is removed
- `examples/.gitkeep` (NEW)
- `.envrc` (NEW)
- `.gitignore` (NEW)
- `.gitattributes` (NEW)
- `.editorconfig` (NEW)
- `.pre-commit-config.yaml` (NEW)
- `flake.nix` (NEW)
- `Makefile` (NEW)
- `README.md` (NEW)
- `LICENSE` (NEW)
- `CHANGELOG.md` (NEW)
- `cliff.toml` (NEW)
- `CLAUDE.md` (NEW)
- `AGENTS.md` (NEW)

## Implementation

### `.claude-plugin/plugin.json`

Exact content from `../repo-bootstrap.md` § "Plugin manifest". Required field is `name`; the rest is good-citizen metadata.

### `flake.nix`

Exact content from `../repo-bootstrap.md` § "Distribution" → "Nix flake (v0: devShell only)". Only `devShells.default` at this stage; `packages.default` is deferred.

### `.envrc`

```
use flake
PATH_add bin
```

### `.gitignore`

```
# Local config / runtime
.test-tmp/
result
result-*
.direnv/

# State (when in-repo)
.claude/prtend-state/

# Editor
*.swp
.idea/
.vscode/

# OS
.DS_Store
Thumbs.db
```

### `.editorconfig`

Standard: 2-space indents, LF, UTF-8, trim trailing whitespace, insert final newline. Tab indents for `Makefile`. Reference: `../repo-bootstrap.md` § "Tooling files".

### `.pre-commit-config.yaml`

Exact content from `../repo-bootstrap.md` § "Tooling files".

### `Makefile`

Exact content from `../repo-bootstrap.md` § "Tooling files".

### `README.md`

One paragraph project description and pre-release warning. Use the description from `.claude-plugin/plugin.json`'s `description` as the lead paragraph. Add a brief "Development" section pointing at the Nix devShell.

### `LICENSE`

MIT, attributed to Beau (or whatever name the user prefers — check `.claude-plugin/plugin.json` author).

### `CLAUDE.md` and `AGENTS.md`

Short files (≤30 lines each) for coding agents working *on* prtend. Point at the docs:

- `CLAUDE.md`: Claude-specific conventions for editing the repo.
- `AGENTS.md`: model-neutral version of the same.

Both reference `docs/overview.md` as the source of truth for design decisions.

### `cliff.toml`

Standard git-cliff config with conventional-commits parsing. Start from cliff's `examples/changelog/cliff.toml`.

### Key decisions

- **Placeholder `.gitkeep` files** in `bin/`, `lib/prtend/`, etc. let the directories exist before later steps populate them. Remove `.gitkeep` files in the same commit that adds real files to the directory.
- **No code yet.** This step is purely structural. If you find yourself writing `bin/prtend`, stop and save it for step 02.
- **`docs/` will be populated separately** by the design docs themselves (`overview.md`, `repo-bootstrap.md`, etc.). Leave it empty (with a `.gitkeep`) at this stage; the docs land as a follow-up commit or via a separate process.

## Verification

```bash
# Tree check — should match the spec
find . -type d -not -path './.git*' | sort
# → all directories from the spec, no extras

# Pre-commit hooks run cleanly
pre-commit install
pre-commit run --all-files
# → all hooks pass (trivially, on an empty/scaffolded repo)

# Nix devShell works
nix develop --command bash -c 'which gh glab jq shellcheck'
# → prints four paths, all under /nix/store/

# direnv works (if installed)
direnv allow
echo "$PATH" | tr ':' '\n' | grep prtend
# → includes ./bin (from PATH_add bin)

# Plugin manifest validates
nix develop --command claude plugin validate . --strict
# → "Plugin is valid" (or equivalent success message)
# Note: `claude` may not be in the devShell; run this from your normal env if so.
```

## Done

- [ ] Full directory tree matches `repo-bootstrap.md` § "Directory tree"
- [ ] All tooling files (`.envrc`, `.gitignore`, `.editorconfig`, `.pre-commit-config.yaml`, `Makefile`, `flake.nix`, `cliff.toml`) match the spec
- [ ] `README.md`, `LICENSE`, `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md` present
- [ ] `.claude-plugin/plugin.json` matches `repo-bootstrap.md` § "Plugin manifest"
- [ ] `nix develop` works and provides `gh`, `glab`, `jq`, `shellcheck`, `pre-commit`
- [ ] `pre-commit run --all-files` passes
- [ ] One commit on a feature branch: `chore: scaffold repo structure`
```

---

## Worked example: `step-02-dispatcher.md`

The second step file. Less verbose than step 01 because the pattern is now established.

```markdown
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
```

---

## Generating the remaining step files

The two worked examples establish the pattern. For steps 03–13, draft each file by:

1. **Start from the template.** Copy `_template.md` to `docs/steps/step-NN-<slug>.md`.
2. **Pull the Context section** from the corresponding paragraph in `repo-bootstrap.md` § "Suggested build order" and the relevant section of `cli-contract.md` / `forge-mapping.md`.
3. **Set Prerequisites** from the dependency table above.
4. **Set Goal** by describing what's true after the step that wasn't before — usually a small set of artifacts and their visible behaviors.
5. **List Files to create or modify** from `repo-bootstrap.md` § "Directory tree" and the implementation guidance below.
6. **Implementation** points at the source-of-truth doc for each piece. Don't reproduce specs; reference them. Include only the gotchas and design choices that aren't in the canonical doc.
7. **Verification** is concrete shell commands with expected outcomes. Each subcommand step should include a smoke test that exercises the happy path.
8. **Done** is a binary checklist.

### Per-step implementation pointers

For each remaining step, the primary reference docs and the implementation focus:

- **Step 03 (`forge-detect`)** — `forge-mapping.md` § "Detect forge from repo" and § "Authentication". Two functions, plus the dispatcher cache (`$PRTEND_FORGE`). Smoke test: run against real repos for both forges.

- **Step 04 (`forge-read`)** — `forge-mapping.md` § "Operation mapping" for each of the seven read ops. JSON shape canonicalization is the bulk of the work. Smoke tests use real PRs in test repos.

- **Step 05 (`state`)** — `repo-bootstrap.md` § "State". Six functions; all I/O goes through `prtend_atomic_write` from step 02. Test with synthetic JSON files in a tmp dir.

- **Step 06 (`notes`)** — `repo-bootstrap.md` § "Notes & marker — `prtend-notes-lib.bash`". Marker constant, four template renderers, one detection function. Pure string work; trivial unit tests.

- **Step 07 (`detect-subcmd`)** — `cli-contract.md` § "`prtend detect`". Composes step 03 + step 04 + step 05 (for state-file reads). One subcommand file. Verification asserts the JSON shape against fixtures.

- **Step 08 (`watch-primitives`)** — `cli-contract.md` §§ "`prtend ci-watch`", "`prtend reviews-poll`", "`prtend watch`". Largest step. Pay attention to flag handling (`--block` / `--once` / `--timeout`) and the GitLab discussion settle-window. Split into 08a/08b/08c if it grows past one comfortable commit.

- **Step 09 (`forge-mutations`)** — `forge-mapping.md` § "Operation mapping" for `push_branch`, `pr_create`, `add_reviewer`, `post_review_reply`. Four functions. Smoke-test against throwaway PRs in a test repo. Pay attention to draft-flag semantics on GitLab.

- **Step 10 (`note-post-and-pr-open`)** — `cli-contract.md` §§ "`prtend note-post`" and "`prtend pr-open`". Composes steps 06 + 09. Two subcommand files. Kind/flag pairing validation in `note-post` is mandatory.

- **Step 11 (`defer-and-doctor`)** — `cli-contract.md` §§ "`prtend defer-write`" and "`prtend doctor`". `defer-write` template body matches `overview.md` § "Defer documents". `doctor` checks listed in `cli-contract.md`'s "Standard checks" table.

- **Step 12 (`config-subcmd`)** — `cli-contract.md` § "`prtend config`". Sub-subcommands `init`, `show`, `get`, `set`, `path`. The `init` flow is fully flag-driven — no interactive prompts in the CLI.

- **Step 13 (`skill-and-marketplace`)** — `skill-prompts.md` for all the file contents. SKILL.md and four reference files (`ci-fixable-rubric.md`, `comment-decision-rubric.md`, `ask-options.md`, `note-templates.md`) plus four example transcripts under `examples/`. Marketplace registration is one entry in the `procrastivity` marketplace repo.

---

## Using these step files with an agent

The intended workflow is:

```
1. Open a fresh agent session in the prtend repo.
2. Hand it docs/steps/step-NN-<slug>.md.
3. Tell it: "Read this step file and any docs it references, then implement and verify. Commit when done. Stop."
4. Review the resulting commit.
5. If satisfactory: move to step NN+1 in a new session.
6. If not: provide feedback, optionally re-run the step in a fresh session.
```

Why fresh sessions per step: each step is bounded enough that a new session can complete it; reusing sessions accumulates context that's irrelevant to the next step and may pull the agent toward inconsistent choices.

If a step proves too large for one session (this is most likely with step 08), split the file: `step-08a-ci-watch.md`, `step-08b-reviews-poll.md`, `step-08c-watch.md`. Update this doc's inventory table to match.

---

## When this doc changes

The doc set is consistent when:

- The step inventory in this doc matches the files under `docs/steps/`.
- Each step file's referenced sections in the canonical docs (`overview.md`, `repo-bootstrap.md`, `cli-contract.md`, `forge-mapping.md`, `skill-prompts.md`) still exist with the expected content.
- Dependencies between steps in this doc match the file references each step makes.

When a canonical doc changes in a way that affects multiple steps, update this inventory's Status column (mark affected steps for re-review) and walk through them in order.

---

## See also

- `overview.md` — workflow spec.
- `repo-bootstrap.md` — layout, dispatcher, lib structure, build order.
- `cli-contract.md` — subcommand reference and JSON shapes.
- `forge-mapping.md` — `gh` / `glab` translations.
- `skill-prompts.md` — SKILL.md content, decision rubrics, example transcripts.
