/// What the current platform can actually do.
///
/// Features are gated on a named capability rather than on a raw
/// `Platform.isMacOS` check scattered through the UI. That keeps the reason a
/// thing is hidden readable at the call site, and means adding Android or
/// Windows later is one edit here rather than a hunt.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

abstract final class AppPlatform {
  static bool get isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  static bool get isMobile => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  /// Whether a local language model could plausibly be reached.
  ///
  /// Ollama is a desktop program; there is no equivalent a phone or tablet can
  /// talk to. So on mobile the AI surfaces are removed rather than shown
  /// permanently disconnected — a panel that says "unavailable" and can never
  /// be fixed is worse than no panel.
  ///
  /// This does not weaken anything: every figure in the app is computed by
  /// `AnalyticsEngine` and `InsightRules` in pure Dart. The model only ever
  /// rewrote those figures as prose, so mobile loses the phrasing and keeps
  /// all of the information.
  static bool get supportsLocalAi => isDesktop;

  /// Menu bar residency, a global capture shortcut, and window management.
  static bool get supportsMenuBar => isDesktop;

  /// Whether a physical keyboard is the primary input.
  ///
  /// Drives whether the UI advertises shortcuts like "⏎ to save", which read
  /// as noise on a touch device.
  static bool get hasKeyboardShortcuts => isDesktop;
}
