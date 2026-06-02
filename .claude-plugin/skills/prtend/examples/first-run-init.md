User: I just pushed to feature/widget-layout. What's the state of the PR?

[Claude runs prtend detect]
> {"forge":"github","branch":"feature/widget-layout","pr":123,"pr_state":"open","is_default_branch":false}

[Claude runs prtend config show]
> exit 4 — no config for this repo

Claude: You have an open PR (#123) on this branch. Quick first-time setup before I start watching — won't take long.

[Claude uses ask_user_input with first-run-init: system reviewers]

User: GitHub Copilot

[Claude follows up with optional reviewers free-text]

User: alice, bob

[Claude uses ask_user_input with first-run-init: watch strategy]

User: Block in this session

[Claude uses ask_user_input with first-run-init: write target]

User: User config ($XDG_CONFIG_HOME)

[Claude runs prtend config init --system-reviewer copilot \
  --optional-reviewer alice --optional-reviewer bob \
  --watch-strategy blocking --write-target xdg]
> {"written_to":"/home/beau/.config/prtend/owner-repo.yml", ...}

Claude: Config saved. Now watching PR #123.

[Claude runs prtend watch --pr 123 --block --timeout 300]
> ...
