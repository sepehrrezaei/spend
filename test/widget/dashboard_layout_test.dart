import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend/core/day.dart';
import 'package:spend/core/money.dart';
import 'package:spend/core/providers.dart';
import 'package:spend/data/db/database.dart';
import 'package:spend/features/dashboard/dashboard_screen.dart';

/// Overflow guards for the dashboard at phone widths.
///
/// The existing widget tests all run on a 1280x900 surface, which is why three
/// separate RenderFlex overflows shipped without CI noticing. A `RenderFlex
/// overflowed` error is reported to the framework rather than thrown, so it
/// surfaces here through `tester.takeException()`.
void main() {
  late SpendDatabase db;

  setUp(() => db = SpendDatabase.memory());
  tearDown(() => db.close());

  /// The dashboard needs data: an empty period renders a placeholder instead
  /// of the charts, which would make every one of these tests pass vacuously.
  Future<void> seed() async {
    for (var i = 0; i < 12; i++) {
      await db
          .into(db.transactions)
          .insert(
            TransactionsCompanion.insert(
              amountMinor: Money(1240 + i * 100),
              categoryId: (i % 4) + 1,
              occurredOn: Day.today().firstOfMonth.addDays(i),
              merchant: Value('Merchant $i'),
            ),
          );
    }
    // A recurring cost, so the chart header renders its "excl. … recurring"
    // note — the widest of its four items and the one that overflowed.
    await db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            amountMinor: Money(120000),
            categoryId: 4,
            occurredOn: Day.today().firstOfMonth,
            merchant: const Value('Landlord'),
          ),
        );
  }

  Future<void> pumpAt(
    WidgetTester tester,
    Size size, {
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: const DashboardScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> disposeHost(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// Widths worth pinning, and why each one is here.
  const widths = <String, double>{
    'iPhone portrait': 402, // where the 328pt and 84pt overflows appeared
    'iPhone landscape': 874,
    'iPad portrait': 834,
    'iPad landscape': 1194,
    // 730-762 is the band where the AppBar height and the bar's own layout
    // used to disagree, stacking the bar under a slot sized for one row.
    'inside the old disagreement band': 745,
    'at its upper edge': 762,
    'desktop': 1280,
    'wide desktop': 1600,
  };

  for (final entry in widths.entries) {
    testWidgets('lays out without overflow at ${entry.key}', (tester) async {
      await seed();
      await pumpAt(tester, Size(entry.value, 900));

      expect(
        tester.takeException(),
        isNull,
        reason: '${entry.key} (${entry.value}pt) overflowed',
      );
      await disposeHost(tester);
    });
  }

  testWidgets('the title survives the stacked bar', (tester) async {
    await seed();
    await pumpAt(tester, const Size(402, 900));

    // The regression this guards is the AppBar reserving the single-row height
    // while the bar stacked, which pushed the title out of its own slot.
    expect(find.text('Overview'), findsOneWidget);
    final title = tester.getRect(find.text('Overview'));
    expect(title.top, greaterThanOrEqualTo(0));
    expect(title.height, greaterThan(0));
    await disposeHost(tester);
  });

  testWidgets('survives an accessibility text scale', (tester) async {
    await seed();
    await pumpAt(tester, const Size(402, 900), textScale: 1.8);

    expect(tester.takeException(), isNull);
    await disposeHost(tester);
  });
}
