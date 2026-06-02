# Step 13 — Skill files and marketplace registration

## Context

Land the Claude Code skill. Every prior step has been about the CLI; the CLI is now fully locked (steps 01–12 covered scaffolding, dispatcher, forge detection, read ops, state, notes, `detect`, `pr-open`, `note-post`, `defer-write`, and the `config` subcommand family). This step finally writes the thing the user actually invokes — `SKILL.md` and the reference files Claude reads on demand — and registers `prtend` in the `procrastivity` marketplace so `claude plugin install prtend@procrastivity` works end-to-end.

The skill is a content-only deliverable. There is no new bash code, no new subcommand, no new lib function — just Markdown files copied verbatim out of `../skill-prompts.md` into `.claude-plugin/skills/prtend/` and a one-entry change to the marketplace repo. The reason it lands last is precisely the reason the build-order doc gives: "SKILL.md is written against the fully-locked CLI surface; don't write it against a partial CLI — the result drifts." With step 12's `config` subcommand family in, every command SKILL.md references (`detect`, `pr-open`, `watch`, `note-post`, `defer-write`, `config show`, `config init`) now exists and matches the contract documented in `../cli-contract.md`.

See `../skill-prompts.md` for the verbatim contents of every file this step ships, `../repo-bootstrap.md` §§ "Directory tree" / "Plugin manifest" / "Marketplace" for the layout and registration target, `../overview.md` for the workflow the skill orchestrates, and `../cli-contract.md` as the authoritative reference SKILL.md links into.

## Prerequisites

- Steps 07 (`detect`), 08 (`pr-open`), 10 (`note-post`), 11 (`defer-write`), 12 (`config`) all complete — these are the five subcommands SKILL.md instructs Claude to call. The skill is correct only if their JSON shapes, flags, and exit codes match what SKILL.md says they do. (Steps 03–05, 06, 09 land lib code SKILL.md doesn't reference directly but transitively depends on; they're prerequisites to those five subcommands and so transitively prerequisites here.)
- `.claude-plugin/plugin.json` already exists from step 01 with the canonical name / version / description / author / homepage fields per `../repo-bootstrap.md` § "Plugin manifest". This step does not modify it.
- `.claude-plugin/skills/prtend/` exists but contains only `.gitkeep` (the placeholder from step 01). This step replaces the placeholder with real content.

Required on the host for smoke tests: a Claude Code install that can load a local plugin via `--plugin-dir` (or equivalent) so the skill can be sourced from this repo without going through the marketplace. The marketplace half of the step is tested separately in the `procrastivity` marketplace repo and does not gate the local skill working.

## Goal

After this step:

- `.claude-plugin/skills/prtend/SKILL.md` contains the body from `../skill-prompts.md` § "SKILL.md (ships as-is)", verbatim — frontmatter intact, headings intact, internal links intact. The frontmatter `description` field is the long trigger sentence from skill-prompts.md, not a placeholder.
- `.claude-plugin/skills/prtend/ci-fixable-rubric.md` contains the body from `../skill-prompts.md` § "`ci-fixable-rubric.md` (ships as-is)", verbatim.
- `.claude-plugin/skills/prtend/comment-decision-rubric.md` contains the body from `../skill-prompts.md` § "`comment-decision-rubric.md` (ships as-is)", verbatim.
- `.claude-plugin/skills/prtend/ask-options.md` contains the body from `../skill-prompts.md` § "`ask-options.md` (ships as-is)", verbatim.
- `.claude-plugin/skills/prtend/note-templates.md` contains the body from `../skill-prompts.md` § "`note-templates.md` (ships as-is)", verbatim.
- `.claude-plugin/skills/prtend/examples/first-run-init.md` contains the transcript from `../skill-prompts.md` § "Example transcripts" → `examples/first-run-init.md`, verbatim.
- `.claude-plugin/skills/prtend/examples/ci-fix-loop.md` contains the transcript from `../skill-prompts.md` § "Example transcripts" → `examples/ci-fix-loop.md`, verbatim.
- `.claude-plugin/skills/prtend/examples/comment-mixed-outcomes.md` contains the transcript from `../skill-prompts.md` § "Example transcripts" → `examples/comment-mixed-outcomes.md`, verbatim.
- `.claude-plugin/skills/prtend/examples/defer-flow.md` contains the transcript from `../skill-prompts.md` § "Example transcripts" → `examples/defer-flow.md`, verbatim.
- The `.gitkeep` placeholder under `.claude-plugin/skills/prtend/` is removed (the directory is no longer empty, so the keepfile is no longer load-bearing).
- The relative links inside SKILL.md to `../../../docs/overview.md`, `../../../docs/cli-contract.md`, and `../../../docs/forge-mapping.md` resolve from the SKILL.md location (i.e. clicking them in a Markdown viewer rooted at the skill file lands on the correct doc).
- The marketplace registration entry lives in the `procrastivity` org's marketplace repo (separate repo, not this one), adding `prtend` alongside `clast` and `direnv-session-loader` per `../repo-bootstrap.md` § "Marketplace". This is documented here but the change ships as a separate PR in that repo.

## Files to create or modify

- `.claude-plugin/skills/prtend/SKILL.md` (NEW)
- `.claude-plugin/skills/prtend/ci-fixable-rubric.md` (NEW)
- `.claude-plugin/skills/prtend/comment-decision-rubric.md` (NEW)
- `.claude-plugin/skills/prtend/ask-options.md` (NEW)
- `.claude-plugin/skills/prtend/note-templates.md` (NEW)
- `.claude-plugin/skills/prtend/examples/first-run-init.md` (NEW)
- `.claude-plugin/skills/prtend/examples/ci-fix-loop.md` (NEW)
- `.claude-plugin/skills/prtend/examples/comment-mixed-outcomes.md` (NEW)
- `.claude-plugin/skills/prtend/examples/defer-flow.md` (NEW)
- `.claude-plugin/skills/prtend/.gitkeep` (DELETE)
- *(Separate repo)* `procrastivity/marketplace`: add the `prtend` entry per that repo's existing convention (entry mirrors `clast`'s shape exactly — name, repo URL, version, description).

No bash, no test scripts, no lib changes, no `bin/prtend` changes, no `docs/` changes. If you find yourself touching any of those, you've drifted out of step 13's scope.

## Implementation

### Extract the canonical content

Every file written by this step is already authored in `../skill-prompts.md` inside fenced code blocks labelled "ships as-is". The implementation is a verbatim copy with three constraints:

1. **Strip the outer fence.** Each block in skill-prompts.md is wrapped in a ```` ```markdown ```` fence so it renders in the source doc. The fence is documentation packaging — do not write the fence into the destination files. The destination file's content begins with the first character inside the fence and ends with the last character before the closing ``` ` ` ` ```.
2. **Preserve every inner fence.** Some bodies (notably `note-templates.md` and the example transcripts) contain nested fenced code blocks. Those *are* content and must survive the copy.
3. **Preserve every inner link.** SKILL.md's "Reference files (read on demand)" section uses relative paths like `../../../docs/overview.md`. Those paths are relative to the *destination* (`.claude-plugin/skills/prtend/SKILL.md`), not relative to skill-prompts.md. They were authored with the destination in mind; do not "fix" them by recomputing relative to the source.

Mechanically, the simplest approach is to open `docs/skill-prompts.md`, find each "ships as-is" block by its heading, and create the destination file with the block's body. There are nine destination files (one SKILL.md, four reference rubrics, four example transcripts) — list them up front, work down the list, write each one, never read back from one destination to populate another (the source of truth is always `docs/skill-prompts.md`).

### Skill files vs. the source doc

After this step there are two copies of the same content: one in `docs/skill-prompts.md` (the authoring/design doc, in fenced blocks) and one under `.claude-plugin/skills/prtend/*.md` (the live skill that ships). This is deliberate. The source doc is the editable spec; the destination tree is what Claude Code loads. When the spec changes, the change is made first in `docs/skill-prompts.md` (so the discussion lives in a reviewable diff), then propagated to the destination files in the same commit. There is no codegen / generator script — the doc is short enough that hand-propagation under code review is more reliable than a script that drifts.

A drift check is included in Verification below: a `diff`-style comparison that fails noisily if the destination tree falls out of sync with the source. Re-run it before tagging any release.

### Plugin manifest

`.claude-plugin/plugin.json` is unchanged. The skill auto-loads from `.claude-plugin/skills/<name>/SKILL.md` per the Claude Code plugin loader; no manifest entry is required to enumerate the skill. (If a future Claude Code version requires explicit skill registration in the manifest, that's a follow-up edit, not part of step 13.)

### Examples directory

`examples/` lives under the skill directory (`.claude-plugin/skills/prtend/examples/`), not at the repo root. The repo root already has a top-level `examples/` directory (currently holding `pr-reviewers.yml.sample` per `../repo-bootstrap.md` § "Directory tree"); that is a different directory for a different purpose (sample configs, not skill transcripts). Do not collapse them.

### Marketplace registration (out-of-repo)

The marketplace entry is one row added to `procrastivity/marketplace`'s plugin index. The exact format depends on that repo's current conventions — read it before opening the PR there. Concretely:

1. Clone (or pull) `procrastivity/marketplace`.
2. Find the existing `clast` or `direnv-session-loader` entry — those are the reference shapes.
3. Add a sibling entry for `prtend` with `name: prtend`, the repo URL for this repo, the version from `.claude-plugin/plugin.json` (`0.1.0`), and the description from the same manifest.
4. Open a PR titled `add: prtend plugin entry` (or whatever matches the marketplace repo's convention).

That PR is reviewed and merged in the marketplace repo. Do not block this step's local merge on the marketplace PR — the skill files landing here let local-plugin installs work; the marketplace makes the install URL prettier.

### Key decisions

- **Skill ships in this repo, not a separate one.** The CLI and the skill have one shared design (`overview.md` is the workflow contract; the CLI implements one half, the skill implements the other). Splitting them into two repos would require version-pinning the skill to a CLI release, which is overhead for a v0 that has one author and one user. Co-locate; revisit if external skill authors materialize.
- **Skill files are content, not generated.** No build step, no template substitution, no `${VERSION}` placeholder swap. The version is in `.claude-plugin/plugin.json`; SKILL.md doesn't reproduce it. If SKILL.md needs to reference a version-specific behavior in the future, link to a doc that does — don't bake the version into prose.
- **Source of truth is `docs/skill-prompts.md`.** The destination files are downstream copies. This inverts the obvious assumption ("the live file is the source"); the reason is reviewability. Changes to the skill go through a doc review (visible in PR diffs as a single block edit) before the corresponding hand-propagation. Treating the live files as source-of-truth means every skill change is a multi-file diff with no central narrative, which is harder to review and easier to drift on.
- **No drift-check CI yet.** A bash script that diffs the source blocks against the destination files is straightforward (the fences are stable delimiters), but it's not worth wiring into pre-commit at v0 — the surface is small enough that human review catches drift. If we land a skill update without updating the source doc twice, add the check. Track this as a follow-up, not part of step 13.
- **Marketplace registration is one PR, not a workflow change.** No new CI in this repo runs against the marketplace; no submodule; no release hook. The marketplace entry points at this repo's release tag (or branch, at v0). When this repo tags `v0.1.0`, the marketplace entry's `version` becomes valid; until then, marketplace install pulls `main`.
- **`.gitkeep` removal in the same commit as the content.** Leaving the placeholder beside real content is harmless but signals "directory is intentionally empty" — a confusing claim once nine files live there. Drop it.
- **Frontmatter `description` ships verbatim from skill-prompts.md.** That sentence is calibrated for the skill router's trigger heuristics (it lists the exact phrases that should activate prtend); shortening or rewording it changes when the skill fires. Do not abbreviate even though it's long.
- **Reference files do not have frontmatter.** Only SKILL.md has the `--- name: prtend ---` block; the rubrics, ask-options, and note-templates are plain Markdown. Adding frontmatter to them would risk Claude Code interpreting them as additional skills.
- **Example transcripts in `examples/`, not inline in SKILL.md.** SKILL.md stays compact (it's read on every trigger); examples are read on demand. The split is the progressive-disclosure pattern called out at the top of `../skill-prompts.md`.

## Verification

```bash
# Files exist where the bootstrap doc says they should.
test -f .claude-plugin/skills/prtend/SKILL.md
test -f .claude-plugin/skills/prtend/ci-fixable-rubric.md
test -f .claude-plugin/skills/prtend/comment-decision-rubric.md
test -f .claude-plugin/skills/prtend/ask-options.md
test -f .claude-plugin/skills/prtend/note-templates.md
test -f .claude-plugin/skills/prtend/examples/first-run-init.md
test -f .claude-plugin/skills/prtend/examples/ci-fix-loop.md
test -f .claude-plugin/skills/prtend/examples/comment-mixed-outcomes.md
test -f .claude-plugin/skills/prtend/examples/defer-flow.md
# → all succeed (exit 0)

# Placeholder is gone.
test ! -e .claude-plugin/skills/prtend/.gitkeep
# → exit 0

# SKILL.md frontmatter parses and has the canonical name.
head -n 5 .claude-plugin/skills/prtend/SKILL.md
# → "---" then "name: prtend" then a "description: |" block then more lines

# Reference files have NO frontmatter (no leading "---" line).
for f in ci-fixable-rubric.md comment-decision-rubric.md ask-options.md note-templates.md \
         examples/first-run-init.md examples/ci-fix-loop.md \
         examples/comment-mixed-outcomes.md examples/defer-flow.md; do
  head -n 1 ".claude-plugin/skills/prtend/$f" | grep -qv '^---$' \
    || { echo "FAIL: $f has frontmatter"; exit 1; }
done
# → no output, exit 0

# Internal links in SKILL.md resolve from the SKILL.md location.
cd .claude-plugin/skills/prtend && \
  test -f ../../../docs/overview.md && \
  test -f ../../../docs/cli-contract.md && \
  test -f ../../../docs/forge-mapping.md && \
  cd - >/dev/null
# → exit 0

# Skill content matches the source doc (manual drift check). For each "ships
# as-is" block in docs/skill-prompts.md, the body should diff cleanly against
# the destination file. The mechanical check is left to reviewer eyeballs at
# v0 — run a side-by-side diff between the fenced block and the live file for
# any block you touched.
diff <(awk '/^## SKILL.md \(ships as-is\)/{p=1;next} p&&/^```markdown$/{p=2;next} p==2&&/^```$/{exit} p==2' docs/skill-prompts.md) \
     .claude-plugin/skills/prtend/SKILL.md
# → no output, exit 0

# Plugin manifest is unchanged.
git diff -- .claude-plugin/plugin.json
# → empty

# Pre-commit passes (shellcheck has nothing to do; the YAML / JSON / EOF /
# trailing-whitespace hooks run against the new Markdown).
pre-commit run --all-files
# → all hooks pass

# Local plugin load (manual). With Claude Code pointed at this repo's
# .claude-plugin tree:
#   - The skill appears as available
#   - Asking "what's the state of my PR?" in a repo with an open PR triggers
#     prtend (you'll see Claude reach for `prtend detect`)
#   - Following the trigger to first-run init opens an AskUserQuestion with
#     the options from `ask-options.md` § "first-run-init — system reviewers"

# Marketplace registration (out-of-repo, tracked separately):
# A PR opened against procrastivity/marketplace adds the prtend entry beside
# clast / direnv-session-loader. That PR's CI (if any) passes.
```

## Done

- [ ] `.claude-plugin/skills/prtend/SKILL.md` ships verbatim from `docs/skill-prompts.md` § "SKILL.md (ships as-is)", frontmatter and links intact
- [ ] `.claude-plugin/skills/prtend/ci-fixable-rubric.md`, `comment-decision-rubric.md`, `ask-options.md`, `note-templates.md` all ship verbatim from their respective "ships as-is" blocks in `docs/skill-prompts.md`
- [ ] `.claude-plugin/skills/prtend/examples/first-run-init.md`, `ci-fix-loop.md`, `comment-mixed-outcomes.md`, `defer-flow.md` all ship verbatim from the "Example transcripts" section of `docs/skill-prompts.md`
- [ ] `.claude-plugin/skills/prtend/.gitkeep` is removed
- [ ] Reference files and example transcripts have **no** YAML frontmatter (only SKILL.md does)
- [ ] Relative links in SKILL.md resolve correctly from its on-disk location
- [ ] `pre-commit run --all-files` is clean (no Markdown-affecting hook trips, no trailing whitespace, EOF newline present)
- [ ] Plugin manifest (`.claude-plugin/plugin.json`) is unchanged in this commit
- [ ] Manual: local plugin load shows the skill triggering on the documented phrases and following the first-run-init flow when `prtend config show` indicates no config
- [ ] Out-of-repo: a PR opened against `procrastivity/marketplace` adds the `prtend` entry beside `clast` and `direnv-session-loader`; tracked in this step's PR description but not blocking local merge
- [ ] One commit on a feature branch: `feat(skill): ship SKILL.md and reference files (step 13)`
