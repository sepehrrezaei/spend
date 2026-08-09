import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend/core/providers.dart';
import 'package:spend/data/db/database.dart';
import 'package:spend/data/repositories/budget_repository.dart';
import 'package:spend/domain/entities/budget_definition.dart';
import 'package:spend/features/budgets/budget_editor.dart';

/// The budget editor is the one screen where a single wrong write silently
/// doubles a limit the user thought they had moved, so it gets its own test.
void main() {
  late SpendDatabase db;
  late BudgetRepository budgets;

  setUp(() {
    db = SpendDatabase.memory();
    budgets = BudgetRepository(db);
  });
  tearDown(() => db.close());

  /// Pumps a bare host that opens the editor, so the test exercises the dialog
  /// rather than the whole app shell.
  Future<void> openEditor(
    WidgetTester tester, {
    BudgetDefinition? existing,
  }) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showBudgetEditor(context, existing: existing),
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

  /// Picks a value in the "Applies to" dropdown by its visible label.
  Future<void> chooseCategory(WidgetTester tester, String name) async {
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
  }

  /// Unmounts inside the test body and lets drift's cleanup timer run.
  ///
  /// Cancelling a drift query stream schedules a zero-duration timer. Left to
  /// the framework's own teardown it is created after the body finishes and
  /// the binding fails with "Pending timers"; advancing the clock by a
  /// millisecond here gives it somewhere to run.
  Future<void> disposeHost(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('re-pointing a budget at another category moves it', (
    tester,
  ) async {
    await openEditor(tester);
    await chooseCategory(tester, 'Groceries');
    await tester.enterText(find.byType(TextField), '400');
    await save(tester);

    final created = await budgets.active();
    expect(created, hasLength(1));

    // Now edit that budget and change which category it applies to. setLimit
    // keys on the category, so without an explicit move this wrote a second
    // budget and left the first one live — two limits from one edit.
    await openEditor(tester, existing: created.single);
    await chooseCategory(tester, 'Dining');
    await save(tester);

    final after = await budgets.active();
    expect(after, hasLength(1), reason: 'moved, not cloned');
    expect(after.single.categoryId, isNot(created.single.categoryId));
    await disposeHost(tester);
  });

  testWidgets('editing a budget without moving it still leaves one', (
    tester,
  ) async {
    await openEditor(tester);
    await chooseCategory(tester, 'Groceries');
    await tester.enterText(find.byType(TextField), '400');
    await save(tester);

    final created = await budgets.active();
    await openEditor(tester, existing: created.single);
    await tester.enterText(find.byType(TextField), '500');
    await save(tester);

    final after = await budgets.active();
    expect(after, hasLength(1));
    expect(after.single.limit.minor, 50000);
    expect(after.single.categoryId, created.single.categoryId);
    await disposeHost(tester);
  });
}
