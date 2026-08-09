import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Explicit quit.
    //
    // `applicationShouldTerminateAfterLastWindowClosed` is false so the app can
    // live in the menu bar with no window. That also means destroying the last
    // window does *not* end the process — "Quit Spend" would leave a headless,
    // unreachable copy running. Terminating has to be asked for directly, and
    // going through NSApplication runs the normal shutdown path rather than
    // pulling the rug out from under the engine.
    let lifecycle = FlutterMethodChannel(
      name: "spend/lifecycle",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    lifecycle.setMethodCallHandler { call, result in
      switch call.method {
      case "terminate":
        result(nil)
        NSApplication.shared.terminate(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
