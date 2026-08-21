/// End-to-end smoke tests.
///
/// These run inside a real macOS app process, which is the whole reason they
/// are separate from `test/`. That buys four things no test under `test/` can
/// have: registered plugins, a real SQLite file, real bytes on a real disk,
/// and the app sandbox actually enforced.
///
/// They are deliberately few. A required check that is slow or flaky is one
/// people learn to route around, and the 229 tests under `test/` already carry
/// the arithmetic and the boundaries.
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spend/core/day.dart';
import 'package:spend/core/money.dart';
import 'package:spend/core/providers.dart';
import 'package:spend/data/db/database.dart';

import 'package:spend/main.dart';

import 'support/harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late SpendDatabase db;
  late Directory tempDir;

  setUp(() {
    final made = realDatabaseInTempDir();
    db = made.db;
    tempDir = made.dir;
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('the harness has real plugins and a real disk', (tester) async {
    // path_provider is a platform channel. Under `flutter test` it throws,
    // which is why test/widget_test.dart stubs everything that touches it.
    // If this fails, the harness is broken rather than the app.
    final support = await getApplicationSupportDirectory();
    expect(support.existsSync(), isTrue);

    final probe = File('${tempDir.path}/probe.txt');
    await probe.writeAsString('written by the integration harness');
    expect(await probe.readAsString(), contains('integration harness'));
  });

  testWidgets('a first launch creates its database file and seeds categories', (
    tester,
  ) async {
    await pumpSpendApp(tester, db: db, tempDir: tempDir);

    expect(tester.takeException(), isNull);
    expect(find.text('Overview'), findsWidgets);

    // The part `test/` cannot reach: the schema was created by a real
    // migration against a real file, not by NativeDatabase.memory().
    expect(File('${tempDir.path}/spend.sqlite').existsSync(), isTrue);
    expect(await db.select(db.categories).get(), hasLength(11));
  });

  testWidgets('a recorded spend reaches the ledger and the history', (
    tester,
  ) async {
    await pumpSpendApp(tester, db: db, tempDir: tempDir);

    await tapRail(tester, 'Add');
    // The amount field is the first TextField in the entry column; merchant
    // and note follow it.
    await tester.enterText(find.byType(TextField).first, '12,40');
    await tester.tap(find.widgetWithText(FilterChip, 'Groceries'));
    await tester.pump(const Duration(milliseconds: 100));
    // Two spaces, and the ⏎ — the desktop branch of hasKeyboardShortcuts.
    await tester.tap(find.widgetWithText(FilledButton, 'Save  ⏎'));
    await tester.pump(const Duration(milliseconds: 300));

    final rows = await db.select(db.transactions).get();
    expect(rows, hasLength(1));
    expect(rows.single.amountMinor.minor, 1240);

    await tapRail(tester, 'History');
    await pumpUntil(tester, find.text('Groceries'));
  });

  testWidgets('searching the history finds one merchant and hides the other', (
    tester,
  ) async {
    for (final merchant in ['Albert Heijn', 'Jumbo']) {
      await db
          .into(db.transactions)
          .insert(
            TransactionsCompanion.insert(
              amountMinor: Money(1240),
              categoryId: 1,
              occurredOn: Day.today(),
              merchant: Value(merchant),
            ),
          );
    }

    await pumpSpendApp(tester, db: db, tempDir: tempDir);
    await tapRail(tester, 'History');
    await pumpUntil(tester, find.text('Jumbo'));

    // The search box is the only TextField on this screen.
    await tester.enterText(find.byType(TextField), 'Albert');

    // Both halves, together. Waiting only for the match returns on the first
    // frame, because that row is already on screen and the 250ms debounce has
    // not fired. Waiting only for the other row to go returns mid-query, when
    // the list is briefly empty and neither row is present. Only the
    // conjunction distinguishes "the search ran" from "nothing has happened".
    await pumpUntilCondition(
      tester,
      () =>
          find.text('Albert Heijn').evaluate().isNotEmpty &&
          find.text('Jumbo').evaluate().isEmpty,
      reason: 'the search to narrow the list to Albert Heijn',
    );
  });

  testWidgets('a backup written to disk restores the ledger after a wipe', (
    tester,
  ) async {
    // The test this suite exists for. `test/data/backup_test.dart` covers the
    // archive format, but entirely in memory — nothing has ever proved that
    // bytes written to a real path come back as the same ledger.
    await db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            amountMinor: Money(1240),
            categoryId: 1,
            occurredOn: Day.today(),
            merchant: const Value('Albert Heijn'),
          ),
        );

    final archive = '${tempDir.path}/e2e.spendbak';
    final selector = ScriptedFileSelector()..path = archive;
    FileSelectorPlatform.instance = selector;

    await pumpSpendApp(tester, db: db, tempDir: tempDir);
    await tapRail(tester, 'Settings');

    await tester.tap(find.text('Save a backup'));
    await pumpUntil(tester, find.textContaining('Backup saved'));
    expect(File(archive).existsSync(), isTrue);
    expect(await File(archive).length(), greaterThan(0));

    // Wipe it the way a real accident would: the rows are gone, the file is
    // all that is left.
    await db.delete(db.transactions).go();
    await tapRail(tester, 'History');
    await pumpUntilGone(tester, find.text('Albert Heijn'));

    await tapRail(tester, 'Settings');
    await tester.tap(find.text('Restore from a backup'));
    await pumpUntil(tester, find.text('Restore this backup?'));
    await tester.tap(find.widgetWithText(FilledButton, 'Replace everything'));
    await pumpUntil(tester, find.textContaining('Restored'));

    final restored = await db.select(db.transactions).get();
    expect(restored, hasLength(1));
    expect(restored.single.amountMinor.minor, 1240);
    expect(restored.single.merchant, 'Albert Heijn');
  });

  testWidgets('a cancelled save panel leaves no file and no error', (
    tester,
  ) async {
    // The `if (location == null) return;` branch, which nothing covers today.
    FileSelectorPlatform.instance = ScriptedFileSelector();

    await pumpSpendApp(tester, db: db, tempDir: tempDir);
    await tapRail(tester, 'Settings');
    await tester.tap(find.text('Save a backup'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Backup saved'), findsNothing);
  });

  testWidgets('the insights cards render when no model is reachable', (
    tester,
  ) async {
    // The README's central promise: the app loses the phrasing, not the
    // information. Nothing is listening on the seeded port, so the probe fails
    // exactly as it would on a machine without Ollama installed.
    await seedSpending(db);
    await db.setSetting(SettingKeys.ollamaHost, 'http://127.0.0.1:1');

    await pumpSpendApp(tester, db: db, tempDir: tempDir);
    await tapRail(tester, 'Insights');

    await pumpUntil(tester, find.text('What the numbers say'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the insights narration streams in from the model', (
    tester,
  ) async {
    final ollama = await StubOllama.start();
    addTearDown(ollama.stop);
    ollama.reply = 'Dining ran ahead of its budget this month.';

    await seedSpending(db);
    await db.setSetting(SettingKeys.ollamaHost, ollama.host);
    await db.setSetting(SettingKeys.ollamaModel, ollama.model);

    await pumpSpendApp(tester, db: db, tempDir: tempDir);
    await tapRail(tester, 'Insights');

    // Waiting for the button *is* the assertion that the settings row reached
    // OllamaProvider and /api/tags answered: it only renders once availability
    // reports a model.
    await pumpUntil(tester, find.text('Summarise this period'));
    await tester.tap(find.text('Summarise this period'));

    // Exercises the newline-delimited streaming parser end to end.
    await pumpUntil(
      tester,
      find.textContaining('ahead of its budget'),
      reason: 'the narration to stream in from the stub model',
    );
  });

  testWidgets('the real entry point starts the app', (tester) async {
    // The one thing none of the other tests do: call bootstrap() rather than
    // pumping SpendApp directly. Before this was possible the entry point was
    // the only part of the app no test could reach — its ProviderScope was
    // const, so a temporary database could not be injected and every test had
    // to go around it.
    await bootstrap(
      overrides: [databaseProvider.overrideWithValue(db)],
      // Short on purpose. The window is already up from the test harness, so
      // whatever this does it must not stop the app starting — which is the
      // whole point of the change.
      windowSetupTimeout: const Duration(milliseconds: 1),
    );

    await pumpUntil(tester, find.byType(NavigationRail));
    expect(find.text('Overview'), findsWidgets);
    expect(tester.takeException(), isNull);

    // And it used the injected database, not the developer's real ledger.
    expect(await db.select(db.categories).get(), hasLength(11));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
