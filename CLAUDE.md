# Spend

A local-first expense tracker for macOS. Flutter/Dart, SQLite via drift, Riverpod
for DI. No server, no account, no network dependency except an optional local
model.

`CONTRIBUTING.md` holds the full rules and is worth reading before a first
change. This file is the short version, plus the things that are only learned by
getting them wrong.

## The five rules

1. **Money is an integer.** `Money` is a signed `int` of minor units. A `double`
   must not touch an amount before the formatting layer. `0.1 + 0.2 != 0.3`, and
   a ledger that disagrees with itself by a cent is worthless.
2. **Dates are `Day`, not `DateTime`.** A purchase happens on a calendar date,
   not an instant. A `DateTime` slides a late-night entry into the next month
   after a DST change.
3. **`domain/` imports nothing from Flutter.** If you need a `BuildContext` or a
   `Color` there, the logic belongs in `features/` or the value should be passed
   in.
4. **The model never computes anything.** Every figure shown to a user comes
   from `AnalyticsEngine`, `InsightRules` or a `ChatTools` query. Amounts cross
   into a prompt in major units; ratios as whole percentages; anything ambiguous
   is refused rather than guessed.
5. **Desktop-only code sits behind a capability.** `AppPlatform.supportsMenuBar`
   or `supportsLocalAi`, never a raw `Platform.isMacOS`.

## How work is verified here

This is the part that is not in `CONTRIBUTING.md`, because it was learned the
expensive way. Several bugs in this repository shipped inside the fix for the
previous bug, and every one was caught by running something rather than reading
it.

- **A new test must be shown to fail against the old code.** Break the thing
  deliberately, watch the test go red, revert. A test that has never failed has
  not been tested — three tests written here passed while asserting nothing, and
  each was caught only by breaking the code they were supposed to guard.
- **Waiting on one condition usually asserts nothing.** A wait for something
  already on screen returns on the first frame; a wait for something to
  disappear passes mid-query when the list is briefly empty. Wait on the
  conjunction.
- **The comment is where to be most suspicious.** Three separate defects here
  were defended by a confident comment explaining why the wrong thing was right.

## Test layers, and what each is for

| Layer | Runs under | Covers |
|---|---|---|
| `test/core`, `test/domain` | plain Dart | arithmetic, boundaries, parsing — the bulk of the suite, deliberately |
| `test/data` | in-memory drift | schema, backup format, queries |
| `test/widget` | `flutter test` | layout and dialogs, no plugins registered |
| `integration_test` | `flutter test -d macos` | the real app: registered plugins, a real SQLite file, real bytes on disk |

`flutter test` registers no plugins, so everything under `test/` stubs
`path_provider` and uses `SpendDatabase.memory()`. That is why the end-to-end
suite exists — it covers the seam the others deliberately fake.

## Gates

```bash
dart format --set-exit-if-changed .
flutter analyze --fatal-infos      # --fatal-infos is not optional; CI runs it
flutter test
flutter test -d macos integration_test
```

`main` requires all three CI checks green, with no bypass for anyone. A second
ruleset requires a maintainer's approval, which admins may bypass — that is how
the owner self-merges while contributions still need review.

Xcode may need `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Agents

`.claude/agents/` holds project-specific agents. They exist because the generic
ones cannot know rule 1 or rule 4. Start with `project-manager` for anything
spanning more than one file.
