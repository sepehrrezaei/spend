import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/platform.dart';
import 'features/quick_add/desktop_integration.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (AppPlatform.supportsMenuBar) {
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
  }

  runApp(const ProviderScope(child: SpendApp()));
}
