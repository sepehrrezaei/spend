import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/platform.dart';
import 'features/quick_add/desktop_integration.dart';

Future<void> main() => bootstrap();

/// Starts the app.
///
/// Separate from [main] for two reasons. It takes [overrides], so the real
/// entry point can be exercised by a test against a temporary database rather
/// than the developer's own ledger — previously the `ProviderScope` here was
/// `const`, so nothing could be injected and every test had to bypass this
/// function and construct its own scope. And it returns, so a caller can await
/// the first frame.
///
/// [windowSetupTimeout] is exposed for tests that need it short.
Future<void> bootstrap({
  List<Override> overrides = const [],
  Duration windowSetupTimeout = const Duration(seconds: 5),
}) async {
  WidgetsFlutterBinding.ensureInitialized();

  await _prepareWindow(timeout: windowSetupTimeout);

  runApp(ProviderScope(overrides: overrides, child: const SpendApp()));
}

/// Sizes and shows the desktop window, and never prevents the app starting.
///
/// Every call in here talks to the window server. On a Mac where it is slow or
/// unavailable at login — and in any headless context — these futures can hang,
/// and they used to be awaited unguarded before `runApp`. The result was a
/// process that was running and invisible, with no error, no fallback and
/// nothing in the log to explain it.
///
/// So this bounds the wait and swallows the failure. The fallback is a window
/// at whatever size the OS chooses, which is worse than the intended 1180x820
/// and enormously better than no window at all. The tray setup and the hotkey
/// registration next door already take this view; the bootstrap did not, and
/// it is the one place where failing closed loses the whole app.
Future<void> _prepareWindow({required Duration timeout}) async {
  if (!AppPlatform.supportsMenuBar) return;

  try {
    // One timeout across the whole sequence rather than three, because what
    // matters is how long the user waits for a window, not which call stalled.
    //
    // Note this stops *waiting*; it cannot cancel the work. If the window
    // server comes back later the window still appears, just after the app has
    // already started — which is the right way round.
    await Future(() async {
      await windowManager.ensureInitialized();

      // Clear any registrations left behind by a previous run. Global hotkeys
      // are held by the OS, so a debug session killed mid-run would otherwise
      // leave the shortcut claimed and the next launch unable to register it.
      await hotKeyManager.unregisterAll();

      await windowManager.waitUntilReadyToShow(
        const WindowOptions(
          size: WindowModes.normalSize,
          minimumSize: WindowModes.minimumSize,
          center: true,
          title: 'Spend',
          titleBarStyle: TitleBarStyle.normal,
        ),
        () async {
          await windowManager.show();
          await windowManager.focus();
        },
      );
    }).timeout(timeout);
  } on TimeoutException {
    debugPrint(
      'Window setup timed out after ${timeout.inMilliseconds}ms — starting '
      'anyway. '
      'The window may open at the wrong size or behind other apps.',
    );
  } on Object catch (error, stack) {
    debugPrint('Window setup failed, starting anyway: $error');
    debugPrintStack(stackTrace: stack);
  }
}
