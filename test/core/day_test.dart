import 'package:flutter_test/flutter_test.dart';
import 'package:spend/core/day.dart';

void main() {
  group('leap years', () {
    test('follows the full Gregorian rule, including the century cases', () {
      expect(Day.isLeapYear(2024), isTrue);
      expect(Day.isLeapYear(2025), isFalse);
      expect(Day.isLeapYear(1900), isFalse); // divisible by 100
      expect(Day.isLeapYear(2000), isTrue); // but also by 400
      expect(Day.isLeapYear(2100), isFalse);
    });

    test('February length tracks the leap rule', () {
      expect(Day.daysInMonth(2024, 2), 29);
      expect(Day.daysInMonth(2025, 2), 28);
      expect(Day.daysInMonth(2000, 2), 29);
      expect(Day.daysInMonth(1900, 2), 28);
    });
  });

  group('addMonths clamps instead of overflowing', () {
    test('month-end dates land on the last valid day', () {
      // The bug this prevents: a rent charge dated the 31st skipping February
      // entirely and drifting a day forward every year.
      expect(Day(2025, 1, 31).addMonths(1), Day(2025, 2, 28));
      expect(Day(2024, 1, 31).addMonths(1), Day(2024, 2, 29)); // leap
      expect(Day(2025, 3, 31).addMonths(1), Day(2025, 4, 30));
      expect(Day(2025, 5, 31).addMonths(1), Day(2025, 6, 30));
    });

    test('crosses year boundaries in both directions', () {
      expect(Day(2025, 12, 15).addMonths(1), Day(2026, 1, 15));
      expect(Day(2025, 1, 15).addMonths(-1), Day(2024, 12, 15));
      expect(Day(2025, 6, 10).addMonths(12), Day(2026, 6, 10));
      expect(Day(2025, 6, 10).addMonths(-18), Day(2023, 12, 10));
    });

    test('a monthly series from the 31st stays anchored, not drifting', () {
      // Clamping must not be cumulative: each step is computed from the
      // original anchor day, so March returns to the 31st.
      var d = Day(2025, 1, 31);
      final series = [for (var i = 1; i <= 3; i++) d.addMonths(i)];
      expect(series, [Day(2025, 2, 28), Day(2025, 3, 31), Day(2025, 4, 30)]);
    });

    test('addYears clamps Feb 29 onto non-leap years', () {
      expect(Day(2024, 2, 29).addYears(1), Day(2025, 2, 28));
      expect(Day(2024, 2, 29).addYears(4), Day(2028, 2, 29));
    });
  });

  group('addDays', () {
    test('crosses month, year and leap-day boundaries', () {
      expect(Day(2025, 1, 31).addDays(1), Day(2025, 2, 1));
      expect(Day(2025, 12, 31).addDays(1), Day(2026, 1, 1));
      expect(Day(2024, 2, 28).addDays(1), Day(2024, 2, 29)); // leap
      expect(Day(2025, 2, 28).addDays(1), Day(2025, 3, 1)); // non-leap
      expect(Day(2025, 3, 1).addDays(-1), Day(2025, 2, 28));
    });

    test('survives a DST transition unchanged', () {
      // Europe/Amsterdam springs forward on 2025-03-30. A local-midnight
      // implementation can lose or gain a day here; a UTC-backed one cannot.
      expect(Day(2025, 3, 29).addDays(1), Day(2025, 3, 30));
      expect(Day(2025, 3, 30).addDays(1), Day(2025, 3, 31));
      expect(Day(2025, 10, 25).addDays(1), Day(2025, 10, 26)); // falls back
      expect(Day(2025, 10, 26).addDays(1), Day(2025, 10, 27));
    });

    test('a full year of steps lands exactly on the next year', () {
      var d = Day(2025, 1, 1);
      for (var i = 0; i < 365; i++) {
        d = d.addDays(1);
      }
      expect(d, Day(2026, 1, 1));
    });
  });

  group('serialisation', () {
    test('iso format is zero-padded and lexically sortable', () {
      expect(Day(2025, 1, 5).iso, '2025-01-05');
      expect(Day(2025, 12, 31).iso, '2025-12-31');
      expect(Day(2025, 1, 5).isoMonth, '2025-01');

      final days = [Day(2025, 10, 2), Day(2025, 2, 10), Day(2024, 12, 31)];
      final byIso = [...days.map((d) => d.iso)]..sort();
      final byCompare = [...days]..sort();
      expect(byIso, byCompare.map((d) => d.iso).toList());
    });

    test('parse round-trips', () {
      for (final iso in ['2025-01-01', '2024-02-29', '2025-12-31']) {
        expect(Day.parse(iso).iso, iso);
      }
    });

    test('rejects dates that do not exist', () {
      expect(Day.tryParse('2025-02-30'), isNull);
      expect(Day.tryParse('2025-13-01'), isNull);
      expect(Day.tryParse('2025-00-10'), isNull);
      expect(Day.tryParse('2025-1-1'), isNull); // must be padded
      expect(Day.tryParse('not a date'), isNull);
      expect(() => Day.parse('2025-02-30'), throwsFormatException);
    });

    test('epochDays round-trips and measures distance', () {
      expect(Day(1970, 1, 1).epochDays, 0);
      expect(Day.fromEpochDays(0), Day(1970, 1, 1));
      expect(Day(2025, 1, 1).daysUntil(Day(2026, 1, 1)), 365);
      expect(Day(2024, 1, 1).daysUntil(Day(2025, 1, 1)), 366); // leap
      expect(Day(2025, 3, 1).daysUntil(Day(2025, 2, 1)), -28);

      final d = Day(2025, 7, 14);
      expect(Day.fromEpochDays(d.epochDays), d);
    });
  });

  group('weekdays', () {
    test('identifies weekends', () {
      expect(Day(2025, 7, 26).isWeekend, isTrue); // Saturday
      expect(Day(2025, 7, 27).isWeekend, isTrue); // Sunday
      expect(Day(2025, 7, 28).isWeekend, isFalse); // Monday
      expect(Day(2025, 7, 25).weekday, DateTime.friday);
    });
  });

  test('value equality, so dates work as map keys', () {
    expect(Day(2025, 7, 14), Day(2025, 7, 14));
    expect(Day(2025, 7, 14).hashCode, Day(2025, 7, 14).hashCode);
    expect({Day(2025, 7, 14), Day(2025, 7, 14)}.length, 1);
    expect(Day(2025, 7, 14) < Day(2025, 7, 15), isTrue);
    expect(Day(2025, 7, 14) >= Day(2025, 7, 14), isTrue);
  });
}
