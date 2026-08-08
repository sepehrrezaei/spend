# Architecture

How the pieces fit, and why they were chosen that way. Start with the
[README](../README.md) for what the app does; this is for changing it.

## Layers

```
lib/
├── core/       Money, Day, DateRange, theme, formatting, DI, platform
├── domain/     Entities + analytics — pure Dart, imports nothing from Flutter
├── data/       Drift schema, repositories, backup, CSV
├── ai/         Optional model layer: providers, tools, prompts
└── features/   One folder per screen
```

Dependencies point downward only. `features/` may use anything; `domain/` may
use only `core/`; `core/` uses nothing of ours.

### Why `domain/` is Flutter-free

It is the difference between a test that runs in one millisecond from a list of
literals, and one that needs a widget harness, a database and a pumped frame.
77 of the 177 tests live here and the whole file runs in well under a second.

It is also what makes a future iOS build a rebuild rather than a rewrite: none
of the arithmetic knows what it is running on.

## The two invariants

### Money

`Money` wraps a signed `int` of minor units. Addition, subtraction, scaling and
comparison are all exact. Division returns `Money` with explicit rounding;
`ratioTo` returns a nullable `double` because a ratio is not money — and returns
`null` rather than infinity when the denominator is zero, so "no budget set"
cannot render as a full progress bar.

Parsing is deliberately liberal, because typing speed is what makes or breaks an
expense tracker. `12.40` and `12,40` both work — the comma is the decimal
separator in the Netherlands. Where both separators appear, the rightmost is the
decimal. Three trailing digits read as digit grouping (`12,345` → €12,345) but
only where a grouped number is plausible: `0,005` keeps its fraction, because
nobody groups thousands starting from zero.

Structurally broken input is rejected rather than salvaged. `1,2,3.4.5` returns
`null` instead of quietly becoming €1234.50 — a bug that existed and is now a
test.

### Day

Year, month, day. No time, no zone. Persisted as ISO `YYYY-MM-DD` text.

`addMonths` clamps to the end of the target month: 31 January plus one month is
28 February, not 3 March. Without that, a monthly charge dated the 31st skips
February entirely and drifts forward every year. Clamping is not cumulative —
each step is computed from the original anchor, so March returns to the 31st.

## Data

Drift with two type converters, so the generated row classes carry `Money` and
`Day` directly and the type safety reaches the database boundary.

Foreign keys are enabled explicitly in `beforeOpen` — SQLite ships with them
off, and without the pragma the `RESTRICT` and `SET NULL` actions declared in
the schema are inert. There is a test that asserts deleting a category with
history throws, precisely so a regression there cannot pass silently.

The database lives in Application Support, not Documents. Documents is
user-facing space, and on iOS the default would put a live SQLite file into
iCloud sync.

### Backup format

A `.spendbak` is a zip of `manifest.json` + `data.json`.

JSON rather than a copy of the SQLite file. A raw database copy is easier to
produce but nearly impossible to restore into a *different* schema version, and
it cannot be inspected or hand-repaired. Plain text means a backup taken today
is readable by a future version that has since migrated — and by you in a text
editor if this app ever stops working, which is the entire point of owning your
own data.

The manifest carries a SHA-256 of the payload. `inspect()` validates everything
*before* `restore()` touches the database, so a corrupt file cannot damage live
data. Newer schema versions are refused outright; older ones are accepted for
migration.

Merging matches categories **by name**, because the same "Groceries" on two
machines will have different ids. Transactions dedupe on a natural key of date,
amount, category, merchant and note. Budgets are not merged at all — a limit is
a current intention, not history, and silently combining two machines' limits
would produce a figure the user never chose.

## Analytics

`AnalyticsEngine.summarise` takes records and a range and returns a
`PeriodSummary`. Three details are load-bearing:

**Elapsed days, not period days.** On the 3rd of the month, dividing by 31 would
understate the daily average tenfold. Projection uses the same figure.

**Like-for-like comparison.** A half-finished month compared against a complete
previous month always looks like a decrease. The engine truncates the comparison
window to the same elapsed length automatically.

**A separate discretionary series.** Rent lands once and is roughly twenty times
a normal day's spending; on a shared axis it flattens every other bar to nothing
and yanks the average line off the top of the chart. The daily chart plots
`dailyDiscretionary` and says so.

### Budget health

Classified on **pace** — spend rate against time rate — with tolerance bands,
not on a bare projection comparison:

| Pace | Meaning |
|---|---|
| ≤ 1.05 | on track |
| 1.05 – 1.15 | worth a glance |
| > 1.15 | genuinely heading over |
| spent > limit | exceeded |

Comparing `projected > limit` directly is far too twitchy: on the 15th of a
31-day month, spending exactly half the budget projects 3% over and would raise
a warning about essentially perfect pacing.

## The AI layer

```
AiProvider (interface)
├── OllamaProvider   HTTP to 127.0.0.1:11434
└── NullAiProvider   not an error state — the normal state without a model
```

Insights and chat differ in shape:

- **Insights** hands the model a `FinanceBrief` — a closed set of already-computed
  values — and asks for prose. One round trip.
- **Chat** gives the model five query tools and no data. It picks one, Dart runs
  the real query, and the exact figures come back for it to phrase. Two round
  trips.

Both share the rule: **anything the model says that is not traceable to a
computed value is a fabrication.** The chat UI shows the queries under every
answer so that is checkable rather than assumed.

### Defensive details that exist because they had to

- Amounts crossing into the model are converted from minor to major units and
  the `_minor` suffix stripped, or it writes `€10466` for `10466` cents.
- Tool arguments are repaired, not rejected: models emit `2026-7-1` and swap
  `from`/`to` routinely, and failing the whole answer over that costs a
  30-second retry.
- Category names match fuzzily but **only when unambiguous**. `grocery` finds
  `Groceries`; anything matching two categories is refused. A wrong category
  returns a confidently wrong number, whereas an error sends the model to
  `list_categories` and it recovers.

## Platform

`core/platform.dart` names capabilities rather than platforms:

```dart
AppPlatform.supportsLocalAi      // desktop only
AppPlatform.supportsMenuBar      // desktop only
AppPlatform.hasKeyboardShortcuts // drives "⏎ to save" vs "Save"
```

Features are gated on a named capability so the reason a thing is hidden stays
readable at the call site. `AppDestination.available` filters the navigation,
and both the router branches and the navigation bar are built from that one
list — their indices cannot drift apart.

### macOS specifics

Three defaults had to be changed, each of which looks fine until you test with
another app frontmost:

- `applicationShouldTerminateAfterLastWindowClosed` returns `false`. Flutter's
  default is `true`, and *hiding* a window counts as closing it, so the app
  quit the first time the capture panel dismissed itself.
- `WindowModes.enterCompact` ends with `show()` and never calls `focus()` after
  it. window_manager's `focus()` uses `NSApp.activate(ignoringOtherApps: false)`,
  a no-op while another app is frontmost — exactly when a global shortcut fires.
- The capture panel has no `Focus(autofocus: true)` wrapper, which would beat
  the `TextField` to focus and leave the panel open with keystrokes going
  nowhere.

Entitlements: `network.client` for the local model, and
`files.user-selected.read-write` for backups. Both in Debug and Release.

Category icons are stored by **name**, resolved through a const table. Release
builds tree-shake the icon font, and an `IconData` built from a stored integer
renders as a blank box in release while looking perfect in debug.

## Regenerating code

After changing anything under `lib/data/db/`:

```bash
dart run build_runner build
```

`database.g.dart` is committed so a fresh clone builds and tests without this
step.
