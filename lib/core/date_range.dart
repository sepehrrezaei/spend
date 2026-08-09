/// Reporting periods and the comparison windows that go with them.
library;

import 'package:meta/meta.dart';

import 'day.dart';

/// The period a dashboard is currently showing.
enum PeriodType {
  day,
  week,
  month,
  quarter,
  year,

  /// A user-picked span. Has no natural calendar predecessor, so its
  /// comparison window is simply the equally long span immediately before it.
  custom;

  String get label => switch (this) {
    PeriodType.day => 'Day',
    PeriodType.week => 'Week',
    PeriodType.month => 'Month',
    PeriodType.quarter => 'Quarter',
    PeriodType.year => 'Year',
    PeriodType.custom => 'Custom',
  };
}

/// An inclusive range of calendar days.
///
/// Both ends are inclusive: a month range for July runs 1 July through 31 July,
/// not "up to but excluding 1 August". Half-open ranges are the usual source of
/// off-by-one errors in date filtering, and inclusive bounds map directly onto
/// SQL `BETWEEN`.
@immutable
class DateRange {
  final Day start;
  final Day end;

  const DateRange(this.start, this.end);

  /// The calendar month containing [anchor].
  factory DateRange.month(Day anchor) =>
      DateRange(anchor.firstOfMonth, anchor.lastOfMonth);

  /// The calendar year containing [anchor].
  factory DateRange.year(Day anchor) =>
      DateRange(Day(anchor.year, 1, 1), Day(anchor.year, 12, 31));

  /// The calendar quarter containing [anchor].
  factory DateRange.quarter(Day anchor) {
    final firstMonth = ((anchor.month - 1) ~/ 3) * 3 + 1;
    final start = Day(anchor.year, firstMonth, 1);
    return DateRange(start, start.addMonths(2).lastOfMonth);
  }

  /// The week containing [anchor], starting on [weekStartsOn].
  ///
  /// Defaults to Monday, which is both the ISO-8601 convention and how weeks
  /// are read in the Netherlands.
  factory DateRange.week(Day anchor, {int weekStartsOn = DateTime.monday}) {
    final shift = (anchor.weekday - weekStartsOn + 7) % 7;
    final start = anchor.addDays(-shift);
    return DateRange(start, start.addDays(6));
  }

  factory DateRange.single(Day day) => DateRange(day, day);

  /// The range for [type] around [anchor], defaulting to today.
  factory DateRange.forPeriod(
    PeriodType type, {
    Day? anchor,
    int weekStartsOn = DateTime.monday,
  }) {
    final a = anchor ?? Day.today();
    return switch (type) {
      PeriodType.day => DateRange.single(a),
      PeriodType.week => DateRange.week(a, weekStartsOn: weekStartsOn),
      PeriodType.month => DateRange.month(a),
      PeriodType.quarter => DateRange.quarter(a),
      PeriodType.year => DateRange.year(a),
      PeriodType.custom => DateRange.month(a),
    };
  }

  /// Days in the range. Always at least 1, since both ends are inclusive.
  int get dayCount => start.daysUntil(end) + 1;

  bool contains(Day day) => day >= start && day <= end;

  /// Every day in the range, ascending. Used to fill gaps so a chart shows
  /// zero-spend days rather than silently omitting them.
  Iterable<Day> get days sync* {
    for (var d = start; d <= end; d = d.addDays(1)) {
      yield d;
    }
  }

  /// The equivalent period immediately before this one, for period-over-period
  /// comparison.
  ///
  /// Calendar periods step back by one calendar unit, so the comparison for
  /// March is February — not "the 31 days before March", which would straddle
  /// two months and make the number meaningless. Ranges that are not whole
  /// calendar units step back by their own length instead.
  DateRange previous({int weekStartsOn = DateTime.monday}) {
    if (isWholeMonth) {
      final prev = start.addMonths(-1);
      return DateRange.month(prev);
    }
    if (isWholeYear) return DateRange.year(Day(start.year - 1, 1, 1));
    if (isWholeQuarter) return DateRange.quarter(start.addMonths(-3));
    if (dayCount == 7) {
      return DateRange(start.addDays(-7), start.addDays(-1));
    }
    return DateRange(start.addDays(-dayCount), start.addDays(-1));
  }

  /// This range capped at [day], or `null` when the range starts after it.
  ///
  /// The current month is only partly spent, so comparing it against a
  /// complete previous month always looks like a decrease. Callers truncate
  /// the comparison window to the same elapsed length to keep it honest.
  DateRange? truncatedTo(Day day) {
    if (day < start) return null;
    if (day >= end) return this;
    return DateRange(start, day);
  }

  /// The first [count] days of this range, for like-for-like comparison
  /// against a partly elapsed period.
  DateRange firstDays(int count) {
    if (count >= dayCount) return this;
    return DateRange(start, start.addDays(count - 1));
  }

  bool get isWholeMonth =>
      start.day == 1 &&
      end == start.lastOfMonth &&
      start.month == end.month &&
      start.year == end.year;

  bool get isWholeYear =>
      start.month == 1 &&
      start.day == 1 &&
      end.month == 12 &&
      end.day == 31 &&
      start.year == end.year;

  bool get isWholeQuarter {
    if (start.day != 1 || start.year != end.year) return false;
    if ((start.month - 1) % 3 != 0) return false;
    return end == start.addMonths(2).lastOfMonth;
  }

  /// How far through the range [day] is, from 0.0 to 1.0.
  ///
  /// Drives budget pacing: 58% through the month but 71% through the budget.
  /// Counts days inclusively, so the final day of a period reads as fully
  /// elapsed rather than one day short.
  double elapsedFraction(Day day) {
    if (day < start) return 0;
    if (day >= end) return 1;
    return (start.daysUntil(day) + 1) / dayCount;
  }

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '${start.iso}..${end.iso}';
}
