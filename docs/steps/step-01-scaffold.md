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
