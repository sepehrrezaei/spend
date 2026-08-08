/// Turning [Money] into text.
///
/// Kept apart from [Money] itself so the value type stays free of locale
/// concerns, and so formatting choices can change without touching arithmetic.
library;

import 'package:intl/intl.dart';

import 'money.dart';

/// Formats amounts for a single currency and locale.
///
/// Construct one per currency/locale pair and reuse it — building an
/// [NumberFormat] is not free, and chart axes format many labels per frame.
class MoneyFormatter {
  final String currencyCode;
  final String locale;

  final NumberFormat _standard;
  final NumberFormat _whole;

  MoneyFormatter({this.currencyCode = 'EUR', String? locale})
    : locale = locale ?? Intl.getCurrentLocale(),
      _standard = NumberFormat.simpleCurrency(
        locale: locale ?? Intl.getCurrentLocale(),
        name: currencyCode,
      ),
      _whole = NumberFormat.simpleCurrency(
        locale: locale ?? Intl.getCurrentLocale(),
        name: currencyCode,
        decimalDigits: 0,
      );

  /// The currency symbol alone, for input field prefixes.
  String get symbol => _standard.currencySymbol;

  /// The usual form: `€12,40`.
  String format(Money amount) => _standard.format(amount.major);

  /// Drops the cents: `€12`. For dense summaries where the exact cent is
  /// noise rather than information.
  String formatWhole(Money amount) => _whole.format(amount.major);

  /// Always carries a sign, for deltas where direction is the point.
  String formatSigned(Money amount) {
    final body = _standard.format(amount.abs().major);
    return amount.isNegative ? '-$body' : '+$body';
  }

  /// Short form for chart axes, where labels compete for very little space:
  /// `€1.2k`, `€15k`, `€1.4M`.
  ///
  /// Deliberately not [NumberFormat.compactCurrency], which still emits cents
  /// at small magnitudes and produces labels too wide for an axis.
  String formatCompact(Money amount) {
    final abs = amount.abs().major;
    final sign = amount.isNegative ? '-' : '';
    if (abs < 1000) return '$sign$symbol${abs.round()}';
    if (abs < 10000) {
      final k = (abs / 1000).toStringAsFixed(1);
      return '$sign$symbol${k.endsWith('.0') ? k.substring(0, k.length - 2) : k}k';
    }
    if (abs < 1000000) return '$sign$symbol${(abs / 1000).round()}k';
    return '$sign$symbol${(abs / 1000000).toStringAsFixed(1)}M';
  }
}

/// Formats dates for display, separately from the ISO form used in storage.
class DayFormatter {
  final String locale;
  final DateFormat _short;
  final DateFormat _medium;
  final DateFormat _monthYear;
  final DateFormat _weekday;

  DayFormatter({String? locale})
    : locale = locale ?? Intl.getCurrentLocale(),
      _short = DateFormat.Md(locale ?? Intl.getCurrentLocale()),
      _medium = DateFormat.MMMd(locale ?? Intl.getCurrentLocale()),
      _monthYear = DateFormat.yMMMM(locale ?? Intl.getCurrentLocale()),
      _weekday = DateFormat.E(locale ?? Intl.getCurrentLocale());

  String short(DateTime d) => _short.format(d);
  String medium(DateTime d) => _medium.format(d);
  String monthYear(DateTime d) => _monthYear.format(d);
  String weekday(DateTime d) => _weekday.format(d);
}
