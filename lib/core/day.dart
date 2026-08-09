/// Timezone-free calendar dates.
///
/// A spend record happens on a *day*, not at an instant. Storing it as a
/// `DateTime` invites a whole class of bug where a purchase logged late on the
/// 31st lands in the next month after a timezone or DST shift, silently moving
/// money between reporting periods. [Day] has no time and no zone, so a date
/// means the same thing no matter where the machine is or when it is read.
library;

import 'package:meta/meta.dart';

/// A calendar date: year, month, day. No time, no timezone, no offset.
@immutable
class Day implements Comparable<Day> {
  final int year;
  final int month;
  final int day;

  const Day(this.year, this.month, this.day);

  /// The local calendar date of [dt] — the date a person would say it is.
  factory Day.fromDateTime(DateTime dt) => Day(dt.year, dt.month, dt.day);

  factory Day.today() => Day.fromDateTime(DateTime.now());

  /// Parses `YYYY-MM-DD`, the storage format. Throws on anything else, since
  /// a malformed date in the database is a bug rather than a user mistake.
  factory Day.parse(String iso) {
    final parsed = tryParse(iso);
    if (parsed == null) throw FormatException('Not an ISO date', iso);
    return parsed;
  }

  static Day? tryParse(String iso) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(iso.trim());
    if (m == null) return null;
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    if (mo < 1 || mo > 12) return null;
    if (d < 1 || d > daysInMonth(y, mo)) return null;
    return Day(y, mo, d);
  }

  /// `YYYY-MM-DD`. Sorts lexicographically in the same order it sorts
  /// chronologically, which is why it is the storage format.
  String get iso =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  /// `YYYY-MM`, for grouping rows by calendar month in SQL and in memory.
  String get isoMonth =>
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';

  /// Midnight UTC on this date. UTC specifically: it is the one construction
  /// that cannot be shifted by the host's zone or by DST.
  DateTime toUtcDateTime() => DateTime.utc(year, month, day);

  /// Midnight local time, for handing to date pickers and formatters.
  DateTime toLocalDateTime() => DateTime(year, month, day);

  /// Whole days since the Unix epoch. Makes day arithmetic and distance a
  /// plain integer operation.
  int get epochDays => toUtcDateTime().millisecondsSinceEpoch ~/ 86400000;

  static Day fromEpochDays(int days) => Day.fromDateTime(
    DateTime.fromMillisecondsSinceEpoch(days * 86400000, isUtc: true),
  );

  /// ISO-8601 weekday, Monday = 1 through Sunday = 7.
  int get weekday => toUtcDateTime().weekday;

  bool get isWeekend =>
      weekday == DateTime.saturday || weekday == DateTime.sunday;

  Day addDays(int count) => fromEpochDays(epochDays + count);

  /// Adds calendar months, clamping to the end of the target month.
  ///
  /// Jan 31 plus one month is Feb 28 (or Feb 29 in a leap year) rather than
  /// rolling into March. Without clamping, a monthly recurring charge dated
  /// the 31st would skip February entirely and drift forward every year.
  Day addMonths(int count) {
    final total = year * 12 + (month - 1) + count;
    final y = total ~/ 12;
    final m = total % 12 + 1;
    return Day(y, m, day.clamp(1, daysInMonth(y, m)));
  }

  Day addYears(int count) {
    final y = year + count;
    return Day(y, month, day.clamp(1, daysInMonth(y, month)));
  }

  Day get firstOfMonth => Day(year, month, 1);
  Day get lastOfMonth => Day(year, month, daysInMonth(year, month));

  /// The number of days from this date to [other], negative when [other] is
  /// earlier.
  int daysUntil(Day other) => other.epochDays - epochDays;

  static bool isLeapYear(int year) =>
      (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;

  static int daysInMonth(int year, int month) {
    const lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if (month == 2 && isLeapYear(year)) return 29;
    return lengths[month - 1];
  }

  bool operator <(Day other) => compareTo(other) < 0;
  bool operator <=(Day other) => compareTo(other) <= 0;
  bool operator >(Day other) => compareTo(other) > 0;
  bool operator >=(Day other) => compareTo(other) >= 0;

  @override
  int compareTo(Day other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  @override
  bool operator ==(Object other) =>
      other is Day &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => iso;
}
