/// Shared scaffolding for the end-to-end suite.
///
/// The point of this suite is the seam `test/` deliberately stubs: real plugin
/// registration, a real SQLite file, real bytes on a real disk. So the fakes
/// here are kept to the two things a CI runner genuinely cannot provide — a
/// human clicking a native save panel, and a language model — and everything
/// else runs for real.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend/app.dart';
import 'package:spend/core/day.dart';
import 'package:spend/core/money.dart';
import 'package:spend/core/providers.dart';
import 'package:spend/data/backup/auto_backup.dart';
import 'package:spend/data/db/database.dart';
import 'package:window_manager/window_manager.dart';

/// A real on-disk database in a throwaway directory.
///
/// Not [SpendDatabase.memory], which is what every test under `test/` uses:
/// the file path, the SQLite journal and the migration that creates and seeds
/// the schema are exactly the parts that have never been exercised.
({SpendDatabase db, Directory dir}) realDatabaseInTempDir() {
  final dir = Directory.systemTemp.createTempSync('spend-e2e-');
  final db = SpendDatabase(NativeDatabase(File('${dir.path}/spend.sqlite')));
  return (db: db, dir: dir);
}

/// Keeps the launch-time snapshot out of the real Application Support folder.
///
/// `lib/app.dart` calls `snapshotIfDue()` on every launch, and overriding
/// [autoSnapshotsProvider] only stubs the *listing* — the write still happens.
/// Redirecting the directory keeps the write real, which is the point, while
/// leaving the developer's own backups alone.
class TempAutoBackup extends AutoBackup {
  TempAutoBackup(super.service, this._dir);

  final Directory _dir;

  @override
  Future<Directory> directory() async {
    if (!await _dir.exists()) await _dir.create(recursive: true);
    return _dir;
  }
}

/// Boots the real app against [db].
///
/// The 1280x900 surface is inherited from `test/widget_test.dart`, where the
/// comment explains why: the 800x600 default pushes the entry form's save
/// button off-screen, and taps then silently miss.
Future<void> pumpSpendApp(
  WidgetTester tester, {
  required SpendDatabase db,
  required Directory tempDir,
}) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        autoBackupProvider.overrideWith(
          (ref) => TempAutoBackup(
            ref.watch(backupServiceProvider),
            Directory('${tempDir.path}/backups'),
          ),
        ),
      ],
      child: const SpendApp(),
    ),
  );
  await pumpUntil(tester, find.byType(NavigationRail));

  // Undo the app's own no-exit machinery, or a failing test hangs the runner
  // rather than failing it.
  //
  // Pumping SpendApp runs DesktopIntegration.initialise(), which calls
  // setPreventClose(true) so the real app can live in the menu bar with no
  // window. Nothing lifts it: DesktopIntegration.dispose() tears down the tray
  // and the hotkey but leaves preventClose set, and on a failing test the tree
  // is never unmounted so even that does not run. The app then refuses to
  // close, `flutter test` waits on a process that will never exit, and CI
  // reports a twenty-minute `cancelled` instead of a failure with the
  // assertion in it.
  //
  // Registered, not called at the end of the body, precisely so it still runs
  // when an expectation has already thrown.
  addTearDown(() async {
    await windowManager.setPreventClose(false);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

/// Pumps until [finder] matches, or fails at [timeout].
///
/// `pumpAndSettle` is close to unusable here. `IntegrationTestWidgetsFlutterBinding`
/// extends the *live* binding, so there is no fake clock: a
/// `CircularProgressIndicator` — which several screens show while a stream or
/// the AI probe is in flight — schedules frames forever, and settling waits out
/// its full ten-minute default before throwing. Waiting on a condition instead
/// is bounded and says what it is waiting for when it fails.
///
/// The same absence of a fake clock is why this file has no equivalent of the
/// `disposeApp` teardown in `test/widget_test.dart`: that exists to flush a
/// zero-duration timer queued by fake async, which does not arise here.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
  String? reason,
}) async {
  await _pumpUntil(
    tester,
    () => finder.evaluate().isNotEmpty,
    timeout,
    reason ?? 'Timed out after ${timeout.inSeconds}s waiting for $finder',
  );
}

/// Pumps until [finder] matches nothing, or fails at [timeout].
///
/// The counterpart to [pumpUntil], and not a nicety: waiting for something
/// that is *already* on screen returns on the first frame and asserts nothing.
/// Where a change removes rows — a search narrowing a list, a filter applying —
/// the disappearance is the only thing that actually distinguishes "it worked"
/// from "nothing has happened yet".
Future<void> pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
  String? reason,
}) async {
  await _pumpUntil(
    tester,
    () => finder.evaluate().isEmpty,
    timeout,
    reason ?? 'Timed out after ${timeout.inSeconds}s waiting for $finder to go',
  );
}

/// Pumps until [satisfied] holds, or fails at [timeout].
///
/// The general form, and usually the right one when a single change both adds
/// and removes widgets. Waiting on only half of it passes on a transient frame:
/// a list mid-query is briefly empty, so "the old row has gone" is true before
/// the new one has arrived.
Future<void> pumpUntilCondition(
  WidgetTester tester,
  bool Function() satisfied, {
  Duration timeout = const Duration(seconds: 20),
  required String reason,
}) => _pumpUntil(tester, satisfied, timeout, 'Timed out waiting for $reason');

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() satisfied,
  Duration timeout,
  String message,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    if (satisfied()) return;
  }
  fail(message);
}

/// Taps a destination in the navigation rail.
///
/// `NavigationRailDestination` is a configuration object rather than a widget,
/// so it never appears in the tree. Scoping to the rail also avoids matching
/// the same label in a screen's app bar.
Future<void> tapRail(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

/// Stands in for the human at the native save/open panel.
///
/// The four `file_selector` calls in `data_section.dart` are made inline with
/// no injectable seam, but the platform interface has a public `instance`
/// setter — so this needs no production change. Everything past the panel is
/// real: real archive bytes, real file, real read back.
class ScriptedFileSelector extends FileSelectorPlatform {
  /// Path handed back for a save panel, and read from for an open panel.
  String? path;

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async => path == null ? null : FileSaveLocation(path!);

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => path == null ? null : XFile(path!);
}

/// A local stand-in for Ollama.
///
/// Bound to loopback because `LocalEndpoint` refuses anything else, and to an
/// ephemeral port so two runs cannot collide. Only the two endpoints the app
/// actually calls are answered; the streaming shape matters, because
/// `OllamaProvider.narrate` parses newline-delimited JSON one object at a time.
class StubOllama {
  StubOllama._(this._server, this.model);

  final HttpServer _server;
  final String model;

  /// Prose the stub streams back, chunked, for a narration request.
  String reply = 'Dining is running ahead of its budget this month.';

  /// Whether /api/tags reports an installed model. False makes the app behave
  /// as though nothing is installed while still answering, which is a
  /// different state from nothing listening at all.
  bool hasModel = true;

  static Future<StubOllama> start({String model = 'llama3.2:3b'}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stub = StubOllama._(server, model);
    unawaited(stub._serve());
    return stub;
  }

  String get host => 'http://127.0.0.1:${_server.port}';

  Future<void> _serve() async {
    await for (final request in _server) {
      final response = request.response;
      if (request.uri.path == '/api/tags') {
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'models': [
              if (hasModel) {'name': model},
            ],
          }),
        );
        await response.close();
        continue;
      }

      if (request.uri.path == '/api/chat') {
        await request.drain<void>();
        // Newline-delimited JSON, one object per chunk, then a done marker —
        // the shape the provider's line splitter expects.
        for (final word in reply.split(' ')) {
          response.write(
            '${jsonEncode({
              'message': {'role': 'assistant', 'content': '$word '},
              'done': false,
            })}\n',
          );
        }
        response.write('${jsonEncode({'done': true})}\n');
        await response.close();
        continue;
      }

      response.statusCode = HttpStatus.notFound;
      await response.close();
    }
  }

  Future<void> stop() => _server.close(force: true);
}

/// A month of spending, enough that the insight rules have something to say.
///
/// An empty period renders a placeholder instead of cards, which would make an
/// insights test pass while asserting nothing.
Future<void> seedSpending(SpendDatabase db) async {
  final start = Day.today().firstOfMonth;
  for (var i = 0; i < 12; i++) {
    await db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            amountMinor: Money(1500 + i * 250),
            categoryId: (i % 4) + 1,
            occurredOn: start.addDays(i),
            merchant: Value('Merchant $i'),
          ),
        );
  }
}
