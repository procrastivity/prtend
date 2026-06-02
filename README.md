# prtend — Claude Code plugin

Tend your PR while you pretend you're actually still there. Subscribes to CI
and review events after a push, fixes what can be fixed, and resolves review
comments deterministically.

**Pre-release notice:** prtend is in early development and not yet usable
end-to-end. The repository ships design documents plus an initial CLI
dispatcher and core helper library; subcommands are being built step-by-step.
See [docs/overview.md](docs/overview.md) for the project overview and
[docs/build-steps.md](docs/build-steps.md) for the build plan.

## Install

This plugin is distributed through the
[procrastivity](https://github.com/procrastivity/claude-plugins) marketplace.

### From within Claude Code

Add the marketplace (if not already added).

```
/plugin marketplace add procrastivity/claude-plugins
```

Install the plugin.

```
/plugin install prtend@procrastivity
```

### From the command line

Add the marketplace (if not already added).

```
claude plugin marketplace add procrastivity/claude-plugins
```

Install the plugin.

```
claude plugin install prtend@procrastivity
```

## Update

Refresh the marketplace to pull in the latest version.

### From within Claude Code

```
/plugin marketplace update procrastivity
```

### From the command line

```
claude plugin marketplace update procrastivity
```

## Development

The repo ships a Nix flake devShell with `bash`, `jq`, `gh`, `glab`, `git`,
`shellcheck`, and `pre-commit`:

```bash
nix develop          # or: direnv allow
pre-commit install
pre-commit run --all-files
```

## License

MIT. See [LICENSE](LICENSE).
