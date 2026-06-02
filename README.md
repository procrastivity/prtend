# prtend

Tend your PR while you pretend you're actually still there. Subscribes to CI and review events after a push, fixes what can be fixed, resolves review comments deterministically.

**Pre-release notice:** prtend is in early development and not yet usable end-to-end. The repository ships design documents plus an initial CLI dispatcher and core helper library; subcommands are being built step-by-step. See [docs/overview.md](docs/overview.md) for the project overview and [docs/build-steps.md](docs/build-steps.md) for the build plan.

## Development

The repo ships a Nix flake devShell with `bash`, `jq`, `gh`, `glab`, `git`, `shellcheck`, and `pre-commit`:

```bash
nix develop          # or: direnv allow
pre-commit install
pre-commit run --all-files
```
