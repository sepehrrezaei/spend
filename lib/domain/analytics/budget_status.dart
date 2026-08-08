/// Budget evaluation: not just "how much is left" but "am I on pace".
///
/// A bare remaining figure is nearly useless mid-period. Being 40% through a
/// grocery budget sounds fine on the 28th and alarming on the 3rd. Everything
/// here is about comparing spend against elapsed time.
library;

import 'package:meta/meta.dart';

import '../../core/date_range.dart';
import '../../core/day.dart';
import '../../core/money.dart';
import '../entities/budget_definition.dart';
import '../entities/enums.dart';
import '../entities/spend_record.dart';

/// How a budget is doing, in the terms a warning should use.
enum BudgetHealth {
  /// Spending is at or behind the rate the period is elapsing.
  onTrack,

  /// Ahead of pace, but the current rate still lands under the limit.
  watch,

  /// The current rate lands over the limit before the period ends.
  overPace,

  /// Already spent more than the limit.
  exceeded;

  bool get needsAttention => this != BudgetHealth.onTrack;
}

@immutable
class BudgetStatus {
  final BudgetDefinition budget;

  /// The period currently being measured.
  final DateRange period;

  final Day asOf;
  final Money spent;

  /// Transactions counted, so the UI can offer a drill-down.
  final int transactionCount;

  const BudgetStatus({
    required this.budget,
    required this.period,
    required this.asOf,
    required this.spent,
    required this.transactionCount,
  });

  Money get limit => budget.limit;

  /// Negative once the limit is passed, which is the point — "−€23.40" reads
  /// as overspend far more directly than a bar sitting at 104%.
  Money get remaining => limit - spent;

  /// Fraction of the limit used, or null when the limit is zero.
  double? get usedFraction => spent.ratioTo(limit);

  /// Fraction of the period that has passed.
  double get elapsedFraction => period.elapsedFraction(asOf);

  /// Spend rate relative to time rate. 1.0 is exactly on pace, 2.0 is
  /// spending twice as fast as the period is passing.
  ///
  /// Null when there is nothing meaningful to divide — a zero limit, or a
  /// period that has not started.
  double? get pace {
    final used = usedFraction;
    if (used == null || elapsedFraction == 0) return null;
    return used / elapsedFraction;
  }

  /// Where spending lands at the current rate.
  Money get projected =>
      elapsedFraction == 0 ? Money.zero : spent * (1 / elapsedFraction);

  bool get isExceeded => spent > limit;

  /// Classified on [pace], not on a bare projection comparison.
  ///
  /// Comparing [projected] against [limit] directly is far too twitchy: on the
  /// 15th of a 31-day month, spending exactly half the budget projects 3% over
  /// and would raise a warning about what is essentially perfect pacing. Real
  /// spending is lumpy — groceries on some days, none on others — so the bands
  /// carry tolerance:
  ///
  ///  * within 5% of linear -> on track
  ///  * 5-15% ahead -> worth a glance
  ///  * more than 15% ahead -> genuinely heading over
  BudgetHealth get health {
    if (isExceeded) return BudgetHealth.exceeded;
    final p = pace;
    // Null pace means a zero limit or a period that has not begun; neither is
    // a problem to warn about.
    if (p == null) return BudgetHealth.onTrack;
    if (p > 1.15) return BudgetHealth.overPace;
    if (p > 1.05) return BudgetHealth.watch;
    return BudgetHealth.onTrack;
  }

  /// Days left in the period, counting today.
  int get daysRemaining => asOf >= period.end ? 0 : asOf.daysUntil(period.end);

  /// What could be spent per remaining day to finish exactly on the limit.
  /// Zero once the limit is gone.
  Money get allowancePerRemainingDay {
    if (remaining.isNegative || daysRemaining <= 0) return Money.zero;
    return remaining.dividedBy(daysRemaining);
  }
}

class BudgetEvaluator {
  const BudgetEvaluator();

  /// Evaluates every budget in force on [today].
  ///
  /// [records] must span the longest period among [budgets] — a yearly budget
  /// needs a year of transactions to be judged. Records outside a given
  /// budget's own period are filtered out per budget, so passing extra is
  /// harmless.
  List<BudgetStatus> evaluate({
    required List<BudgetDefinition> budgets,
    required List<SpendRecord> records,
    required Day today,
    int weekStartsOn = DateTime.monday,
  }) {
    final statuses = <BudgetStatus>[];

    for (final budget in budgets) {
      if (!budget.appliesOn(today)) continue;

      final period = periodFor(budget, today, weekStartsOn: weekStartsOn);
      final matching = records.where(
        (r) =>
            r.isExpense &&
            period.contains(r.occurredOn) &&
            (budget.categoryId == null || r.categoryId == budget.categoryId),
      );

      statuses.add(
        BudgetStatus(
          budget: budget,
          period: period,
          asOf: today,
          spent: matching.map((r) => r.amount).sum(),
          transactionCount: matching.length,
        ),
      );
    }

    // Overall first, then whichever categories need attention most.
    statuses.sort((a, b) {
      if (a.budget.isOverall != b.budget.isOverall) {
        return a.budget.isOverall ? -1 : 1;
      }
      final byHealth = b.health.index.compareTo(a.health.index);
      if (byHealth != 0) return byHealth;
      return b.spent.compareTo(a.spent);
    });

    return statuses;
  }

  /// The current instance of a budget's period, containing [today].
  DateRange periodFor(
    BudgetDefinition budget,
    Day today, {
    int weekStartsOn = DateTime.monday,
  }) => switch (budget.period) {
    BudgetPeriod.weekly => DateRange.week(today, weekStartsOn: weekStartsOn),
    BudgetPeriod.monthly => DateRange.month(today),
    BudgetPeriod.yearly => DateRange.year(today),
  };

  /// The widest span any of [budgets] needs, so a caller can fetch
  /// transactions once rather than per budget.
  DateRange spanFor(
    List<BudgetDefinition> budgets,
    Day today, {
    int weekStartsOn = DateTime.monday,
  }) {
    if (budgets.isEmpty) return DateRange.month(today);
    var start = today;
    var end = today;
    for (final b in budgets) {
      final r = periodFor(b, today, weekStartsOn: weekStartsOn);
      if (r.start < start) start = r.start;
      if (r.end > end) end = r.end;
    }
    return DateRange(start, end);
  }
}
