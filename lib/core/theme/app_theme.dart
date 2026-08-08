/// Visual theme.
///
/// Tuned for a desktop window rather than a phone: tighter density, smaller
/// touch targets, and typography that stays readable at the distance you sit
/// from a Mac. The same theme still works on iOS, where Flutter's own density
/// handling restores comfortable spacing.
library;

import 'dart:io';

import 'package:flutter/material.dart';

abstract final class AppTheme {
  static bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// Seed for the Material 3 palette. A muted teal-green: it reads as
  /// financial without the alarm-red or corporate-blue defaults, and it leaves
  /// red and amber free to mean "over budget" rather than merely "accent".
  static const seed = Color(0xFF2E7D6F);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final isDark = brightness == Brightness.dark;

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      // Desktop pointers are precise, so the default touch-sized padding
      // wastes a lot of window.
      visualDensity: VisualDensity.compact,
      scaffoldBackgroundColor: isDark
          ? scheme.surface
          : const Color(0xFFF7F8F7),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: isDark ? scheme.surfaceContainerLow : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? scheme.surfaceContainerHigh : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: isDark
            ? scheme.surfaceContainerLowest
            : const Color(0xFFEFF1F0),
        indicatorColor: scheme.primaryContainer,
        labelType: NavigationRailLabelType.all,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
        space: 1,
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        // A floating snackbar still spans the whole window, which on a
        // maximised desktop window means a confirmation toast a metre wide.
        // Phones keep the default, where full width is correct.
        width: _isDesktop ? 460 : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  /// Tabular figures, so digits occupy identical width.
  ///
  /// Without this, a column of amounts visibly jitters as values change and
  /// the decimal points fail to line up — the single most noticeable way a
  /// finance UI looks amateurish.
  static const TextStyle tabularFigures = TextStyle(
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// Semantic colours for budget and trend states.
///
/// Derived from the scheme rather than hard-coded so they stay legible in
/// both brightnesses.
extension SpendColors on ColorScheme {
  /// Spending is up. In a spend tracker that is bad news, so it borrows the
  /// error colour rather than a neutral "increase" green.
  Color get increase => error;

  /// Spending is down.
  Color get decrease => brightness == Brightness.dark
      ? const Color(0xFF6FCF97)
      : const Color(0xFF2E7D32);

  /// Approaching a budget limit.
  Color get warning => brightness == Brightness.dark
      ? const Color(0xFFFFB74D)
      : const Color(0xFFE65100);
}
