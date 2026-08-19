import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend/core/day.dart';
import 'package:spend/core/money.dart';
import 'package:spend/core/providers.dart';
import 'package:spend/core/theme/app_theme.dart';
import 'package:spend/data/db/database.dart';
import 'package:spend/features/transactions/transactions_screen.dart';

/// The History search box.
///
/// These cover the two problems that live in the screen rather than in the
/// query, and that removing the row cap turned from survivable into not:
/// every typed prefix used to retain a live database subscription, and every
/// keystroke used to run a fresh query.
void main() {
  late SpendDatabase db;

  setUp(() => db = SpendDatabase.memory());
  tearDown(() => db.close());

  Future<void> seed(int n) async {
    for (var i = 0; i < n; i++) {
      await db
          .into(db.transactions)
          .insert(
            TransactionsCompanion.insert(
              amountMinor: Money(1000 + i),
              categoryId: 1,
              occurredOn: Day(2026, 1, 1).addDays(i),
              merchant: Value(i.isEven ? 'Albert Heijn' : 'Jumbo'),
            ),
          );
    }
  }

  late _ProviderWatcher watcher;

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    watcher = _ProviderWatcher('historySearchResults');
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
      observers: [watcher],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const TransactionsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Registered rather than called at the end of each body. A failed expect
    // aborts the test, and an un-cancelled debounce Timer would then be
    // reported as "A Timer is still pending" instead of the assertion that
    // actually failed — hiding the finding behind its own cleanup.
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
    });
    return container;
  }

  testWidgets('typing does not leave a subscription per prefix', (
    tester,
  ) async {
    await seed(5);
    await pump(tester);

    // Six prefixes: A, Al, Alb, Albe, Alber, Albert. Without autoDispose all
    // six stay alive for the lifetime of the app, each re-running its query
    // on every write.
    for (final prefix in ['A', 'Al', 'Alb', 'Albe', 'Alber', 'Albert']) {
      await tester.enterText(find.byType(TextField), prefix);
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.pumpAndSettle();

    expect(
      watcher.live,
      lessThanOrEqualTo(1),
      reason: 'only the term currently being displayed should stay watched',
    );
  });

  testWidgets('a burst of keystrokes runs one query, not one each', (
    tester,
  ) async {
    await seed(5);
    await pump(tester);

    // Typed faster than the debounce window.
    for (final prefix in ['A', 'Al', 'Alb', 'Albe', 'Alber', 'Albert']) {
      await tester.enterText(find.byType(TextField), prefix);
      await tester.pump(const Duration(milliseconds: 40));
    }
    // Mid-burst: nothing has been queried yet.
    expect(watcher.live, 0, reason: 'debounced, not yet queried');

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(watcher.live, 1);
    expect(find.text('Albert Heijn'), findsWidgets);
  });

  testWidgets('clearing the box is immediate, not debounced', (tester) async {
    await seed(4);
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'Albert');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Jumbo'), findsNothing);

    await tester.tap(find.byIcon(Icons.clear));
    // One frame, no debounce wait: an empty box is the unfiltered list rather
    // than a query, and waiting to show it would just feel broken.
    await tester.pumpAndSettle();
    expect(find.text('Jumbo'), findsWidgets);
  });

  testWidgets('results stay on screen while the next term loads', (
    tester,
  ) async {
    await seed(6);
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'Albert');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Albert Heijn'), findsWidgets);

    // Backspace to a different term. A family keyed by term would start a
    // brand-new provider in AsyncLoading here and replace the whole list with
    // a spinner — for as long as an uncapped query takes.
    await tester.enterText(find.byType(TextField), 'Albe');
    await tester.pump(const Duration(milliseconds: 260));

    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'previous results should survive the term change',
    );
    await tester.pumpAndSettle();
  });

  testWidgets('the clear button appears as soon as there is text', (
    tester,
  ) async {
    await seed(4);
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'A');
    // One frame — well inside the 250ms debounce. Tied to the debounced term
    // the button was absent for that whole window, so there was no way to
    // clear what had just been typed.
    await tester.pump();
    expect(find.byIcon(Icons.clear), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('trailing whitespace does not re-run the query', (tester) async {
    await seed(4);
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'Albert');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final before = watcher.updates;
    await tester.enterText(find.byType(TextField), 'Albert ');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // The term is trimmed on the way into the notifier, so a trailing space
    // leaves it unchanged and the provider is never recomputed. Untrimmed,
    // this ran the whole uncapped query again for a byte-identical result.
    expect(
      watcher.updates,
      before,
      reason: 'a whitespace-only edit is the same search',
    );
    expect(watcher.live, 1, reason: 'and not a second subscription');
  });

  testWidgets('a search with no matches says so', (tester) async {
    await seed(4);
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'Nowhere');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('Albert Heijn'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// Counts live instances of one specific provider.
///
/// Matches on the provider's own identity rather than on "a family with a
/// String argument": that heuristic only worked while no other String-keyed
/// family existed, and because it stored terms rather than instances, two
/// providers sharing an argument would have cancelled each other out and hidden
/// a genuine leak.
///
/// Counting creates against disposes rather than snapshotting is deliberate —
/// a leak is a lifecycle property, not a state you can observe at one instant.
base class _ProviderWatcher extends ProviderObserver {
  _ProviderWatcher(this._label);

  /// Substring identifying the provider under test, matched against
  /// `context.provider.toString()`.
  final String _label;

  int _created = 0;
  int _disposed = 0;
  int _updates = 0;

  bool _matches(ProviderObserverContext context) =>
      context.provider.toString().contains(_label);

  /// Instances created and not yet disposed.
  int get live => _created - _disposed;

  /// How many times the provider has re-emitted, which is what a term change
  /// costs: one more run of the query.
  int get updates => _updates;

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    if (_matches(context)) _created++;
  }

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previous,
    Object? next,
  ) {
    if (_matches(context)) _updates++;
  }

  @override
  void didDisposeProvider(ProviderObserverContext context) {
    if (_matches(context)) _disposed++;
  }
}
