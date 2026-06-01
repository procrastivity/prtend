# Step 12 — `prtend config` subcommand family

## Context

Wire the config-management subcommand. Every prior step has read config (via `prtend_config_resolve`, `prtend_config_get`, `prtend_config_list_get`) but no step has *written* one. The skill has so far had to assume a config exists or paper around the gap; step 11's `defer-write` even exits 4 with "run `prtend config init` before defer-write", referring to a subcommand that doesn't yet exist. This step ships it.

`prtend config` is the only subcommand with sub-subcommands (`init` / `show` / `get` / `set` / `path`). The contract specifies all five and they're tightly coupled (they share resolution-chain logic and YAML I/O), so they ship together. The CLI never prompts; the skill is responsible for gathering values from the user and passing them via flags. `init` is the only one that *creates* the config file; `set` mutates an existing one; `show` / `get` / `path` are pure reads layered on top of the existing resolver.

This step reuses `prtend_atomic_write` (step 02), `prtend_config_resolve` / `prtend_config_get` / `prtend_config_list_get` (steps 02 + 08), and `prtend_repo_slug` (step 02). The YAML the writer emits is exactly the block-style flat-scalar + flat-list shape the existing readers already parse — no new YAML dialect, no new dependency. We deliberately do **not** add a YAML lib; the writer hand-formats the file, and the readers' constraints (block lists, scalar keys, no nesting beyond top level, no flow-style) become the canonical config schema.

See `../cli-contract.md` § "`prtend config`" for the five output contracts and exit-code table, `../overview.md` § "First-run init (per repo)" and § "State and config locations" for the resolution chain and the write-target rationale, and step 11's defer-write Verification block for the `prtend config init` smoke-test invocation the user is now expected to be able to run.

## Prerequisites

- Step 02 (`dispatcher`) complete — `bin/prtend` already routes `config` to `lib/prtend/prtend-subcommands/config.bash` and calls `prtend_cmd_config`; `prtend_atomic_write`, `prtend_config_resolve`, `prtend_config_get`, `prtend_config_list_get`, and `prtend_repo_slug` are available.
- Step 04 (`forge-read`) complete — not strictly required (config is forge-agnostic), but `prtend config init --write-target repo` writes under `.git`-adjacent paths, so a git repo is required and `git rev-parse` is used the same way every other subcommand uses it.
- Step 11 (`defer-write`) complete — establishes the "subcommand depends on config-dir resolution" pattern this step satisfies; step 11's exit-4 "no active config" stderr is the canonical caller-facing reference and shouldn't be reworded here.

Required on the host for smoke tests: a writable `$XDG_CONFIG_HOME` (or `$HOME/.config`) for the `xdg` write-target path, and the ability to write `.claude/pr-reviewers.yml` under the repo root for the `repo` write-target path. No forge CLI dependency — `config` never calls `gh` / `glab`.

## Goal

After this step:

- `bin/prtend config init --watch-strategy STRATEGY --write-target TARGET [...]` writes a new config file at the resolved path for the chosen target, emits the canonical JSON from `../cli-contract.md` § "`config init` output" on stdout, and exits 0.
- `bin/prtend config show` emits the canonical JSON from `../cli-contract.md` § "`config show` output" — `active_config_path`, full `resolution_chain` (one entry per source, `active: true` exactly once across the array when any config exists; all `false` when none do), and a `values` object populated from the active config.
- `bin/prtend config get KEY` prints the scalar (or newline-joined list) for `KEY` on stdout, raw — no JSON wrapping, no trailing surprise. Unknown keys exit 2.
- `bin/prtend config set KEY VALUE` mutates the active config file in place via `prtend_atomic_write`, preserving every other key's value, and exits 0. List-valued keys (`system_reviewers`, `optional_reviewers`) accept comma-separated input per the contract's v0 note; scalar keys accept a single value. Setting a key when no active config exists exits 4 with `prtend: no active config; run 'prtend config init' before config set` on stderr — same wording shape as defer-write's refusal.
- `bin/prtend config path` prints the active config file path on stdout (one line, no trailing JSON) and exits 0; if no config exists, prints nothing and exits 0 (path is *currently* nothing — that's a valid state, not an error).
- `--force` on `init` overwrites an existing file at the resolved write-target path; without it, an existing file there causes exit 4 with `prtend: config already exists at <path>; pass --force to overwrite`.
- The written YAML is exactly the block-style flat-scalar + block-list shape `prtend_config_get` / `prtend_config_list_get` already parse — no flow lists, no nested maps, no anchors. The writer is the canonical producer of that dialect; the readers are the canonical consumers.
- `bin/prtend --help` lists `config` (already does — no change needed) and `bin/prtend config --help` prints a sub-help with the five sub-subcommands and their flag tables; exit 0.

## Files to create or modify

- `lib/prtend/prtend-subcommands/config.bash` (NEW) — dispatcher + the five sub-subcommand bodies. Single file, not five — they share parsing utilities and are small.
- `lib/prtend/prtend-lib.bash` (MODIFY, small) — add `prtend_config_target_path <target>` returning the resolved file path for a given write-target (`env` / `xdg` / `repo`) without requiring the file to exist; everything else already exists.
- `test/test-config.sh` (NEW) — match the harness style step 10 / 11 landed (`test/test-note-post.sh`, `test/test-defer-write.sh`).
- `test/fixtures/config/` (NEW) — fixture configs covering the show / get / set parsing matrix; specific files listed below.

## Implementation

### `lib/prtend/prtend-subcommands/config.bash`

Public surface:

```bash
prtend_cmd_config "$@"   # dispatches to one of: config_init, config_show, config_get, config_set, config_path
```

The outer `prtend_cmd_config` is a thin router:

1. If `$# == 0` or `$1 == --help` / `-h`, print sub-usage and exit 0.
2. Capture `sub="$1"`; shift.
3. Switch on `sub`:
   - `init` → `_prtend_cmd_config_init "$@"`
   - `show` → `_prtend_cmd_config_show "$@"`
   - `get` → `_prtend_cmd_config_get "$@"`
   - `set` → `_prtend_cmd_config_set "$@"`
   - `path` → `_prtend_cmd_config_path "$@"`
   - anything else → `prtend_log_error "config: unknown subcommand '<sub>'"`, return 2.

Sub-help (printed for `prtend config --help`) lists the five sub-subcommands with one-line descriptions matching `cli-contract.md` verbatim; no flag tables in the sub-help (they're in the contract). Keep it short — this is a router, not a manual.

#### `_prtend_cmd_config_init`

Flag parsing (every value-bearing flag must reject empty and dash-leading values, same convention as `pr-open --title` and `note-post --reason`):

- `--watch-strategy STRATEGY` — required; must be one of `blocking` / `poll-on-resume` / `background`. Anything else → exit 2 with `config init: invalid --watch-strategy '<value>' (expected blocking|poll-on-resume|background)`.
- `--write-target TARGET` — required; must be one of `env` / `xdg` / `repo`. Same shape of error message.
- `--system-reviewer LOGIN` — optional, repeatable; accumulate into an array. Reject empty and dash-leading per-occurrence.
- `--optional-reviewer LOGIN` — optional, repeatable; same.
- `--poll-interval-seconds N` — optional; if present, must match `^[0-9]+$` and be ≥ 1. Exit 2 otherwise.
- `--ci-retry-limit N` — optional; same `^[0-9]+$` ≥ 1 check.
- `--force` — optional, no value.
- Anything else → exit 2 with a usage error on stderr.

Composition (in this order):

1. **Git repo gate.** `git rev-parse --git-dir` or exit 1 with `prtend: not in a git repository`. Even for `--write-target xdg`, prtend's config is keyed by repo slug — without a repo, the slug lookup is meaningless and the resulting path would be wrong.

2. **Validate `--write-target` preconditions:**
   - `env` → require `$PRTEND_CONFIG` to be set and non-empty. If unset, exit 2 with `config init: --write-target env requires $PRTEND_CONFIG to be set`. (Empty-string is also "unset" for our purposes.)
   - `xdg` → no precondition beyond having `$XDG_CONFIG_HOME` *or* `$HOME` (used by the existing resolver — same fallback chain). `_prtend_cmd_config_init` does NOT require the directory to pre-exist; `prtend_atomic_write` creates it.
   - `repo` → no extra precondition; `prtend_repo_slug` is not consulted (the path is `<repo>/.claude/pr-reviewers.yml` regardless of slug).

3. **Resolve the write-target path.** Call `prtend_config_target_path "$target"` (the new helper, see below). Capture stdout into `out_path`. If empty, exit 1 with `config init: could not resolve path for --write-target $target`.

4. **Overwrite gate.** If `out_path` exists and `--force` was not passed, exit 4 with `prtend: config already exists at $out_path; pass --force to overwrite` on stderr. Do not emit JSON. This is exit 4, not exit 2, because "the data prevents me from acting safely; you decide" is the exact framing the contract reserves exit 4 for.

5. **Assemble the YAML.** Build the body in-memory (single string). The shape is fixed; do not let flag absence shorten it (every key the readers know about appears, even if its list value is empty):

   ```yaml
   # prtend config — managed by `prtend config init` / `prtend config set`
   # See docs/overview.md § "First-run init (per repo)" for what each key does.

   watch_strategy: <STRATEGY>
   write_target: <TARGET>
   poll_interval_seconds: <N or 15>
   ci_retry_limit: <N or 3>

   system_reviewers:
   <-->- <login>
   <-->- ...

   optional_reviewers:
   <-->- <login>
   <-->- ...
   ```

   - `<-->` is exactly two spaces — the existing `prtend_config_list_get` accepts any positive indent, but pin it to two for forward compatibility with downstream tools.
   - When a list is empty, emit the bare `system_reviewers:` line followed by an empty line — do *not* emit `system_reviewers: []` (flow style is explicitly unsupported by the reader). The reader's "list block ended" detection on the next top-level key handles the empty case naturally.
   - Logins are emitted verbatim — no quoting unless the value contains a `#`, `:`, or leading/trailing whitespace, in which case wrap it in double quotes and escape any embedded `"` and `\`. Reviewer logins on both forges are restricted to a safe alphabet so this branch should be near-cold, but defending against a future Copilot-style suffix or self-hosted username convention is cheap. Apply the same quoting policy to scalar values (`watch_strategy`, `write_target`); they're constrained to enums so will never trip it.
   - The top-of-file comment is fixed text; do not stamp a timestamp into it (matches step 11's "deferred_at is the time of *this* write" decision in spirit: avoid metadata that bumps on every `config set` for no reader gain). The "managed by" line is enough to communicate intent.

6. **Write the file** via `prtend_atomic_write "$out_path"`. Propagate its exit code on failure (with the helper's stderr surfaced unmodified).

7. **Emit JSON on stdout** via `jq -c -n`, matching `cli-contract.md` § "`config init` output" field-for-field:

   ```json
   {
     "written_to": "<absolute path>",
     "write_target": "<env|xdg|repo>",
     "keys_set": ["system_reviewers","optional_reviewers","watch_strategy","write_target","poll_interval_seconds","ci_retry_limit"]
   }
   ```

   `keys_set` is the fixed full set — every key the writer emits, in the order the contract example shows. We do not vary it per invocation (the contract's example is also fixed; treat it as a schema, not a sample of "what happened to be set this time").

#### `_prtend_cmd_config_show`

No flags. Composition:

1. **Build the resolution chain.** Three entries, in source-priority order: `env`, `xdg`, `repo`. For each:
   - `source` ← string literal.
   - `path` ← `prtend_config_target_path <source>` *if the file exists*, else `null` (the JSON literal, not `"null"`).
   - `active` ← `true` iff this is the *first* entry in the chain with a non-null path (matches `prtend_config_resolve`'s semantics — first hit wins).

   When no config exists anywhere, every entry has `path: null` and `active: false`; `active_config_path` at the top level is also `null`.

   Implementation detail: `prtend_config_target_path env` returns `$PRTEND_CONFIG` when set, otherwise empty; in `show`, an empty `env` path becomes JSON `null` rather than `""`. The `path` shown for `env` is therefore the *expected* location when `$PRTEND_CONFIG` is set even if the file at that location doesn't exist — and `active` for `env` is still gated on file existence. This matches what a user reading `config show` would expect from a "would this env override hit if a file were there?" diagnostic.

2. **Read the active config.** If a path is active, parse it via the existing helpers:
   - `system_reviewers` ← `prtend_config_list_get system_reviewers` (collect into a JSON array).
   - `optional_reviewers` ← same.
   - `watch_strategy` ← `prtend_config_get watch_strategy`.
   - `write_target` ← `prtend_config_get write_target`.
   - `poll_interval_seconds` ← `prtend_config_get poll_interval_seconds`, coerced to integer via `jq` (`tonumber`); fall back to `15` if missing.
   - `ci_retry_limit` ← same shape, fallback `3`.

   When no path is active, `values` is the empty object `{}` — not omitted, not populated with defaults. (Defaults belong in the readers, not in a diagnostic surface.)

3. **Emit JSON on stdout** via `jq -c -n`, matching the contract field-for-field.

#### `_prtend_cmd_config_get`

Argv: exactly one positional — `KEY`. No flags beyond `-h`.

Composition:

1. Validate `KEY` is non-empty and matches `^[A-Za-z_][A-Za-z0-9_]*$`. The existing `prtend_config_get` already enforces this, but enforcing it at the subcommand boundary lets us emit a friendlier message (`config get: invalid key '<value>'`).
2. Reject unknown keys *before* hitting disk. The known-key set is the fixed six: `system_reviewers`, `optional_reviewers`, `watch_strategy`, `write_target`, `poll_interval_seconds`, `ci_retry_limit`. Anything else → exit 2 with `config get: unknown key '<value>' (known: <list>)`. This catches typos at the skill layer — the readers would silently return empty otherwise.
3. Switch on key:
   - List keys (`system_reviewers`, `optional_reviewers`) → call `prtend_config_list_get`; print each value on its own line. Zero values → print nothing.
   - Scalar keys → call `prtend_config_get`; print the value (or nothing if unset). For `poll_interval_seconds` / `ci_retry_limit`, do **not** substitute defaults — `get` shows what the file says; `show` shows effective values. The asymmetry is the point.
4. Exit 0 in every successful case, including "key is unset" (matches the contract's exit-0 "idempotent no-ops" framing).

#### `_prtend_cmd_config_set`

Argv: exactly two positionals — `KEY VALUE`. No flags beyond `-h`. Composition:

1. Validate `KEY` per the same rules as `get`. Reject unknown keys with exit 2 and the documented stderr.
2. **Active-config gate.** Call `prtend_config_resolve`. If empty, exit 4 with `prtend: no active config; run 'prtend config init' before config set`. Capture the resolved path into `target_path`.
3. **Validate the value** per key:
   - `watch_strategy` ∈ `blocking|poll-on-resume|background`. Mismatch → exit 2.
   - `write_target` ∈ `env|xdg|repo`. Mismatch → exit 2. Note: `set write_target X` does *not* migrate the file to the new target's location — it only edits the key in place. That migration is `config init` territory; if the user wants to relocate the config they should rerun `init` at the new target. Document this explicitly in the sub-help.
   - `poll_interval_seconds`, `ci_retry_limit` → must match `^[0-9]+$` and be ≥ 1. Mismatch → exit 2.
   - `system_reviewers`, `optional_reviewers` → split `VALUE` on `,`, trim each token, reject empty tokens (`"a,,b"` → exit 2 with `config set: empty list element after split`).
4. **Read-modify-write.** Read the entire current config file into memory. Replace the line for `KEY` (for scalars) or the entire block (for lists). The block-replace algorithm mirrors `prtend_config_list_get`'s parser: find the `<KEY>:` line, drop subsequent indented `- value` lines and any blank lines that immediately follow them up to the next top-level key, then splice in the new block. For scalar keys, replace the matched line; if the key was absent from the file (rare — only possible if a user hand-edited it out), append the new line at end-of-file. Use `prtend_atomic_write` to write the result back to `target_path`.
5. **Emit no JSON on stdout** (matches the contract — `set` is silent on success, like `git config`). Exit 0.

The read-modify-write is deliberately implemented inline in this subcommand, not factored into `prtend-lib.bash`. There's exactly one writer; pulling it into the shared lib creates a public mutation API we'd then need to design for arbitrary external callers, when the only caller is the subcommand directly above it.

#### `_prtend_cmd_config_path`

No flags. Composition: call `prtend_config_resolve`, print stdout verbatim (which is either the active path with a trailing newline, or nothing). Exit 0 in both cases.

This is a one-liner. It exists as a sub-subcommand mainly so the skill / shell glue can do `$(prtend config path | xargs dirname)` without parsing the `show` JSON — exactly the pattern step 11's Verification block uses.

### `prtend-lib.bash` additions

One new helper. Sits next to `prtend_config_resolve`, and is the inverse: "what path *would* this target write to?", independent of file existence.

```bash
# prtend_config_target_path <env|xdg|repo>
# Prints the canonical path for the given write-target on stdout.
# Returns 0 on success even if the file doesn't exist.
# Returns 1 if the target's prerequisites are not met
# (env: $PRTEND_CONFIG unset; xdg: neither $XDG_CONFIG_HOME nor $HOME set,
#  or repo slug unresolvable; repo: not in a git repo).
prtend_config_target_path() { ... }
```

Implementation mirrors the three branches inside `prtend_config_resolve` but never checks `-f`:

- `env` → `printf '%s\n' "$PRTEND_CONFIG"` if set; else return 1.
- `xdg` → compute `xdg_root` exactly as the resolver does; require `prtend_repo_slug`; print `$xdg_root/prtend/${slug}.yml`. Return 1 on either lookup failure.
- `repo` → `git rev-parse --show-toplevel` → print `<root>/.claude/pr-reviewers.yml`. Return 1 if not in a git repo.

Anything else (unknown target) → log error, return 2.

A small refactor temptation: have `prtend_config_resolve` call `prtend_config_target_path env`, then `xdg`, then `repo`, and `-f`-check each. Resist it for this step — `prtend_config_resolve` is exercised by every subcommand; changing its internals here adds a regression-surface for no behavior change. File the refactor as a follow-up if it bothers anyone.

### Key decisions

- **Five sub-subcommands in one file, not five files.** They share argv parsing, the `prtend_config_target_path` helper call, and the YAML I/O conventions. Splitting them would force shared helpers into yet another file and create three-deep nesting (`prtend-subcommands/config/init.bash`). The contract treats them as one subcommand; keep the layout matched to the contract.
- **No interactive prompts in `config init`.** The CLI never prompts — that's `overview.md` § "First-run init"'s contract: the skill prompts; the CLI writes. A `--interactive` flag would invert the design and creep responsibility back into the CLI; refuse the temptation.
- **`init` writes the full key set every time, even when most are absent from flags.** The reader doesn't care; the writer's job is to produce a file that `show` can subsequently read deterministically. Leaving keys out of the file would surface as `null` in `show`, which is indistinguishable from "user-set to empty" — and that's a debug-hostile state for a config the user maintains by hand if `set` ever stops working.
- **`set` mutates in place; never reaches for `init`.** No "auto-bootstrap on `set` if missing" behavior — `set` against an empty resolution chain is exit 4. The skill orchestrates the init→set sequence when both are needed. Mirrors step 11's "no `--force` on `defer-write`" stance: idempotency contracts are clearer when each subcommand owns one outcome.
- **`set write_target X` edits the key, not the file location.** The migration semantics ("move my config from XDG to repo") need to delete the source file and write at the destination atomically — both halves can fail independently. That's `config init --write-target repo --force` territory (with the user reading the existing values out via `show` first), not a `set` side effect.
- **`get` does not substitute defaults; `show` does.** `get poll_interval_seconds` against a file that omits the key prints empty. `show` against the same file reports `15`. The contract distinguishes "what does the file say" (`get`) from "what would prtend use" (`show`); preserve the asymmetry.
- **YAML writer is hand-rolled, not jq-piped-through-yq.** Adding a yq dependency for emitting a six-key flat document is a bad ratio. The hand-rolled writer is ~40 lines, exercises every YAML branch the readers parse, and produces stable byte output (easy to diff in tests).
- **Quoting policy applied to scalars too, even though the enums never trip it.** Defensive against a future enum that introduces a `:` or `#` (unlikely). Cheap to write once and forget.
- **`config show` reports `active: false` for every chain entry when no config exists.** Not `active: null`, not omitted — the contract example shows boolean. A future user-facing diagnostic ("you have no config") reads from `active_config_path == null` at the top level; the per-entry `active` is internally consistent regardless.
- **`config path` exits 0 with empty stdout when no config exists.** Not exit 4. The contract reserves exit 4 for "data prevents safe action"; `path` doesn't act, it reports. Empty output is the truthful answer.
- **No `--format` flag on `show`.** YAML, TOML, table — none of them are worth the surface area. JSON is the one contract.
- **List-element quoting on read.** The existing `prtend_config_list_get` strips a single pair of surrounding quotes; the writer's quoting policy emits them only when needed. The two are matched — round-tripping a quoted value preserves it as quoted on disk and as a bare value in `get` output.

### Test shape

Match `test/test-defer-write.sh` / `test/test-note-post.sh` exactly. No forge mocking is needed (this subcommand never calls the forge), but the harness's tmp-repo + cleanup scaffolding is reused. Mock `$PRTEND_CONFIG` and `$XDG_CONFIG_HOME` via `export` per case; mock `prtend_repo_slug` only where the surface needs an unresolvable slug (e.g., to exercise `prtend_config_target_path xdg` returning 1).

Fixtures under `test/fixtures/config/`:

- `minimal.yml` — only `watch_strategy: blocking` and `write_target: xdg` set; all other keys absent. Drives the `show` "defaults appear" + `get` "absent key returns empty" tests.
- `populated.yml` — every key set, both list keys with two entries each, `poll_interval_seconds: 30`, `ci_retry_limit: 5`. The happy-path `show` reference.
- `with_quoted.yml` — a `system_reviewers` entry with a `#` in the login wrapped in double quotes; verifies the reader's quote-strip + the writer's quote-emit round-trip.
- `expected_init.minimal.yml` — byte-for-byte expected output for an `init` call with `--watch-strategy blocking --write-target xdg`; the happy-path `init` test diffs against this.
- `expected_init.populated.yml` — same with every flag set including `--system-reviewer` (×2) and `--optional-reviewer` (×2).

Cases (one test block each, matching step 10 / 11's granularity):

1. **`init` happy path, xdg target.** `--watch-strategy blocking --write-target xdg`; assert file exists at the resolved xdg path, byte-matches `expected_init.minimal.yml`, JSON shape matches the contract.
2. **`init` happy path, repo target.** Same with `--write-target repo`; file at `<repo>/.claude/pr-reviewers.yml`.
3. **`init` happy path, env target.** Set `$PRTEND_CONFIG=/tmp/foo.yml` before invocation; file at that path.
4. **`init` env target without `$PRTEND_CONFIG`.** `--write-target env` with the env var unset → exit 2 with the documented stderr.
5. **`init` invalid `--watch-strategy`.** → exit 2.
6. **`init` invalid `--write-target`.** → exit 2.
7. **`init` invalid `--poll-interval-seconds 0`.** (Edge: zero is ≥ 0 but our rule is ≥ 1.) → exit 2.
8. **`init` non-numeric `--ci-retry-limit abc`.** → exit 2.
9. **`init` overwrite refusal.** Pre-create the target path; rerun → exit 4 with the documented stderr; original content unchanged.
10. **`init --force` overwrite.** Same setup + `--force`; assert file is rewritten to the new content.
11. **`init` writes both list keys empty when no `--system-reviewer` / `--optional-reviewer` is passed.** Assert the body contains bare `system_reviewers:` and `optional_reviewers:` lines with no list items.
12. **`init` writes quoted list element when login contains a `#`.** Pass `--system-reviewer 'bot#1'`; assert output contains `- "bot#1"`; read it back with `config get system_reviewers` and assert the value is `bot#1` (unquoted in the get output).
13. **`show` with populated.yml as the active config.** Assert `active_config_path` matches, `resolution_chain` has the right `active` distribution, `values` populated.
14. **`show` with no active config.** All `path: null`, all `active: false`, `active_config_path: null`, `values: {}`.
15. **`show` with `$PRTEND_CONFIG` set but missing file.** `env` entry has the expected path, `active: false`; falls through to the next entry that does exist.
16. **`show` defaults appear for `poll_interval_seconds` / `ci_retry_limit` when the file omits them.** Using `minimal.yml`; assert `values.poll_interval_seconds == 15` and `values.ci_retry_limit == 3`.
17. **`get` scalar present.** `config get watch_strategy` against `populated.yml` → prints `blocking` only.
18. **`get` scalar absent.** Same against `minimal.yml` → empty stdout, exit 0.
19. **`get` list present.** `config get system_reviewers` against `populated.yml` → prints one login per line.
20. **`get` list with quoted entry.** Against `with_quoted.yml` → prints the unquoted value on its own line.
21. **`get` unknown key.** `config get nonsense` → exit 2 with the documented stderr.
22. **`get` invalid key format.** `config get '1bad'` → exit 2.
23. **`set` scalar (`watch_strategy`).** Against `populated.yml`; verify the file is rewritten with the new value, all other keys preserved byte-for-byte (or at least round-trip via `show` to the expected JSON).
24. **`set` invalid scalar value.** `set watch_strategy nonsense` → exit 2.
25. **`set` list (`system_reviewers a,b,c`).** Against `populated.yml`; verify the block is replaced and `get system_reviewers` returns `a\nb\nc`.
26. **`set` list with empty element.** `set system_reviewers 'a,,b'` → exit 2 with the documented stderr.
27. **`set` without active config.** No file in any slot; `set watch_strategy blocking` → exit 4 with the documented stderr; no file created.
28. **`set` unknown key.** → exit 2.
29. **`path` with active config.** Prints the path; exit 0.
30. **`path` with no active config.** Prints nothing; exit 0.
31. **Unknown sub-subcommand.** `config bogus` → exit 2.
32. **Sub-help.** `config --help` → prints the five sub-subcommands; exit 0.

## Verification

```bash
shellcheck bin/prtend lib/prtend/prtend-lib.bash lib/prtend/prtend-forge-lib.bash lib/prtend/prtend-notes-lib.bash lib/prtend/prtend-subcommands/config.bash
# → no output, exit 0

# Help still works and the sub-help renders.
bin/prtend --help                # → exit 0, includes 'config'
bin/prtend config --help         # → exit 0, lists init / show / get / set / path

# Happy-path init under a temp XDG root.
tmpdir="$(mktemp -d)"
XDG_CONFIG_HOME="$tmpdir" bin/prtend config init \
  --watch-strategy blocking \
  --write-target xdg \
  --system-reviewer copilot \
  --optional-reviewer alice \
  --optional-reviewer bob | jq .
# → JSON: written_to ends with /prtend/<slug>.yml, write_target="xdg",
#    keys_set is the full six-item array.

# Show reflects the written config.
XDG_CONFIG_HOME="$tmpdir" bin/prtend config show | jq .
# → active_config_path matches; resolution_chain shows xdg as active;
#    values.system_reviewers == ["copilot"]; values.poll_interval_seconds == 15.

# Get round-trip.
XDG_CONFIG_HOME="$tmpdir" bin/prtend config get watch_strategy
# → "blocking" on stdout
XDG_CONFIG_HOME="$tmpdir" bin/prtend config get optional_reviewers
# → "alice" then "bob", one per line

# Set + get round-trip preserves other keys.
XDG_CONFIG_HOME="$tmpdir" bin/prtend config set system_reviewers "copilot,duo"
XDG_CONFIG_HOME="$tmpdir" bin/prtend config get system_reviewers
# → copilot\nduo
XDG_CONFIG_HOME="$tmpdir" bin/prtend config get watch_strategy
# → blocking (unchanged)

# Path resolves.
XDG_CONFIG_HOME="$tmpdir" bin/prtend config path
# → absolute path ending in /prtend/<slug>.yml

# Overwrite refusal.
XDG_CONFIG_HOME="$tmpdir" bin/prtend config init \
  --watch-strategy blocking --write-target xdg; echo "exit=$?"
# → "prtend: config already exists at ...; pass --force to overwrite"; exit=4

# Overwrite with --force.
XDG_CONFIG_HOME="$tmpdir" bin/prtend config init \
  --watch-strategy poll-on-resume --write-target xdg --force | jq -r .written_to
# → same path; the file's watch_strategy now reads as poll-on-resume.

# No-config set refusal.
EMPTY="$(mktemp -d)"
XDG_CONFIG_HOME="$EMPTY" PRTEND_CONFIG="" bin/prtend config set watch_strategy blocking; echo "exit=$?"
# → "prtend: no active config; run 'prtend config init' before config set"; exit=4

# Composition with step 11's defer-write — the original motivating use case.
XDG_CONFIG_HOME="$tmpdir" bin/prtend defer-write --pr 123 --comment 456789 \
  --reason "design review" 2>&1 | head -5
# → no longer hits the "no active config" exit 4 — defer-write proceeds to fetch
#   the comment (which then fails for unrelated reasons in this smoke test, but
#   the config gate is satisfied).

# Mocked tests pass.
./test/test-config.sh
# → all cases green
```

## Done

- [ ] `lib/prtend/prtend-subcommands/config.bash` defines `prtend_cmd_config` and the five `_prtend_cmd_config_<sub>` bodies
- [ ] `prtend_config_target_path` added to `prtend-lib.bash`; resolves `env` / `xdg` / `repo` to a path without requiring file existence
- [ ] `config init` writes a file at the resolved write-target whose body is byte-equal to the expected fixture (six top-level keys, in fixed order, with the documented quoting policy)
- [ ] `config init` refuses to overwrite an existing file without `--force` (exit 4 with the documented stderr); `--force` overwrites cleanly
- [ ] `config init --write-target env` requires `$PRTEND_CONFIG`; absent → exit 2 with the documented stderr
- [ ] `config show` emits the contract JSON: `active_config_path`, three-entry `resolution_chain`, `values` populated from the active config (with `poll_interval_seconds` / `ci_retry_limit` defaults applied) or empty when no config is active
- [ ] `config get KEY` prints scalar values raw / list values one-per-line; absent keys exit 0 with empty output; unknown keys exit 2
- [ ] `config set KEY VALUE` mutates in place via `prtend_atomic_write`, preserving every other key's value; absent active config exits 4 with the documented stderr
- [ ] `config set` validates each key's value per the same rules `init` uses (enums for `watch_strategy` / `write_target`, integers ≥ 1 for the two numeric keys, comma-split with no empty tokens for the list keys)
- [ ] `config path` prints the active path or nothing; always exits 0
- [ ] `config --help` and `config <unknown>` behave per the dispatcher rules above
- [ ] `shellcheck` clean on the new file and the modified core lib
- [ ] Test cases for: each sub-subcommand happy path, each write-target, overwrite refusal + `--force`, every parse-error mode, no-active-config refusal in `set`, quoted-list-element round-trip, defaults-in-show / no-defaults-in-get asymmetry, unknown-sub-subcommand dispatch
- [ ] One commit on a feature branch: `feat(config): add config subcommand family (step 12)`
