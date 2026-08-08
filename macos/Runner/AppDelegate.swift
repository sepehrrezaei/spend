import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Keep running with no visible window.
  ///
  /// Flutter's default is `true`, which terminates the process as soon as the
  /// last window goes away — and hiding the window counts. That killed the app
  /// every time the quick-add panel dismissed itself, so the menu bar item
  /// vanished and the next ⌥⌘Space did nothing.
  ///
  /// Returning `false` makes this a proper menu bar resident: the window can
  /// come and go while the process, the tray item and the global shortcut all
  /// stay alive. Quitting is explicit, via the menu bar item or ⌘Q.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
