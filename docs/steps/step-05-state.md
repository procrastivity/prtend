# Step 05 — State lib

## Context

Build `prtend-state-lib.bash` — the per-PR state store that holds the subscription marker, per-signature CI retry counters, and the last review-batch cursor. Every later subcommand that needs to remember anything across invocations (`ci-watch`, `reviews-poll`, `watch`, `doctor`) reads and writes through this lib. See `../repo-bootstrap.md` § "State — `prtend-state-lib.bash`" and `../overview.md` § "State and config locations".

This step is intentionally independent of the forge work — state files don't care which forge they were written from beyond a `forge` field for diagnostics. It could have been done in parallel with step 03 / 04, but the linear order keeps the git log readable.

## Prerequisites

- Step 02 (`dispatcher`) complete — provides `prtend_atomic_write`, `prtend_state_dir`, `prtend_log_*`, and `prtend_json_get` in `lib/prtend/prtend-lib.bash`. Every write in this step goes through `prtend_atomic_write`; every read parses via `jq`.

Required on the host for verification: `jq` (already a hard dep from step 04), `bash` 4.4+.

## Goal

After this step, `lib/prtend/prtend-state-lib.bash` defines the eight public functions from `../repo-bootstrap.md` § "State", each operating on the per-PR JSON file at `prtend_state_dir()/<pr>.json`:

- `prtend_state_path <pr>` — print the absolute state-file path; never reads or writes.
- `prtend_state_read <pr>` — print the JSON contents on stdout; print nothing and exit 0 if the file does not exist.
- `prtend_state_write <pr> <json>` — atomic write via `prtend_atomic_write`. Validates that `<json>` parses (`jq -e .`) before touching disk.
- `prtend_state_increment_ci_attempt <pr> <signature>` — bump `.ci_attempts[<signature>]` by 1, creating the file (with `pr`, `forge`, `subscribed_at` initialized) if absent. Print the new count on stdout.
- `prtend_state_ci_attempts <pr> <signature>` — print the current count (0 if file or key absent). No write.
- `prtend_state_set_cursor <pr> <cursor>` — set `.last_review_cursor` and `.last_review_at`; create file if absent.
- `prtend_state_get_cursor <pr>` — print `.last_review_cursor` or empty if absent.
- `prtend_state_clear <pr>` — remove the state file; exit 0 even if it didn't exist (idempotent).

No subcommand consumes the lib yet. Step 07's `detect` reads it (for `subscribed_at` / `last_review_cursor` reporting); step 08's watch primitives mutate it.

## Files to create or modify

- `lib/prtend/prtend-state-lib.bash` (NEW)

## Implementation

### File header

Mirror the structure of `prtend-lib.bash` and (when step 03 lands it) `prtend-forge-lib.bash`:

```bash
#!/usr/bin/env bash
# prtend-state-lib.bash — per-PR state file: subscription marker, CI retry
# counters, review-batch cursor. All I/O through prtend_atomic_write.

if [[ -n "${PRTEND_STATE_LIB_LOADED:-}" ]]; then
  return 0
fi
PRTEND_STATE_LIB_LOADED=1

set -euo pipefail

# Depends on prtend-lib.bash being sourced first (atomic_write, state_dir, log_*).
if [[ -z "${PRTEND_LIB_LOADED:-}" ]]; then
  printf 'error: prtend-state-lib.bash requires prtend-lib.bash to be sourced first\n' >&2
  return 1
fi
```

The dispatcher already sources `prtend-lib.bash` before any other lib, so the guard is a belt-and-braces check for ad-hoc `bash -c 'source ...'` callers. Match the guard idiom from `prtend-forge-lib.bash` — same wording, same exit path.

### Canonical state-file shape

From `../repo-bootstrap.md` § "State":

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

All seven fields are top-level. `ci_attempts` is an object keyed by signature string; missing key means zero. `last_review_cursor` / `last_review_at` are absent until the first poll. `forge` is filled in lazily on first write — see "Initialization" below.

### Function-by-function

#### `prtend_state_path <pr>`

```bash
prtend_state_path() {
  local pr="${1:-}"
  if [[ -z "$pr" ]]; then
    prtend_log_error "prtend_state_path: missing pr argument"
    return 2
  fi
  local dir
  dir="$(prtend_state_dir)" || return 1
  printf '%s/%s.json\n' "$dir" "$pr"
}
```

`prtend_state_dir` already exists in `prtend-lib.bash` — do not reimplement directory resolution here. If it fails (no git, no XDG, no HOME), propagate the failure.

PR argument validation: require non-empty. Don't enforce numeric — GitHub/GitLab PR identifiers are integers in practice, but the lib treats `<pr>` as an opaque slug for the filename. Bad input shows up as a missing file, not a crash.

#### `prtend_state_read <pr>`

```bash
prtend_state_read() {
  local pr="${1:-}" path
  [[ -n "$pr" ]] || { prtend_log_error "prtend_state_read: missing pr"; return 2; }
  path="$(prtend_state_path "$pr")" || return 1
  if [[ ! -f "$path" ]]; then
    return 0   # absent → empty stdout, success
  fi
  cat -- "$path"
}
```

"Absent → empty stdout, exit 0" is the contract. Callers distinguish present-but-empty from absent by piping through `jq` themselves. Don't `jq .` on read — that would alter formatting and add latency for the common case where the caller is about to feed the JSON into another `jq` anyway.

#### `prtend_state_write <pr> <json>`

```bash
prtend_state_write() {
  local pr="${1:-}" json="${2:-}" path
  [[ -n "$pr" ]] || { prtend_log_error "prtend_state_write: missing pr"; return 2; }
  [[ -n "$json" ]] || { prtend_log_error "prtend_state_write: missing json"; return 2; }
  if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    prtend_log_error "prtend_state_write: input is not valid JSON"
    return 2
  fi
  path="$(prtend_state_path "$pr")" || return 1
  printf '%s\n' "$json" | prtend_atomic_write "$path"
}
```

Validation gate: `jq -e .` rejects malformed JSON before the atomic write so a corrupt file can never replace a valid one. Exit 2 (user/data error) matches the convention in `prtend_atomic_write` and `prtend_config_get`.

#### Initialization helper (private)

The increment-and-set-cursor paths both need to "create the file if absent with reasonable defaults". Factor that into one private function so the seed shape lives in exactly one place:

```bash
_prtend_state_seed_json() {
  local pr="$1" forge_now ts
  forge_now="${PRTEND_FORGE:-unknown}"
  ts="$(_prtend_state_now)"
  jq -n \
    --argjson pr "$pr" \
    --arg forge "$forge_now" \
    --arg ts "$ts" \
    '{pr: $pr, forge: $forge, subscribed_at: $ts, ci_attempts: {}}'
}
```

Two important details:

- **`forge` reads `$PRTEND_FORGE`, the cache populated by `prtend_forge_detect` (step 03).** If the state lib is exercised before forge detection has run in the same process (e.g. a unit test of `state_increment_ci_attempt` in isolation), `forge` falls back to `"unknown"`. That's fine — `doctor` (step 11) will treat `unknown` as a stale-state signal and offer to refresh. Do not call `prtend_forge_detect` from here; the state lib must not depend on the forge lib (the dependency arrow is forge → state, not the other way).
- **`--argjson pr` (not `--arg pr`)** so the value lands as a JSON number, matching the canonical shape. Validate `<pr>` parses as a number before calling — see below.

#### Timestamp helper (private)

```bash
_prtend_state_now() {
  # ISO 8601 UTC, second precision. GNU and BSD date both support -u -Iseconds,
  # but BSD prints "+00:00" and GNU prints "+00:00" too in recent versions —
  # normalise to "Z" to match the canonical shape.
  local ts
  ts="$(date -u -Iseconds 2>/dev/null || date -u +'%Y-%m-%dT%H:%M:%S%z')"
  # Replace trailing "+00:00" or "+0000" with "Z".
  ts="${ts/+00:00/Z}"
  ts="${ts/+0000/Z}"
  printf '%s\n' "$ts"
}
```

Match the canonical shape's `2026-05-31T19:42:00Z` form. Don't use fractional seconds — the per-signature counter only needs ordering, not high-resolution timing.

#### `prtend_state_increment_ci_attempt <pr> <signature>`

```bash
prtend_state_increment_ci_attempt() {
  local pr="${1:-}" sig="${2:-}" path existing next
  [[ -n "$pr" ]] || { prtend_log_error "increment_ci_attempt: missing pr"; return 2; }
  [[ -n "$sig" ]] || { prtend_log_error "increment_ci_attempt: missing signature"; return 2; }
  [[ "$pr" =~ ^[0-9]+$ ]] || { prtend_log_error "increment_ci_attempt: pr must be numeric (got '$pr')"; return 2; }

  path="$(prtend_state_path "$pr")" || return 1
  if [[ -f "$path" ]]; then
    existing="$(cat -- "$path")"
  else
    existing="$(_prtend_state_seed_json "$pr")"
  fi

  next="$(printf '%s' "$existing" | jq \
    --arg sig "$sig" \
    '.ci_attempts[$sig] = ((.ci_attempts[$sig] // 0) + 1) | .ci_attempts[$sig]' \
    )"
  # Re-run the same update to produce the full doc, not just the count.
  local updated
  updated="$(printf '%s' "$existing" | jq \
    --arg sig "$sig" \
    '.ci_attempts[$sig] = ((.ci_attempts[$sig] // 0) + 1)')"

  prtend_state_write "$pr" "$updated"
  printf '%s\n' "$next"
}
```

The two-jq pattern is intentional: one call updates and emits the full doc for writing; one call emits just the new count for stdout. Trying to do both in a single `jq` invocation requires either `tee` plumbing or `(...) as $x | ...`, both of which obscure intent. Two calls are cheap.

PR numeric check is here, not in `state_path` — `state_path` is a pure filename builder used by `state_clear` too, and clearing a non-numeric "PR" file (left over from a typo) should still work.

#### `prtend_state_ci_attempts <pr> <signature>`

```bash
prtend_state_ci_attempts() {
  local pr="${1:-}" sig="${2:-}" path
  [[ -n "$pr" ]] || { prtend_log_error "ci_attempts: missing pr"; return 2; }
  [[ -n "$sig" ]] || { prtend_log_error "ci_attempts: missing signature"; return 2; }
  path="$(prtend_state_path "$pr")" || return 1
  if [[ ! -f "$path" ]]; then
    printf '0\n'
    return 0
  fi
  jq -r --arg sig "$sig" '.ci_attempts[$sig] // 0' < "$path"
}
```

`// 0` covers both "key missing" and "key present but null". Pure read, no mutation, no init.

#### `prtend_state_set_cursor <pr> <cursor>`

```bash
prtend_state_set_cursor() {
  local pr="${1:-}" cursor="${2:-}" path existing updated ts
  [[ -n "$pr" ]] || { prtend_log_error "set_cursor: missing pr"; return 2; }
  [[ "$pr" =~ ^[0-9]+$ ]] || { prtend_log_error "set_cursor: pr must be numeric (got '$pr')"; return 2; }
  # cursor MAY be empty — that's "reset to first-poll".

  path="$(prtend_state_path "$pr")" || return 1
  if [[ -f "$path" ]]; then
    existing="$(cat -- "$path")"
  else
    existing="$(_prtend_state_seed_json "$pr")"
  fi
  ts="$(_prtend_state_now)"

  updated="$(printf '%s' "$existing" | jq \
    --arg cursor "$cursor" \
    --arg ts "$ts" \
    '.last_review_cursor = $cursor | .last_review_at = $ts')"
  prtend_state_write "$pr" "$updated"
}
```

Empty cursor is allowed — sets `.last_review_cursor` to `""`. The reviews-poll subcommand (step 08) interprets empty as "no batches seen yet", so storing empty is meaningful. `last_review_at` always updates on a set call, even if the cursor itself didn't change — it records "we polled at <ts> and saw nothing past the previous cursor".

#### `prtend_state_get_cursor <pr>`

```bash
prtend_state_get_cursor() {
  local pr="${1:-}" path
  [[ -n "$pr" ]] || { prtend_log_error "get_cursor: missing pr"; return 2; }
  path="$(prtend_state_path "$pr")" || return 1
  if [[ ! -f "$path" ]]; then
    return 0   # empty stdout, success
  fi
  jq -r '.last_review_cursor // ""' < "$path"
}
```

Empty stdout = "no cursor yet, treat as first poll". Distinguishing missing-file from missing-key isn't useful to the caller; both mean the same thing operationally.

#### `prtend_state_clear <pr>`

```bash
prtend_state_clear() {
  local pr="${1:-}" path
  [[ -n "$pr" ]] || { prtend_log_error "clear: missing pr"; return 2; }
  path="$(prtend_state_path "$pr")" || return 1
  rm -f -- "$path"
}
```

Idempotent by `rm -f`. Triggered by PR close (step 11's `doctor --fix`) and by explicit "abort watch" (step 08's user halt). Don't archive — the deferred docs already preserve user-visible history; state is purely operational.

### Key decisions

- **No dependency on the forge lib.** `prtend-state-lib.bash` reads `$PRTEND_FORGE` if set, but never calls `prtend_forge_detect`. State must be writable in test contexts that mock or skip forge detection entirely.
- **`prtend_atomic_write` is the ONLY write path.** No direct `>` redirection anywhere in this file, even for `state_clear` (which uses `rm`, not write). If you find yourself writing `> "$path"`, stop and reach for `prtend_atomic_write`.
- **Reads bypass `jq` when possible.** `state_read` uses `cat`; only `ci_attempts` and `get_cursor` parse with `jq`. Reason: `state_read`'s job is "give me the bytes"; the caller decides whether to parse. Forcing a parse adds latency to the common "read → mutate → write" pattern.
- **Numeric PR validation is per-function, not in `state_path`.** Only mutating functions enforce it. This lets `state_clear` and `state_read` work on stray files left by earlier bugs.
- **No locking.** A given PR is touched by at most one watcher at a time (the subscription marker in `overview.md` § "Watch session" guarantees this); a second concurrent watcher is itself the bug to fix, not something the state lib should paper over with flock. If multi-process contention becomes a real concern later (e.g. background watcher + foreground `doctor --fix`), revisit then.
- **State files never gain a schema version field in this step.** When (if) the shape changes incompatibly, add a `schema: 2` field and have readers migrate. v0 is unversioned and that's deliberate.
- **No "sweep stale states" function.** That belongs in `doctor` (step 11), which knows which PRs are still open. The lib only knows about one PR at a time.

### No `bin/prtend` change

The dispatcher does not source `prtend-state-lib.bash` yet — only the subcommands that need state will source it (step 07 onward). Adding it to the dispatcher now would couple every invocation to a lib it doesn't use. Defer.

## Verification

```bash
shellcheck bin/prtend lib/prtend/prtend-lib.bash lib/prtend/prtend-forge-lib.bash lib/prtend/prtend-state-lib.bash
# → no output, exit 0

# All eight public functions are defined.
bash -c '
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-state-lib.bash
  for f in prtend_state_path prtend_state_read prtend_state_write \
           prtend_state_increment_ci_attempt prtend_state_ci_attempts \
           prtend_state_set_cursor prtend_state_get_cursor prtend_state_clear; do
    declare -F "$f" >/dev/null || { echo "missing: $f" >&2; exit 1; }
  done
  echo ok
'
# → "ok"; exit 0

# Refuses to load without prtend-lib.bash first.
bash -c '
  source lib/prtend/prtend-state-lib.bash 2>&1 | head -n1
' || true
# → "error: prtend-state-lib.bash requires prtend-lib.bash to be sourced first"

# Round-trip: write → read → matches.
bash -c '
  set -euo pipefail
  export XDG_STATE_HOME="$(mktemp -d)"
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-state-lib.bash
  prtend_state_write 999 "{\"pr\":999,\"forge\":\"github\",\"subscribed_at\":\"2026-05-31T19:42:00Z\",\"ci_attempts\":{}}"
  out="$(prtend_state_read 999)"
  echo "$out" | jq -e ".pr == 999 and .forge == \"github\"" >/dev/null
  echo ok
'
# → "ok"; exit 0

# Missing file → empty stdout, exit 0.
bash -c '
  set -euo pipefail
  export XDG_STATE_HOME="$(mktemp -d)"
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-state-lib.bash
  out="$(prtend_state_read 12345)"
  [[ -z "$out" ]] && echo ok
'
# → "ok"; exit 0

# Bad JSON is rejected (exit 2, file untouched).
bash -c '
  set +e
  export XDG_STATE_HOME="$(mktemp -d)"
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-state-lib.bash
  prtend_state_write 999 "not json at all" 2>/dev/null
  rc=$?
  [[ $rc -eq 2 ]] && echo ok
'
# → "ok"; exit 0

# Increment from absent → 1 → 2 → 3 on same signature.
bash -c '
  set -euo pipefail
  export XDG_STATE_HOME="$(mktemp -d)"
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-state-lib.bash
  a="$(prtend_state_increment_ci_attempt 1 eslint:src:no-unused)"
  b="$(prtend_state_increment_ci_attempt 1 eslint:src:no-unused)"
  c="$(prtend_state_increment_ci_attempt 1 eslint:src:no-unused)"
  [[ "$a" == "1" && "$b" == "2" && "$c" == "3" ]] && echo ok
'
# → "ok"; exit 0

# Independent signatures have independent counters.
bash -c '
  set -euo pipefail
  export XDG_STATE_HOME="$(mktemp -d)"
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-state-lib.bash
  prtend_state_increment_ci_attempt 1 sig:a >/dev/null
  prtend_state_increment_ci_attempt 1 sig:a >/dev/null
  prtend_state_increment_ci_attempt 1 sig:b >/dev/null
  ca="$(prtend_state_ci_attempts 1 sig:a)"
  cb="$(prtend_state_ci_attempts 1 sig:b)"
  cc="$(prtend_state_ci_attempts 1 sig:c)"   # never incremented
  [[ "$ca" == "2" && "$cb" == "1" && "$cc" == "0" ]] && echo ok
'
# → "ok"; exit 0

# Cursor round-trip; empty cursor is allowed.
bash -c '
  set -euo pipefail
  export XDG_STATE_HOME="$(mktemp -d)"
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-state-lib.bash
  [[ -z "$(prtend_state_get_cursor 1)" ]]                              # absent → empty
  prtend_state_set_cursor 1 "RR_kwDOAbc123"
  [[ "$(prtend_state_get_cursor 1)" == "RR_kwDOAbc123" ]]
  prtend_state_set_cursor 1 ""                                         # reset
  [[ -z "$(prtend_state_get_cursor 1)" ]]
  echo ok
'
# → "ok"; exit 0

# Clear is idempotent (no file → exit 0; file present → removed → exit 0).
bash -c '
  set -euo pipefail
  export XDG_STATE_HOME="$(mktemp -d)"
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-state-lib.bash
  prtend_state_clear 1                                          # no file
  prtend_state_increment_ci_attempt 1 sig:a >/dev/null
  [[ -f "$(prtend_state_path 1)" ]]
  prtend_state_clear 1
  [[ ! -f "$(prtend_state_path 1)" ]]
  echo ok
'
# → "ok"; exit 0

# Atomic write leaves no temp files behind on success.
bash -c '
  set -euo pipefail
  export XDG_STATE_HOME="$(mktemp -d)"
  source lib/prtend/prtend-lib.bash
  source lib/prtend/prtend-state-lib.bash
  prtend_state_write 1 "{\"pr\":1,\"forge\":\"github\",\"subscribed_at\":\"x\",\"ci_attempts\":{}}"
  dir="$(prtend_state_dir)"
  # No .prtend.XXXXXX leftovers
  ! ls -A "$dir" | grep -q "^\.prtend\." && echo ok
'
# → "ok"; exit 0

# Dispatcher remains healthy (lib is NOT sourced by bin/prtend in this step).
bin/prtend --help
bin/prtend --version
# → unchanged behaviour; exit 0
```

If `prtend_state_dir` returns a path that requires `git rev-parse` (i.e. you're testing outside an XDG-configured shell and inside the repo), the smoke tests above will write to `.claude/prtend-state/` — that directory is gitignored from step 01, so check `git status` is clean afterward.

## Done

- [ ] `lib/prtend/prtend-state-lib.bash` defines all eight public functions (`prtend_state_path`, `prtend_state_read`, `prtend_state_write`, `prtend_state_increment_ci_attempt`, `prtend_state_ci_attempts`, `prtend_state_set_cursor`, `prtend_state_get_cursor`, `prtend_state_clear`)
- [ ] Every write goes through `prtend_atomic_write`; no direct `>` redirects in the file
- [ ] `prtend_state_write` validates JSON via `jq -e .` before writing
- [ ] `prtend_state_increment_ci_attempt` creates the file with seed shape if absent, returns the new count on stdout
- [ ] `prtend_state_read` and `prtend_state_get_cursor` exit 0 with empty stdout when the file is absent
- [ ] `prtend_state_clear` is idempotent (`rm -f`)
- [ ] Lib refuses to load without `prtend-lib.bash` sourced first (parity with `prtend-forge-lib.bash`)
- [ ] No new dependency on `prtend-forge-lib.bash`; `forge` field reads `$PRTEND_FORGE` with `"unknown"` fallback
- [ ] `shellcheck` clean on the new lib and unchanged dispatcher / other libs
- [ ] `bin/prtend` is unchanged — state lib is sourced by subcommands starting in step 07, not by the dispatcher
- [ ] One commit on a feature branch: `docs(steps): add step-05-state` for the plan, then the implementation commit later: `feat(state): add per-PR state lib`
