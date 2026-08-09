import 'package:flutter_test/flutter_test.dart';
import 'package:spend/core/date_range.dart';
import 'package:spend/core/day.dart';
import 'package:spend/core/money.dart';
import 'package:spend/domain/analytics/analytics_engine.dart';
import 'package:spend/domain/entities/enums.dart';
import 'package:spend/domain/entities/spend_record.dart';

const engine = AnalyticsEngine();

var _nextId = 1;

/// Builds a record from a terse literal, so fixtures read as data.
SpendRecord rec(
  String iso,
  int minor, {
  int cat = 1,
  String name = 'Groceries',
  bool income = false,
  bool recurring = false,
  String merchant = '',
}) => SpendRecord(
  id: _nextId++,
  amount: Money(minor),
  occurredOn: Day.parse(iso),
  categoryId: cat,
  categoryName: name,
  categoryIcon: 'tag',
  categoryColor: 0xFF000000,
  categoryKind: income ? CategoryKind.income : CategoryKind.expense,
  merchant: merchant,
  recurringRuleId: recurring ? 99 : null,
);

void main() {
  setUp(() => _nextId = 1);

  final july = DateRange.month(Day(2025, 7, 1));
  final june = DateRange.month(Day(2025, 6, 1));

  group('empty periods', () {
    test('report zeroes rather than throwing or dividing by zero', () {
      final s = engine.summarise(
        records: [],
        range: july,
        today: Day(2025, 7, 31),
      );
      expect(s.isEmpty, isTrue);
      expect(s.expenseTotal, Money.zero);
      expect(s.dailyAverage, Money.zero);
      expect(s.projectedTotal, Money.zero);
      expect(s.deltaFraction, isNull);
      expect(s.categories, isEmpty);
      expect(s.largest, isNull);
      expect(s.daily, hasLength(31), reason: 'still zero-filled');
      expect(s.noSpendDays, 31);
    });
  });

  group('totals', () {
    test('sums expenses and income separately', () {
      final s = engine.summarise(
        records: [
          rec('2025-07-01', 1240),
          rec('2025-07-02', 860),
          rec('2025-07-03', 250000, cat: 9, name: 'Income', income: true),
        ],
        range: july,
        today: Day(2025, 7, 31),
      );
      expect(s.expenseTotal, Money(2100));
      expect(s.incomeTotal, Money(250000));
      expect(s.net, Money(247900));
      expect(s.transactionCount, 3);
    });

    test('a refund reduces the category total', () {
      final s = engine.summarise(
        records: [rec('2025-07-01', 5000), rec('2025-07-05', -1500)],
        range: july,
        today: Day(2025, 7, 31),
      );
      expect(s.expenseTotal, Money(3500));
      expect(s.categories.single.total, Money(3500));
    });

    test('records outside the range are ignored', () {
      final s = engine.summarise(
        records: [
          rec('2025-06-30', 9999), // day before
          rec('2025-07-01', 1000),
          rec('2025-08-01', 9999), // day after
        ],
        range: july,
        today: Day(2025, 7, 31),
      );
      expect(s.expenseTotal, Money(1000));
      expect(s.transactionCount, 1);
    });

    test('boundary days are inclusive at both ends', () {
      final s = engine.summarise(
        records: [rec('2025-07-01', 100), rec('2025-07-31', 200)],
        range: july,
        today: Day(2025, 7, 31),
      );
      expect(s.expenseTotal, Money(300));
    });
  });

  group('category breakdown', () {
    test('sorts by size and shares sum to one', () {
      final s = engine.summarise(
        records: [
          rec('2025-07-01', 1000, cat: 1, name: 'Groceries'),
          rec('2025-07-02', 3000, cat: 2, name: 'Rent'),
          rec('2025-07-03', 1000, cat: 1, name: 'Groceries'),
        ],
        range: july,
        today: Day(2025, 7, 31),
      );
      expect(s.categories.map((c) => c.name), ['Rent', 'Groceries']);
      expect(s.categories[0].total, Money(3000));
      expect(s.categories[1].total, Money(2000));
      expect(s.categories[1].count, 2);
      expect(
        s.categories.fold<double>(0, (a, c) => a + c.share),
        closeTo(1.0, 1e-9),
      );
    });

    test('a category absent last period is flagged new, not +100%', () {
      final s = engine.summarise(
        records: [rec('2025-07-01', 1000, cat: 3, name: 'Gym')],
        range: july,
        previousRecords: const [],
        previousRange: june,
        today: Day(2025, 7, 31),
      );
      final slice = s.categories.single;
      expect(slice.isNew, isTrue);
      expect(slice.deltaFraction, isNull);
    });

    test('computes change against the same category last period', () {
      final s = engine.summarise(
        records: [rec('2025-07-01', 1500)],
        previousRecords: [rec('2025-06-01', 1000)],
        range: july,
        previousRange: june,
        today: Day(2025, 7, 31),
      );
      expect(s.categories.single.delta, Money(500));
      expect(s.categories.single.deltaFraction, closeTo(0.5, 1e-9));
    });

    test('a period that nets to zero does not produce infinite shares', () {
      final s = engine.summarise(
        records: [rec('2025-07-01', 1000), rec('2025-07-02', -1000)],
        range: july,
        today: Day(2025, 7, 31),
      );
      expect(s.expenseTotal, Money.zero);
      expect(s.categories.single.share, 0);
    });
  });

  group('partial periods', () {
    test('daily average divides by elapsed days, not the whole month', () {
      // €30 over the first 3 days of July.
      final s = engine.summarise(
        records: [
          rec('2025-07-01', 1000),
          rec('2025-07-02', 1000),
          rec('2025-07-03', 1000),
        ],
        range: july,
        today: Day(2025, 7, 3),
      );
      expect(s.isPartial, isTrue);
      expect(s.elapsedDays, 3);
      // Dividing by 31 here would report €0.97/day instead of €10.
      expect(s.dailyAverage, Money(1000));
      expect(s.projectedTotal, Money(31000));
    });

    test('a completed period projects to its actual total', () {
      final s = engine.summarise(
        records: [rec('2025-07-15', 5000)],
        range: july,
        today: Day(2025, 8, 20),
      );
      expect(s.isPartial, isFalse);
      expect(s.elapsedDays, 31);
      expect(s.projectedTotal, Money(5000));
      expect(s.asOf, Day(2025, 7, 31));
    });

    test('the comparison period is truncated to the same elapsed length', () {
      // July: €30 over 3 days. June: €30 in the first 3 days, then €500 more
      // later in the month. Comparing against all of June would show a huge
      // fall; comparing like for like shows no change at all.
      final s = engine.summarise(
        records: [
          rec('2025-07-01', 1000),
          rec('2025-07-02', 1000),
          rec('2025-07-03', 1000),
        ],
        previousRecords: [
          rec('2025-06-01', 1000),
          rec('2025-06-02', 1000),
          rec('2025-06-03', 1000),
          rec('2025-06-20', 50000),
        ],
        range: july,
        previousRange: june,
        today: Day(2025, 7, 3),
      );
      expect(s.previousExpenseTotal, Money(3000));
      expect(s.delta, Money.zero);
      expect(s.deltaFraction, closeTo(0.0, 1e-9));
    });

    test('a completed period compares against the whole previous period', () {
      final s = engine.summarise(
        records: [rec('2025-07-05', 3000)],
        previousRecords: [rec('2025-06-01', 1000), rec('2025-06-20', 1000)],
        range: july,
        previousRange: june,
        today: Day(2025, 7, 31),
      );
      expect(s.previousExpenseTotal, Money(2000));
      expect(s.deltaFraction, closeTo(0.5, 1e-9));
    });
  });

  group('daily series', () {
    test('zero-fills every day of the month, in order', () {
      final s = engine.summarise(
        records: [rec('2025-07-05', 500)],
        range: july,
        today: Day(2025, 7, 31),
      );
      expect(s.daily, hasLength(31));
      expect(s.daily.first.day, Day(2025, 7, 1));
      expect(s.daily.last.day, Day(2025, 7, 31));
      expect(s.daily[4].total, Money(500));
      expect(s.daily[0].total, Money.zero);
    });

    test('February gets 28 days, or 29 in a leap year', () {
      final feb2025 = engine.summarise(
        records: [],
        range: DateRange.month(Day(2025, 2, 10)),
        today: Day(2025, 3, 1),
      );
      expect(feb2025.daily, hasLength(28));

      final feb2024 = engine.summarise(
        records: [rec('2024-02-29', 100)],
        range: DateRange.month(Day(2024, 2, 10)),
        today: Day(2024, 3, 1),
      );
      expect(feb2024.daily, hasLength(29));
      expect(feb2024.daily.last.day, Day(2024, 2, 29));
      expect(feb2024.expenseTotal, Money(100));
    });

    test('a trailing moving average never looks into the future', () {
      final s = engine.summarise(
        records: [
          rec('2025-07-01', 300),
          rec('2025-07-02', 600),
          rec('2025-07-03', 900),
        ],
        range: DateRange(Day(2025, 7, 1), Day(2025, 7, 3)),
        today: Day(2025, 7, 3),
      );
      final avg = s.movingAverage(3);
      expect(avg[0], Money(300)); // only day 1 available
      expect(avg[1], Money(450)); // (300+600)/2
      expect(avg[2], Money(600)); // (300+600+900)/3
    });
  });

  group('derived splits', () {
    test('separates recurring fixed costs from discretionary spend', () {
      final s = engine.summarise(
        records: [
          rec('2025-07-01', 120000, cat: 2, name: 'Rent', recurring: true),
          rec('2025-07-03', 1099, cat: 6, name: 'Subs', recurring: true),
          rec('2025-07-04', 4200),
        ],
        range: july,
        today: Day(2025, 7, 31),
      );
      expect(s.fixedTotal, Money(121099));
      expect(s.discretionaryTotal, Money(4200));
      expect(s.fixedTotal + s.discretionaryTotal, s.expenseTotal);
    });

    test('the discretionary daily series excludes recurring spikes', () {
      final s = engine.summarise(
        records: [
          rec('2025-07-01', 120000, cat: 2, name: 'Rent', recurring: true),
          rec('2025-07-01', 1500),
          rec('2025-07-02', 2000),
        ],
        range: july,
        today: Day(2025, 7, 31),
      );

      // The full series keeps everything, so totals still reconcile.
      expect(s.daily[0].total, Money(121500));
      // The discretionary series drops the rent, leaving day one comparable
      // with every other day rather than 60x larger.
      expect(s.dailyDiscretionary[0].total, Money(1500));
      expect(s.dailyDiscretionary[1].total, Money(2000));
      expect(s.dailyDiscretionary, hasLength(31));

      final discretionarySum = s.dailyDiscretionary.map((d) => d.total).sum();
      expect(discretionarySum, s.discretionaryTotal);
    });

    test('splits weekend from weekday spending', () {
      // 2025-07-05 is a Saturday, 2025-07-06 a Sunday, 2025-07-07 a Monday.
      final s = engine.summarise(
        records: [
          rec('2025-07-05', 1000),
          rec('2025-07-06', 2000),
          rec('2025-07-07', 400),
        ],
        range: july,
        today: Day(2025, 7, 31),
      );
      expect(s.weekendTotal, Money(3000));
      expect(s.weekdayTotal, Money(400));
    });

    test('ranks merchants and ignores unnamed ones', () {
      final s = engine.summarise(
        records: [
          rec('2025-07-01', 1000, merchant: 'Albert Heijn'),
          rec('2025-07-02', 2500, merchant: 'Albert Heijn'),
          rec('2025-07-03', 3000, merchant: 'Jumbo'),
          rec('2025-07-04', 9999),
        ],
        range: july,
        today: Day(2025, 7, 31),
      );
      expect(s.topMerchants.map((m) => m.merchant), ['Albert Heijn', 'Jumbo']);
      expect(s.topMerchants.first.total, Money(3500));
      expect(s.topMerchants.first.count, 2);
    });

    test('finds the largest single expense', () {
      final s = engine.summarise(
        records: [
          rec('2025-07-01', 1000),
          rec('2025-07-02', 8800),
          rec('2025-07-03', 400),
        ],
        range: july,
        today: Day(2025, 7, 31),
      );
      expect(s.largest?.amount, Money(8800));
    });
  });

  group('no-spend streaks', () {
    test('counts only elapsed days, not the rest of the month', () {
      // Spent on the 1st, nothing on the 2nd and 3rd, and today is the 3rd.
      final s = engine.summarise(
        records: [rec('2025-07-01', 1000)],
        range: july,
        today: Day(2025, 7, 3),
      );
      // The remaining 28 days have not happened, so they are not "no-spend".
      expect(s.noSpendDays, 2);
      expect(s.currentNoSpendStreak, 2);
    });

    test('finds the longest run in a completed month', () {
      final s = engine.summarise(
        records: [
          rec('2025-07-01', 100),
          rec('2025-07-08', 100),
          rec('2025-07-31', 100),
        ],
        range: july,
        today: Day(2025, 8, 1),
      );
      // 9th-30th inclusive is 22 days, the longest gap.
      expect(s.longestNoSpendStreak, 22);
      expect(s.currentNoSpendStreak, 0, reason: 'spent on the final day');
    });
  });

  group('monthly aggregates', () {
    test('produces a dense six-month series including empty months', () {
      final totals = engine.monthlyTotals(
        [
          rec('2025-07-01', 1000),
          rec('2025-05-01', 2000),
          rec('2025-02-01', 9999), // outside the window
        ],
        endMonth: Day(2025, 7, 15),
        months: 6,
      );
      expect(totals, hasLength(6));
      expect(totals.map((t) => t.month.isoMonth), [
        '2025-02',
        '2025-03',
        '2025-04',
        '2025-05',
        '2025-06',
        '2025-07',
      ]);
      expect(totals.last.total, Money(1000));
      expect(totals[3].total, Money(2000)); // May
      expect(totals[1].total, Money.zero); // March, no spending
    });

    test('spans a year boundary correctly', () {
      final totals = engine.monthlyTotals(
        [rec('2024-12-15', 500), rec('2025-01-10', 700)],
        endMonth: Day(2025, 2, 1),
        months: 3,
      );
      expect(totals.map((t) => t.month.isoMonth), [
        '2024-12',
        '2025-01',
        '2025-02',
      ]);
      expect(totals[0].total, Money(500));
      expect(totals[1].total, Money(700));
    });

    test('per-category series aligns to the same month slots', () {
      final byCategory = engine.categoryMonthlyTotals(
        [
          rec('2025-06-01', 1000, cat: 1),
          rec('2025-07-01', 1500, cat: 1),
          rec('2025-07-02', 800, cat: 2),
        ],
        endMonth: Day(2025, 7, 1),
        months: 3,
      );
      expect(byCategory[1], [Money.zero, Money(1000), Money(1500)]);
      expect(byCategory[2], [Money.zero, Money.zero, Money(800)]);
    });
  });
}
