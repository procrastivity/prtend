# Claude conventions for working on prtend

This repo is the source for the `prtend` CLI and its companion Claude Code skill. Design decisions and the full workflow spec live in `docs/`; start there before editing code.

- `docs/overview.md` — source of truth for the workflow (trigger model, watch session, CI loop, comment decision tree)
- `docs/repo-bootstrap.md` — repo layout, CLI surface, distribution
- `docs/cli-contract.md` — subcommand reference
- `docs/skill-prompts.md` — SKILL.md content and decision logic
- `docs/forge-mapping.md` — gh ↔ glab terminology and command table
- `docs/steps/` — sequenced build steps

## Conventions

- Bash 4.4+ target. `set -euo pipefail` in every script.
- Subcommands are hyphenated externally (`pr-open`) and underscored internally (`pr_open.bash`, `prtend_cmd_pr_open`).
- All forge-specific (`gh`/`glab`) calls live in `lib/prtend/prtend-forge-lib.bash`. No other file shells out to `gh` or `glab`.
- The CLI never calls an LLM. All judgment lives in the skill.
- Pre-commit hooks must pass before commit; use `nix develop` for the toolchain.

## When in doubt

Re-read `docs/overview.md` and `docs/repo-bootstrap.md`. If something is ambiguous, surface the ambiguity instead of guessing.
