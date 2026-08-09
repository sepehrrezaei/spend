import 'package:flutter_test/flutter_test.dart';
import 'package:spend/core/date_range.dart';
import 'package:spend/core/day.dart';
import 'package:spend/core/money.dart';
import 'package:spend/domain/analytics/budget_status.dart';
import 'package:spend/domain/entities/budget_definition.dart';
import 'package:spend/domain/entities/enums.dart';
import 'package:spend/domain/entities/spend_record.dart';

const evaluator = BudgetEvaluator();

var _nextId = 1;

SpendRecord rec(String iso, int minor, {int cat = 1, bool income = false}) =>
    SpendRecord(
      id: _nextId++,
      amount: Money(minor),
      occurredOn: Day.parse(iso),
      categoryId: cat,
      categoryName: 'Groceries',
      categoryIcon: 'tag',
      categoryColor: 0,
      categoryKind: income ? CategoryKind.income : CategoryKind.expense,
    );

BudgetDefinition budget({
  int id = 1,
  int? categoryId = 1,
  int limit = 45000,
  BudgetPeriod period = BudgetPeriod.monthly,
  String startsOn = '2025-01-01',
  String? endsOn,
}) => BudgetDefinition(
  id: id,
  categoryId: categoryId,
  period: period,
  limit: Money(limit),
  startsOn: Day.parse(startsOn),
  endsOn: endsOn == null ? null : Day.parse(endsOn),
);

/// Evaluates one budget and returns its status.
BudgetStatus statusOf(
  BudgetDefinition b,
  List<SpendRecord> records,
  String today,
) => evaluator
    .evaluate(budgets: [b], records: records, today: Day.parse(today))
    .single;

void main() {
  setUp(() => _nextId = 1);

  group('pace', () {
    test('spending in step with elapsed time is on track', () {
      // Day 15 of 31 is ~48% elapsed; half the budget spent.
      final s = statusOf(budget(limit: 45000), [
        rec('2025-07-01', 22500),
      ], '2025-07-15');
      expect(s.spent, Money(22500));
      expect(s.remaining, Money(22500));
      expect(s.usedFraction, closeTo(0.5, 1e-9));
      expect(s.elapsedFraction, closeTo(15 / 31, 1e-9));
      expect(s.pace, closeTo(0.5 / (15 / 31), 1e-9));
      expect(s.health, BudgetHealth.onTrack);
    });

    test('mildly ahead of pace is a glance, not an alarm', () {
      // 16/31 elapsed (51.6%), 55% of the budget spent -> pace 1.07, inside
      // the 5-15% band.
      final s = statusOf(budget(limit: 100000), [
        rec('2025-07-01', 55000),
      ], '2025-07-16');
      expect(s.pace, closeTo(1.066, 0.01));
      expect(s.health, BudgetHealth.watch);
      expect(s.health.needsAttention, isTrue);
    });

    test('being a few percent ahead of linear is still on track', () {
      // The case that used to raise a false alarm: exactly half the budget on
      // day 15 of 31 projects 3% over, which is noise.
      final s = statusOf(budget(limit: 45000), [
        rec('2025-07-01', 22500),
      ], '2025-07-15');
      expect(s.projected, greaterThan(Money(45000)));
      expect(s.health, BudgetHealth.onTrack);
    });

    test('a rate that lands over the limit is flagged before it does', () {
      // A quarter of the month gone, three quarters of the budget spent.
      final s = statusOf(
        budget(limit: 40000),
        [rec('2025-07-01', 30000)],
        '2025-07-08', // 8/31 elapsed
      );
      expect(s.isExceeded, isFalse, reason: 'not over yet');
      expect(s.projected, greaterThan(Money(40000)));
      expect(s.health, BudgetHealth.overPace);
      expect(s.health.needsAttention, isTrue);
    });

    test('past the limit is exceeded, and remaining goes negative', () {
      final s = statusOf(budget(limit: 40000), [
        rec('2025-07-01', 42340),
      ], '2025-07-20');
      expect(s.isExceeded, isTrue);
      expect(s.health, BudgetHealth.exceeded);
      // Negative rather than clamped to zero: the overspend is the number
      // worth showing.
      expect(s.remaining, Money(-2340));
      expect(s.remaining.isNegative, isTrue);
    });

    test('nothing spent is on track, whatever the date', () {
      final s = statusOf(budget(), [], '2025-07-28');
      expect(s.spent, Money.zero);
      expect(s.pace, 0);
      expect(s.health, BudgetHealth.onTrack);
    });
  });

  group('projection and allowance', () {
    test('projects the period total from the current rate', () {
      // €10/day for 10 days of a 31-day month -> €310 projected.
      final s = statusOf(budget(limit: 50000), [
        for (var d = 1; d <= 10; d++)
          rec('2025-07-${d.toString().padLeft(2, "0")}', 1000),
      ], '2025-07-10');
      expect(s.spent, Money(10000));
      expect(s.projected, Money(31000));
    });

    test('daily allowance spreads what is left over the days left', () {
      // €210 left, 21 days remaining after today -> €10/day.
      final s = statusOf(budget(limit: 30000), [
        rec('2025-07-01', 9000),
      ], '2025-07-10');
      expect(s.remaining, Money(21000));
      expect(s.daysRemaining, 21);
      expect(s.allowancePerRemainingDay, Money(1000));
    });

    test('no allowance once the budget is gone', () {
      final s = statusOf(budget(limit: 10000), [
        rec('2025-07-01', 12000),
      ], '2025-07-10');
      expect(s.allowancePerRemainingDay, Money.zero);
    });

    test('the final day of a period has no days remaining', () {
      final s = statusOf(budget(), [rec('2025-07-01', 1000)], '2025-07-31');
      expect(s.daysRemaining, 0);
      expect(s.elapsedFraction, 1.0);
      expect(s.allowancePerRemainingDay, Money.zero);
    });

    test('a zero limit degrades gracefully rather than dividing by zero', () {
      final s = statusOf(budget(limit: 0), [
        rec('2025-07-01', 5000),
      ], '2025-07-10');
      expect(s.usedFraction, isNull);
      expect(s.pace, isNull);
      expect(s.health, BudgetHealth.exceeded, reason: 'anything exceeds zero');
    });
  });

  group('scoping', () {
    test('a category budget counts only that category', () {
      final s = statusOf(budget(categoryId: 1, limit: 50000), [
        rec('2025-07-02', 10000, cat: 1),
        rec('2025-07-03', 90000, cat: 2), // different category
      ], '2025-07-15');
      expect(s.spent, Money(10000));
      expect(s.transactionCount, 1);
    });

    test('an overall budget counts every category', () {
      final s = statusOf(budget(categoryId: null, limit: 200000), [
        rec('2025-07-02', 10000, cat: 1),
        rec('2025-07-03', 90000, cat: 2),
      ], '2025-07-15');
      expect(s.budget.isOverall, isTrue);
      expect(s.spent, Money(100000));
      expect(s.transactionCount, 2);
    });

    test('income is never counted against a spending limit', () {
      final s = statusOf(budget(categoryId: null, limit: 50000), [
        rec('2025-07-02', 10000, cat: 1),
        rec('2025-07-03', 300000, cat: 9, income: true),
      ], '2025-07-15');
      expect(s.spent, Money(10000));
    });

    test('transactions outside the current period are excluded', () {
      final s = statusOf(budget(limit: 50000), [
        rec('2025-06-30', 40000), // last month
        rec('2025-07-05', 5000),
        rec('2025-08-01', 40000), // next month
      ], '2025-07-15');
      expect(s.spent, Money(5000));
    });
  });

  group('periods', () {
    test('weekly budgets measure the current week', () {
      // 2025-07-16 is a Wednesday; the Monday week is 14th-20th.
      final s = statusOf(budget(period: BudgetPeriod.weekly, limit: 10000), [
        rec('2025-07-13', 9000), // previous week (Sunday)
        rec('2025-07-14', 2000), // this week
        rec('2025-07-16', 1000),
      ], '2025-07-16');
      expect(s.period, DateRange(Day(2025, 7, 14), Day(2025, 7, 20)));
      expect(s.spent, Money(3000));
    });

    test('yearly budgets measure the calendar year', () {
      final s = statusOf(budget(period: BudgetPeriod.yearly, limit: 1000000), [
        rec('2024-12-31', 50000),
        rec('2025-03-01', 20000),
      ], '2025-07-16');
      expect(s.period, DateRange(Day(2025, 1, 1), Day(2025, 12, 31)));
      expect(s.spent, Money(20000));
    });

    test('spanFor covers the widest period so one query serves all', () {
      final span = evaluator.spanFor([
        budget(id: 1, period: BudgetPeriod.weekly),
        budget(id: 2, period: BudgetPeriod.monthly),
        budget(id: 3, period: BudgetPeriod.yearly),
      ], Day(2025, 7, 16));
      expect(span.start, Day(2025, 1, 1));
      expect(span.end, Day(2025, 12, 31));
    });
  });

  group('applicability', () {
    test('a budget that has not started yet is skipped', () {
      final statuses = evaluator.evaluate(
        budgets: [budget(startsOn: '2025-09-01')],
        records: [rec('2025-07-05', 1000)],
        today: Day(2025, 7, 15),
      );
      expect(statuses, isEmpty);
    });

    test('a superseded budget is skipped', () {
      final statuses = evaluator.evaluate(
        budgets: [budget(startsOn: '2025-01-01', endsOn: '2025-06-30')],
        records: [rec('2025-07-05', 1000)],
        today: Day(2025, 7, 15),
      );
      expect(statuses, isEmpty);
    });

    test('the limit in force on the day is the one applied', () {
      final old = budget(
        id: 1,
        limit: 30000,
        startsOn: '2025-01-01',
        endsOn: '2025-06-30',
      );
      final current = budget(id: 2, limit: 50000, startsOn: '2025-07-01');
      final statuses = evaluator.evaluate(
        budgets: [old, current],
        records: [rec('2025-07-05', 1000)],
        today: Day(2025, 7, 15),
      );
      expect(statuses, hasLength(1));
      expect(statuses.single.limit, Money(50000));
    });
  });

  group('ordering', () {
    test('overall first, then whatever needs attention most', () {
      final statuses = evaluator.evaluate(
        budgets: [
          budget(id: 1, categoryId: 1, limit: 10000), // will be exceeded
          budget(id: 2, categoryId: 2, limit: 100000), // on track
          budget(id: 3, categoryId: null, limit: 500000), // overall
        ],
        records: [
          rec('2025-07-02', 15000, cat: 1),
          rec('2025-07-02', 1000, cat: 2),
        ],
        today: Day(2025, 7, 15),
      );

      expect(statuses.first.budget.isOverall, isTrue);
      expect(statuses[1].budget.categoryId, 1);
      expect(statuses[1].health, BudgetHealth.exceeded);
      expect(statuses.last.health, BudgetHealth.onTrack);
    });
  });
}
