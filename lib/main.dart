import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/platform.dart';
import 'features/quick_add/desktop_integration.dart';

Future<void> main() => bootstrap();

/// Starts the app.
///
/// Separate from [main] so the real entry point can be exercised by a test:
/// [overrides] reaches the `ProviderScope`, which used to be `const` here, so
/// nothing could be injected and every test had to bypass this function and
/// build its own scope. It was the only part of the app no test could reach.
///
/// Returns once [runApp] has been called. That *schedules* the first frame
/// rather than awaiting it, so a caller that needs a rendered tree has to pump
/// or wait for one itself.
///
/// [windowSetup] is the seam the tests use. Left null it does the real thing;
/// passing a future that never completes is how the timeout path is exercised
/// deterministically, instead of hoping a short timeout wins a race against
/// the real plugin calls.
Future<void> bootstrap({
  List<Override> overrides = const [],
  Duration windowSetupTimeout = const Duration(seconds: 5),
  Future<void> Function()? windowSetup,
}) async {
  WidgetsFlutterBinding.ensureInitialized();

  await _prepareWindow(
    timeout: windowSetupTimeout,
    setUp: windowSetup ?? _sizeAndShowWindow,
  );

  runApp(ProviderScope(overrides: overrides, child: const SpendApp()));
}

/// Set once the wait for the window has been given up on.
///
/// The abandoned setup keeps running — [Future.timeout] stops waiting, it
/// cannot cancel — so anything it does afterwards has to check whether the app
/// has already moved on without it.
bool _windowSetupAbandoned = false;

/// Sizes and shows the desktop window, and never prevents the app starting.
///
/// Every call in here talks to the window server. On a Mac where it is slow or
/// unavailable at login — and in any headless context — these futures can hang,
/// and they used to be awaited unguarded before [runApp]. The result was a
/// process that was running and invisible, with no error, no fallback and
/// nothing in the log to explain it.
///
/// So this bounds the wait and swallows the failure. The fallback is a window
/// at whatever size the OS chooses, which is worse than the intended 1180x820
/// and enormously better than no window at all. The tray setup and the hotkey
/// registration next door already take this view; the bootstrap did not, and
/// it is the one place where failing closed loses the whole app.
Future<void> _prepareWindow({
  required Duration timeout,
  required Future<void> Function() setUp,
}) async {
  if (!AppPlatform.supportsMenuBar) return;

  try {
    // One timeout across the whole sequence rather than one per call, because
    // what matters is how long the user waits for a window, not which call
    // stalled.
    await setUp().timeout(timeout);
  } on TimeoutException {
    _windowSetupAbandoned = true;
    debugPrint(
      'Window setup timed out after ${timeout.inMilliseconds}ms — starting '
      'anyway. The window may open at the wrong size or behind other apps.',
    );
  } on Object catch (error, stack) {
    _windowSetupAbandoned = true;
    debugPrint('Window setup failed, starting anyway: $error');
    debugPrintStack(stackTrace: stack);
  }
}

Future<void> _sizeAndShowWindow() async {
  await windowManager.ensureInitialized();

  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: WindowModes.normalSize,
      minimumSize: WindowModes.minimumSize,
      center: true,
      title: 'Spend',
      titleBarStyle: TitleBarStyle.normal,
    ),
    () async {
      // If the wait was abandoned, the app has been running for a while and
      // the user may have hidden the window to the menu bar or moved on.
      // Showing and focusing it now would drag it back in front of whatever
      // they are doing, for a callback they stopped expecting long ago.
      if (_windowSetupAbandoned) return;

      await windowManager.show();
      await windowManager.focus();
    },
  );
}
