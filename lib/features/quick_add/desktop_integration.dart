/// Menu bar presence and the global capture shortcut.
///
/// Everything here is macOS/desktop only and is never reached on iOS. It is
/// kept in one file behind a single platform guard so the rest of the app has
/// no idea it exists — which is what keeps the eventual iOS build a rebuild
/// rather than a rewrite.
///
/// Why bother: the reason expense trackers get abandoned is friction. If
/// logging €3.20 means switching apps, finding a window and clicking through a
/// form, it does not happen. A global shortcut that puts a focused amount field
/// on screen in one keystroke, and disappears on Enter, is the difference
/// between a habit and an abandoned app.
library;

import 'dart:io' show exit;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/platform.dart';

/// True on the platforms where a menu bar and global hotkeys exist.
///
/// Delegates to [AppPlatform] so there is one definition of "desktop".
bool get isDesktop => AppPlatform.supportsMenuBar;

/// What the quick-capture shortcut should do when it fires.
typedef QuickAddCallback = void Function();

class DesktopIntegration with TrayListener, WindowListener {
  DesktopIntegration({required this.onQuickAdd, required this.onShowMain});

  final QuickAddCallback onQuickAdd;
  final QuickAddCallback onShowMain;

  /// Option+Command+Space.
  ///
  /// Chosen because it is unclaimed by macOS and by the usual launcher tools,
  /// and because it is reachable one-handed without looking.
  static final quickAddHotKey = HotKey(
    key: PhysicalKeyboardKey.space,
    modifiers: [HotKeyModifier.alt, HotKeyModifier.meta],
    scope: HotKeyScope.system,
  );

  bool _initialised = false;

  Future<void> initialise() async {
    if (!isDesktop || _initialised) return;
    _initialised = true;

    trayManager.addListener(this);
    windowManager.addListener(this);

    // Closing the window leaves the app alive in the menu bar rather than
    // quitting, which is what makes the shortcut useful at all — a tracker you
    // have to launch first is a tracker you do not use.
    await windowManager.setPreventClose(true);

    await _setUpTray();
    await _registerHotKey();
  }

  Future<void> _setUpTray() async {
    try {
      await trayManager.setIcon(
        'assets/tray/tray_icon.png',
        isTemplate: true, // let macOS recolour for light/dark menu bars
      );
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'quick_add', label: 'Add spend…  ⌥⌘Space'),
            MenuItem.separator(),
            MenuItem(key: 'show', label: 'Open Spend'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: 'Quit Spend'),
          ],
        ),
      );
    } on Object catch (e) {
      // A missing menu bar icon must not stop the app launching.
      debugPrint('Could not set up the menu bar item: $e');
    }
  }

  Future<void> _registerHotKey() async {
    try {
      // Immediately before registering, not during bootstrap. Global hotkeys
      // are held by the OS, so a debug session killed mid-run leaves the
      // shortcut claimed and the next launch unable to register it — but doing
      // the cleanup in main() put it inside a sequence that can be abandoned
      // on timeout and then complete *after* this registration, unregistering
      // the shortcut it was meant to make room for. Adjacent to the register
      // call, the two cannot be separated in time.
      await hotKeyManager.unregisterAll();

      await hotKeyManager.register(
        quickAddHotKey,
        keyDownHandler: (_) => onQuickAdd(),
      );
    } on Object catch (e) {
      // Another app may already own this combination. Everything else still
      // works, so log it rather than failing.
      debugPrint('Could not register the quick-add shortcut: $e');
    }
  }

  Future<void> dispose() async {
    if (!_initialised) return;
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    await hotKeyManager.unregisterAll();
    await trayManager.destroy();
  }

  // ------------------------------------------------------------ tray events

  @override
  void onTrayIconMouseDown() {
    // Left click opens the menu too, rather than doing nothing — a menu bar
    // icon that ignores a plain click feels broken.
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'quick_add':
        onQuickAdd();
      case 'show':
        onShowMain();
      case 'quit':
        _quit();
    }
  }

  /// Channel onto `NSApplication.terminate`, implemented in
  /// `macos/Runner/MainFlutterWindow.swift`.
  static const _lifecycle = MethodChannel('spend/lifecycle');

  /// Ends the process.
  ///
  /// Public and documented because this app cannot be closed the ordinary way
  /// and there is no other route to a clean exit: `AppDelegate` returns false
  /// from `applicationShouldTerminateAfterLastWindowClosed` and
  /// [initialise] sets `preventClose`, both so the app can live in the menu bar
  /// with no window. Anything driving the app — the tray item, a script, a test
  /// harness — needs this rather than closing the window and hoping.
  ///
  /// Lifts `preventClose` first, so a caller that only wants the window gone
  /// is not fighting it, then asks AppKit to quit so the normal shutdown path
  /// runs rather than the rug being pulled from under the engine.
  static Future<void> terminate() async {
    if (isDesktop) {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    }

    // Destroying the window is not enough. The app deliberately survives its
    // last window, so without an explicit terminate "Quit Spend" leaves a
    // headless process running with no window, no tray icon and no way back to
    // it — the shortcut is gone and the only remedy is Activity Monitor.
    try {
      await _lifecycle.invokeMethod<void>('terminate');
    } on Object catch (e) {
      // Never leave the user stuck in that headless state: if the channel is
      // missing (an older Runner, or a non-macOS desktop host) exit directly.
      debugPrint('Falling back to exit(): $e');
      exit(0);
    }
  }

  Future<void> _quit() async {
    await dispose();
    await terminate();
  }

  // ----------------------------------------------------------- window events

  @override
  void onWindowClose() async {
    // Hide rather than quit. The app stays in the menu bar.
    await windowManager.hide();
  }
}

/// Window geometry helpers for the two modes the window can be in.
abstract final class WindowModes {
  static const compactSize = Size(460, 262);
  static const normalSize = Size(1180, 820);
  static const minimumSize = Size(760, 620);

  /// Shrinks the window to a compact capture panel near the top of the screen.
  ///
  /// Flutter runs one window per engine, so rather than fighting to create a
  /// genuine popover this reuses the main window: small, centred high on
  /// screen, above other windows. It behaves like a capture panel without the
  /// fragility of multi-window support.
  static Future<void> enterCompact() async {
    if (!isDesktop) return;
    await windowManager.setMinimumSize(const Size(360, 240));
    await windowManager.setSize(compactSize);
    await windowManager.setAlignment(Alignment.topCenter);
    await windowManager.setAlwaysOnTop(true);
    // show() must be the last call, and focus() must not follow it.
    //
    // window_manager's focus() runs NSApp.activate(ignoringOtherApps: false),
    // which is a no-op while another application is frontmost — precisely the
    // situation a global shortcut fires in. Only show() activates with
    // ignoringOtherApps: true. Calling focus() afterwards left the panel
    // visible but the app inactive, so keystrokes went to whatever app the
    // user was actually in.
    await windowManager.show();
  }

  /// Restores the ordinary application window.
  static Future<void> exitCompact() async {
    if (!isDesktop) return;
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setMinimumSize(minimumSize);
    await windowManager.setSize(normalSize);
    await windowManager.center();
  }

  static Future<void> hide() async {
    if (!isDesktop) return;
    await windowManager.setAlwaysOnTop(false);
    await windowManager.hide();
  }

  static Future<void> showNormal() async {
    if (!isDesktop) return;
    await exitCompact();
    // Same ordering rule as enterCompact: show() activates, focus() does not.
    await windowManager.show();
  }
}
