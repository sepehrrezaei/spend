# Spend

A local-first expense tracker for macOS. Flutter/Dart, SQLite via drift, Riverpod for DI.
No server, no account, no network dependency except an optional local model.

`CONTRIBUTING.md` holds the full rules. This file is the short version plus the things
only learned by getting them wrong.

## The five rules

1. **Money is an integer.** `Money` is a signed `int` of minor units. A `double` must not
   touch an amount before the formatting layer. `0.1 + 0.2 != 0.3`, and a ledger that
   disagrees with itself by a cent is worthless.
2. **Dates are `Day`, not `DateTime`.** A purchase happens on a calendar date. A
   `DateTime` slides a late-night entry into the next month after a DST change.
3. **`domain/` imports nothing from Flutter.**
4. **The model never computes anything.** Every figure shown to a user comes from
   `AnalyticsEngine`, `InsightRules` or a `ChatTools` query. Amounts cross into a prompt
   in major units, ratios as whole percentages, ambiguity refused rather than guessed.
5. **Desktop-only code sits behind a capability.** `AppPlatform.supportsMenuBar` or
   `supportsLocalAi`, never a raw `Platform.isMacOS`.

**Nothing mechanical enforces these.** `analysis_options.yaml` is stock `flutter_lints`;
six deliberate violations once passed the whole gate. They hold only as long as review
holds.

## Test layers

| Layer | Runs under | Covers |
|---|---|---|
| `test/core`, `test/domain` | plain Dart | arithmetic, boundaries, parsing — the bulk, deliberately |
| `test/data` | in-memory drift | schema, backup format, queries |
| `test/widget` | `flutter test` | layout and dialogs, no plugins registered |
| `integration_test` | `flutter test -d macos` | the real app: registered plugins, a real SQLite file, real bytes on disk |

`flutter test` registers no plugins, so everything under `test/` stubs `path_provider` and
uses `SpendDatabase.memory()`. The end-to-end suite covers the seam the others fake.

## Gates

Run them via the `run-the-gates` skill — order matters, because formatting runs before
tests in CI and a slip means no test executes.

Xcode may need `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## The team

`.claude/` holds a project-specific team. The split is deliberate:

- **`.claude/skills/`** — *procedures*, each carrying `source:` for the incident that
  earned it. Shared, so a rule lives in one place instead of three agent files.
- **`.claude/agents/`** — *roles*, thin, referencing skills rather than restating them.
- **`.claude/team/`** — *memory*. `LEARNED.md` is what went wrong and why the rule exists.
  `DECISIONS.md` is what reached the human and what they said.

| Agent | For |
|---|---|
| `project-manager` | Sequencing and dispatch; escalates decisions rather than making them |
| `reviewer` | A diff, against this repo's rules and its history of mistakes |
| `security-reviewer` | Untrusted files, the loopback boundary, entitlements, queries |
| `money-guard` | Amounts, dates, analytics, anything crossing into a prompt |
| `layout-scout` | Changed screens across the widths this app runs at |
| `verifier` | Proving a test fails against the old code before it is trusted |
| `release-steward` | Gates, rulesets, merges |

Two rules that shape how the team works, both earned:

**The author does not certify their own fix.** Two consecutive PRs here shipped a bug
inside the fix for the previous bug, each reviewed by its own author.

**A confident comment is a reason to look harder.** In a trial against disguised
violations, four comments defended broken code and none was accurate.

Start with `project-manager` for anything spanning more than one file. Append to
`LEARNED.md` when a correction lands, and to `DECISIONS.md` when a question reaches a
human — otherwise the next session relearns it.
