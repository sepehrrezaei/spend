# Contributing

Thanks for looking. This is a small, opinionated app — the guidance below is
mostly about the few places where being casual would break something quietly.

## Getting set up

```bash
git clone https://github.com/sepehrrezaei/spend.git
cd spend
flutter pub get
flutter test
flutter run -d macos
```

You need macOS 13+, Flutter 3.44+, and Xcode. If `xcodebuild` can't find Xcode,
see the note in the [README](README.md#quick-start).

After changing anything under `lib/data/db/`, regenerate the Drift code:

```bash
dart run build_runner build
```

## Before opening a pull request

```bash
dart format .
flutter analyze     # must be clean
flutter test        # must be green
```

## The rules that actually matter

### 1. No floating-point money

Amounts are `Money` — a signed `int` of minor units. A `double` must never touch
an amount before the formatting layer.

```dart
// no
final total = items.fold(0.0, (a, b) => a + b.amount.major);

// yes
final total = items.map((i) => i.amount).sum();
```

This is not stylistic. `0.1 + 0.2 != 0.3`, and a ledger that disagrees with
itself by a cent is worthless.

### 2. No `DateTime` for transaction dates

Use `Day`. A purchase happens on a calendar date, not an instant, and a
`DateTime` will eventually slide a late-night entry into the next month after a
DST change.

### 3. `domain/` imports nothing from Flutter

If you find yourself needing `BuildContext` or a `Color` in `domain/`, the logic
belongs in `features/`, or the value should be passed in. `InsightRules` takes a
`String Function(Money)` formatter for exactly this reason.

### 4. The model never computes anything

Any figure shown to the user must be computed by `AnalyticsEngine`,
`InsightRules` or a `ChatTools` query. The language model rewrites facts; it does
not produce them. If a change would let a model add, subtract or estimate a
number that reaches the UI, it will be asked to change.

Corollaries worth knowing:

- Amounts crossing into a prompt go in **major units**, with the `_minor` suffix
  stripped. Otherwise the model writes `€10466` for `10466` cents.
- Ratios go as whole percentages. `10.476` gets read as "10.476 times".
- Anything ambiguous is refused rather than guessed. A wrong category returns a
  confidently wrong number; an error lets the model recover.

### 5. Desktop-only code sits behind a capability

Check `AppPlatform.supportsMenuBar` or `supportsLocalAi`, not `Platform.isMacOS`.
It keeps the reason readable and keeps a future iOS build a rebuild rather than a
rewrite.

## Tests

Put the effort where a mistake would be invisible in the UI. The existing suite
is weighted heavily toward arithmetic and boundaries, and thinly toward widgets —
that is deliberate.

Good things to test:

- Month boundaries, leap days, DST transitions
- Partial periods and like-for-like comparison
- Anything that parses user or bank input
- Anything that could silently lose or duplicate data

A test name should say what the code guarantees, not what the method is called:

```dart
// no
test('addMonths works', ...)

// yes
test('month-end dates land on the last valid day', ...)
```

## Commits and pull requests

- One concern per pull request.
- Explain **why** in the description; the diff already shows what.
- If you fixed a bug, add the test that would have caught it. Several tests in
  this repo exist because the bug actually happened, and the comments say so —
  that context is worth keeping.

## Reporting bugs

Include your macOS version, `flutter --version`, and what you expected instead.

If it involves your own spending data, **don't attach a backup** — it is your
complete financial history. A description or a redacted example is plenty.

## Ideas that are welcome

- iOS and iPad support (the structure is there; see the roadmap)
- Better bank CSV coverage — new formats are easy to add in `csv_service.dart`
- Accessibility, keyboard navigation, VoiceOver
- Anything that reduces the friction of logging a transaction

## Ideas that need discussion first

- Multi-currency. It needs FX rates, which needs either a network call — breaking
  the offline guarantee — or manually maintained rates. Open an issue before
  building it.
- Bank sync. Same reason, more so.
- Cloud sync of any kind.
