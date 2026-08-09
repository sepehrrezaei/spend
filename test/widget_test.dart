import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend/app.dart';
import 'package:spend/core/providers.dart';
import 'package:spend/data/db/database.dart';

/// Boots the real app against a throwaway in-memory database.
///
/// Overriding [databaseProvider] alone is enough to redirect the entire
/// dependency graph, since every repository resolves through it.
Future<void> pumpApp(WidgetTester tester, SpendDatabase db) async {
  // A realistically sized desktop window. The 800x600 default test surface is
  // smaller than any window this app runs in, and it pushes the entry form's
  // save button off-screen, which makes taps silently miss.
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        // The Settings screen reads the filesystem and the app bundle through
        // platform channels that do not exist under `flutter test`. Stubbing
        // them keeps this a test of the UI rather than of plugin registration.
        autoSnapshotsProvider.overrideWith(
          (ref) => Future.value(const <FileSystemEntity>[]),
        ),
        appVersionProvider.overrideWith((ref) => Future.value('test')),
      ],
      child: const SpendApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// Taps a destination in the navigation rail.
///
/// [NavigationRailDestination] is a configuration object rather than a widget,
/// so it never appears in the tree and cannot be found directly. Scoping to
/// the rail also avoids matching the same label in a screen's app bar.
Future<void> tapRail(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

/// Unmounts the app inside the test body, then flushes drift's cleanup timer.
///
/// Cancelling a drift query stream schedules a zero-duration timer. If the
/// tree is still mounted when the test body ends, that timer is created during
/// teardown and the binding fails with "Pending timers". Tearing down
/// explicitly and pumping once gives it a chance to run.
Future<void> disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  // Advance the fake clock rather than just pumping a frame: a bare pump()
  // schedules a frame without moving time, so a zero-duration timer stays
  // queued and the binding still reports it as pending.
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  late SpendDatabase db;

  setUp(() => db = SpendDatabase.memory());
  tearDown(() => db.close());

  testWidgets('boots to the overview without error', (tester) async {
    await pumpApp(tester, db);
    expect(find.text('Overview'), findsWidgets);
    expect(tester.takeException(), isNull);
    await disposeApp(tester);
  });

  testWidgets('every navigation destination opens', (tester) async {
    await pumpApp(tester, db);

    for (final d in AppDestination.available) {
      await tapRail(tester, d.label);
      expect(
        tester.takeException(),
        isNull,
        reason: '${d.label} should open without throwing',
      );
    }
    await disposeApp(tester);
  });

  testWidgets('recording a spend puts it in the history', (tester) async {
    await pumpApp(tester, db);

    await tapRail(tester, 'Add');

    await tester.enterText(find.byType(TextField).first, '12,40');
    await tester.tap(find.widgetWithText(FilterChip, 'Groceries'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save  ⏎'));
    await tester.pumpAndSettle();

    final rows = await db.select(db.transactions).get();
    expect(rows, hasLength(1));
    expect(rows.single.amountMinor.minor, 1240);

    await tapRail(tester, 'History');
    expect(find.text('Groceries'), findsWidgets);
    await disposeApp(tester);
  });

  testWidgets('an entry with no category is refused', (tester) async {
    await pumpApp(tester, db);
    await tapRail(tester, 'Add');

    await tester.enterText(find.byType(TextField).first, '5,00');
    await tester.tap(find.widgetWithText(FilledButton, 'Save  ⏎'));
    await tester.pumpAndSettle();

    expect(find.text('Pick a category'), findsOneWidget);
    expect(await db.select(db.transactions).get(), isEmpty);
    await disposeApp(tester);
  });
}
