# prtend

Tend your PR while you pretend you're not procrastinating. Subscribes to CI and review events after a push, fixes what can be fixed, resolves review comments deterministically.

**Pre-release notice:** prtend is in early design and not yet usable. The repository currently contains design documents only — no shipping code. See [docs/overview.md](docs/overview.md) for the project overview and links to the rest of the design notes.

## Development

The repo ships a Nix flake devShell with `bash`, `jq`, `gh`, `glab`, `git`, `shellcheck`, and `pre-commit`:

```bash
nix develop          # or: direnv allow
pre-commit install
pre-commit run --all-files
```
