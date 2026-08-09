import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend/core/providers.dart';
import 'package:spend/data/csv/csv_service.dart';
import 'package:spend/data/db/database.dart';
import 'package:spend/domain/entities/enums.dart';
import 'package:spend/features/settings/csv_import_dialog.dart';

/// A bank export with two same-day fares and a salary credit — the three cases
/// that were being imported wrongly.
const _csv = '''
Date,Amount,Description
2026-07-25,-3.20,GVB
2026-07-25,-3.20,NS
2026-07-25,-12.40,Albert Heijn
2026-07-25,2500.00,Salary
''';

void main() {
  late SpendDatabase db;

  setUp(() => db = SpendDatabase.memory());
  tearDown(() => db.close());

  Future<void> openDialog(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final table = const CsvService().parseTable(_csv);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showCsvImportDialog(
                    context,
                    table: table,
                    fileName: 'bank.csv',
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String label, String value) async {
    await tester.tap(find.widgetWithText(DropdownButtonFormField<int>, label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(value).last);
    await tester.pumpAndSettle();
  }

  Future<void> import(WidgetTester tester) async {
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is FilledButton && w.enabled,
        description: 'the Import button',
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> disposeHost(WidgetTester tester) async {
    // Drift schedules a zero-duration timer when a query stream is cancelled;
    // unmounting here rather than at teardown gives it somewhere to run.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('a credit lands in an income category as a positive amount', (
    tester,
  ) async {
    await openDialog(tester);
    await choose(tester, 'Category for imported rows', 'Groceries');
    await choose(tester, 'Category for credits', 'Income');
    await import(tester);

    final rows = await db.select(db.transactions).get();
    final categories = await db.select(db.categories).get();
    final income = categories.firstWhere((c) => c.kind == CategoryKind.income);

    final salary = rows.firstWhere((r) => r.merchant == 'Salary');
    // Filed under an expense category with its negative amount, a salary reads
    // as a refund and *reduces* the month's spending.
    expect(salary.categoryId, income.id);
    expect(salary.amountMinor.minor, 250000, reason: 'positive magnitude');

    await disposeHost(tester);
  });

  testWidgets(
    'credits are skipped, not mis-filed, when no category is picked',
    (tester) async {
      await openDialog(tester);
      await choose(tester, 'Category for imported rows', 'Groceries');
      await import(tester);

      final rows = await db.select(db.transactions).get();
      expect(rows, hasLength(3), reason: 'the three expenses only');
      expect(rows.every((r) => r.merchant != 'Salary'), isTrue);
      expect(find.textContaining('1 credits skipped'), findsOneWidget);

      await disposeHost(tester);
    },
  );

  testWidgets('two same-day fares of the same amount both survive', (
    tester,
  ) async {
    await openDialog(tester);
    await choose(tester, 'Category for imported rows', 'Groceries');
    await import(tester);

    final rows = await db.select(db.transactions).get();
    final fares = rows.where((r) => r.amountMinor.minor == 320).toList();
    // De-duplicating on date+amount+category alone collapsed these into one.
    expect(fares, hasLength(2));
    expect(fares.map((r) => r.merchant).toSet(), {'GVB', 'NS'});

    await disposeHost(tester);
  });
}
