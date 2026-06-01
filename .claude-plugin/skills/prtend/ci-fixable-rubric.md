# CI failure: fixable or ask?

When `prtend watch` returns a CI event with `state == "failure"`, evaluate each failure object and decide whether to attempt an automatic fix or escalate.

## Fixable — attempt the fix

- **Lint errors** (ESLint, RuboCop, Clippy, Flake8, golint). The rule name plus file location is usually enough.
- **Formatting** (Prettier, gofmt, black, rustfmt). Run the formatter, commit the result.
- **Simple type errors** (TypeScript, mypy, type-checked Python, Rust): missing imports, simple parameter mismatches, obvious narrowing.
- **Missing imports**: clear `ImportError` / `module not found`; resolution is adding the import.
- **Tests broken by your own changes**: the test exercises a function you just modified, and the failure clearly reflects the API change you introduced. (The test should be updated; not always — see "gray areas".)
- **Snapshot mismatches** from changes you made: rerun, commit new snapshots.
- **Simple syntax errors** introduced by an edit: missing parenthesis, semicolon, etc.

## Not fixable — escalate

- **Infra flakes**: "Lost connection to runner", "Docker daemon not responding", CI provider 500s.
- **Credentials / auth**: token expired, missing secret, permission denied. You can't get new credentials.
- **External service down**: tests depending on third-party APIs the CI can't reach.
- **Test failures in code you haven't touched** and can't reason about.
- **Build environment issues**: missing OS packages, kernel-level issues, platform behavior.
- **Logic errors needing domain context**: the test correctly catches a bug you introduced, but understanding why requires context only the user has.
- **Anything where your attempt would be a guess**: if you can't form a confident hypothesis from the log, escalate.

## Gray areas — attempt once, then escalate

- **Flaky test, first instance**: re-push retries CI. After signature hits 2+ attempts, escalate as "looks flaky" — let the user decide retry / disable / fix.
- **Test failing in code you transitively affected**: a recent commit touched a shared module, an unrelated test now fails. One attempt is fine; on retry, escalate.
- **Refactor-induced breakage**: you changed a function's signature, several call sites' tests now fail. One sweeping fix is fine; if it doesn't take, the refactor probably needs reconsidering.

## When in doubt

Default to escalation. The 3-retry cap bounds *attempts*, not *certainty* — a confident "fixable" attempt that fails doesn't become a less-confident attempt; it becomes evidence the original judgment was off. After three tries, surface and let the user decide.

## Signature format (for context)

prtend's `failure.signature` follows `<tool>:<scope>:<short-rule>`. Examples:

- `eslint:src-widget-tsx:no-unused-vars`
- `jest:reducer-spec:NaN-NaN`
- `mypy:src-models-py:incompatible-return-type`

You don't compose signatures (prtend does); but you read them to recognize when the same failure is recurring.
