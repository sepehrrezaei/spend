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

  late _SearchWatcher watcher;

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    watcher = _SearchWatcher();
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
    return container;
  }

  Future<void> disposeHost(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
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
    await disposeHost(tester);
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
    await disposeHost(tester);
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
    await disposeHost(tester);
  });

  testWidgets('a search with no matches says so', (tester) async {
    await seed(4);
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'Nowhere');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('Albert Heijn'), findsNothing);
    expect(tester.takeException(), isNull);
    await disposeHost(tester);
  });
}

/// Counts live search-provider instances by observing the container.
///
/// `getAllProviderElements` is not public API in Riverpod 3, and a leak is
/// about lifecycle rather than a snapshot anyway: this counts what was created
/// against what was disposed, which is the thing that actually went wrong.
base class _SearchWatcher extends ProviderObserver {
  final _alive = <String>{};

  /// Search providers are the family-scoped ones taking a String argument.
  String? _term(ProviderObserverContext context) {
    final arg = context.provider.argument;
    return arg is String ? arg : null;
  }

  int get live => _alive.length;

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    final term = _term(context);
    if (term != null) _alive.add(term);
  }

  @override
  void didDisposeProvider(ProviderObserverContext context) {
    final term = _term(context);
    if (term != null) _alive.remove(term);
  }
}
