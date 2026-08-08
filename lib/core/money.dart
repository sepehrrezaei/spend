/// Exact monetary arithmetic.
///
/// Amounts are stored as [int] minor units (cents) and never as [double].
/// Binary floating point cannot represent most decimal fractions exactly, so
/// `0.1 + 0.2` yields `0.30000000000000004`. Summing thousands of transactions
/// that way accumulates visible drift, and a ledger that disagrees with itself
/// by a cent is worthless. Doubles appear only at the display boundary.
library;

import 'package:meta/meta.dart';

/// An exact amount of money, held as a signed count of minor units.
///
/// Negative values are legal and meaningful: they represent refunds and
/// income, and they let a period total be a single sum with no special cases.
@immutable
class Money implements Comparable<Money> {
  /// The amount in minor units — cents for EUR, so `1234` is €12.34.
  final int minor;

  const Money(this.minor);

  static const Money zero = Money(0);

  /// Builds a [Money] from a major-unit number, e.g. `12.34` -> `1234`.
  ///
  /// Only for literals and test fixtures. Anything arriving as user text
  /// should go through [tryParse], which handles separators and stray symbols.
  factory Money.fromMajor(num major) => Money((major * 100).round());

  /// Parses user input, returning `null` when it is not a usable amount.
  ///
  /// Deliberately liberal, because typing speed is what makes or breaks an
  /// expense tracker. It accepts leading currency symbols, thin/non-breaking
  /// spaces pasted from web pages, and either separator convention — `12.40`
  /// and `12,40` both mean the same thing, which matters in the Netherlands
  /// where the comma is the decimal separator.
  ///
  /// Separator disambiguation:
  ///  * Both present -> the rightmost is the decimal, the other groups digits
  ///    (`1.234,56` and `1,234.56` both parse to `123456`).
  ///  * One present, 1-2 digits after it -> decimal separator (`12,4` -> 1240).
  ///  * One present, exactly 3 digits after it, and a plausible grouped head
  ///    (1-3 digits, no leading zero) -> digit grouping (`12,345` ->
  ///    1234500), matching how people write thousands. `0,005` keeps its
  ///    fraction, since nobody groups thousands starting from zero.
  ///  * More than 2 decimals -> rounded half away from zero.
  ///
  /// Structurally broken input is rejected rather than salvaged: a stray
  /// amount like `1,2,3.4.5` returns `null` instead of quietly becoming
  /// 1234.50.
  static Money? tryParse(String input) {
    var s = input.trim();
    if (s.isEmpty) return null;

    // Strip currency symbols, whitespace (including U+00A0 and U+202F, which
    // ride along on pasted amounts), and anything else that is not structural.
    s = s.replaceAll(RegExp(r'[^0-9.,\-+]'), '');
    if (s.isEmpty) return null;

    var negative = false;
    if (s.startsWith('-')) {
      negative = true;
      s = s.substring(1);
    } else if (s.startsWith('+')) {
      s = s.substring(1);
    }
    // A sign anywhere else means the input was malformed, not just decorated.
    if (s.contains('-') || s.contains('+')) return null;
    if (s.isEmpty) return null;

    final lastDot = s.lastIndexOf('.');
    final lastComma = s.lastIndexOf(',');
    int decimalAt;
    if (lastDot >= 0 && lastComma >= 0) {
      decimalAt = lastDot > lastComma ? lastDot : lastComma;
    } else if (lastDot >= 0 || lastComma >= 0) {
      final only = lastDot >= 0 ? lastDot : lastComma;
      final trailing = s.length - only - 1;
      final head = s.substring(0, only);
      // Exactly three trailing digits reads as digit grouping rather than as
      // three decimals, which nobody types for money — but only where a
      // grouped number is actually plausible. "1,005" is one thousand and
      // five; "0,005" and ",005" are fractions of a euro, not thousands.
      final isGrouping =
          trailing == 3 &&
          head.isNotEmpty &&
          head.length <= 3 &&
          !head.startsWith('0') &&
          !head.contains(RegExp(r'[.,]'));
      decimalAt = isGrouping ? -1 : only;
    } else {
      decimalAt = -1;
    }

    final wholeRaw = decimalAt >= 0 ? s.substring(0, decimalAt) : s;
    final fraction = decimalAt >= 0 ? s.substring(decimalAt + 1) : '';

    // The integer part must be either plain digits or properly grouped ones.
    // Without this check, structurally broken input like "1,2,3.4.5" would
    // have its separators stripped and quietly parse as 1234.50.
    if (!_isWellFormedWhole(wholeRaw)) return null;
    if (!RegExp(r'^[0-9]*$').hasMatch(fraction)) return null;

    final whole = wholeRaw.replaceAll(RegExp(r'[.,]'), '');
    if (whole.isEmpty && fraction.isEmpty) return null;

    final wholePart = whole.isEmpty ? 0 : int.tryParse(whole);
    if (wholePart == null) return null;

    // Pad or round the fraction to exactly two digits.
    int cents;
    if (fraction.isEmpty) {
      cents = 0;
    } else if (fraction.length <= 2) {
      cents = int.parse(fraction.padRight(2, '0'));
    } else {
      final keep = int.parse(fraction.substring(0, 2));
      final nextDigit = int.parse(fraction[2]);
      cents = nextDigit >= 5 ? keep + 1 : keep;
    }

    var total = wholePart * 100 + cents;
    if (negative) total = -total;
    return Money(total);
  }

  /// Whether the integer part is plain digits, or digits grouped in threes by
  /// a single consistent separator (`1.234.567`, `1,234,567`).
  ///
  /// The backreference matters: it rejects a separator style that changes
  /// partway through, which is a sign of malformed rather than merely
  /// unusual input.
  static bool _isWellFormedWhole(String raw) {
    if (raw.isEmpty) return true;
    if (RegExp(r'^[0-9]+$').hasMatch(raw)) return true;
    return RegExp(r'^[0-9]{1,3}([.,])[0-9]{3}(?:\1[0-9]{3})*$').hasMatch(raw);
  }

  /// The amount in major units. For display and charting only — never feed
  /// this back into arithmetic that is later persisted.
  double get major => minor / 100;

  bool get isZero => minor == 0;
  bool get isNegative => minor < 0;
  bool get isPositive => minor > 0;

  Money abs() => Money(minor.abs());

  Money operator +(Money other) => Money(minor + other.minor);
  Money operator -(Money other) => Money(minor - other.minor);
  Money operator -() => Money(-minor);

  /// Scales by a factor, rounding to the nearest cent. Used for budget
  /// pacing and projections, where a fractional cent has no meaning.
  Money operator *(num factor) => Money((minor * factor).round());

  /// Splits into [divisor] parts, rounding to the nearest cent.
  ///
  /// Returns [zero] for a zero divisor rather than throwing, because the
  /// callers are averages over a period and a period with no elapsed days
  /// should read as "nothing yet", not crash the dashboard.
  Money dividedBy(num divisor) =>
      divisor == 0 ? Money.zero : Money((minor / divisor).round());

  /// The ratio of this amount to [other], or `null` when [other] is zero.
  ///
  /// Returns a plain [double] because a ratio is not money. Callers get
  /// `null` rather than infinity so "no budget set" cannot silently render
  /// as a full progress bar.
  double? ratioTo(Money other) => other.isZero ? null : minor / other.minor;

  bool operator <(Money other) => minor < other.minor;
  bool operator <=(Money other) => minor <= other.minor;
  bool operator >(Money other) => minor > other.minor;
  bool operator >=(Money other) => minor >= other.minor;

  @override
  int compareTo(Money other) => minor.compareTo(other.minor);

  @override
  bool operator ==(Object other) => other is Money && other.minor == minor;

  @override
  int get hashCode => minor.hashCode;

  /// Unformatted and locale-free, for logs and debugging. User-facing text
  /// goes through the formatter in `money_format.dart`.
  @override
  String toString() {
    final sign = minor < 0 ? '-' : '';
    final abs = minor.abs();
    return '$sign${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
  }
}

/// Sums an iterable of amounts exactly.
extension MoneyIterable on Iterable<Money> {
  Money sum() => fold(Money.zero, (a, b) => a + b);
}
