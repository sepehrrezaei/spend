/// Deterministic analysis of spending.
///
/// Pure functions over plain lists — no database, no Flutter, no clock except
/// the one passed in. That makes every number here reproducible from a
/// literal fixture, which matters because these are the figures the dashboard
/// displays and the language model narrates. If they are wrong, they are
/// wrong invisibly.
library;

import '../../core/date_range.dart';
import '../../core/day.dart';
import '../../core/money.dart';
import '../entities/spend_record.dart';
import 'period_summary.dart';

class AnalyticsEngine {
  const AnalyticsEngine();

  /// Analyses [records] over [range].
  ///
  /// [previousRecords] are the transactions of the preceding comparable
  /// period. When the current period is still running they are automatically
  /// truncated to the same number of elapsed days, so a half-finished month is
  /// never compared against a complete one — the single most common way a
  /// spending dashboard lies to its user.
  ///
  /// [today] is injectable so tests are not at the mercy of the wall clock.
  PeriodSummary summarise({
    required List<SpendRecord> records,
    required DateRange range,
    List<SpendRecord> previousRecords = const [],
    DateRange? previousRange,
    Day? today,
  }) {
    final now = today ?? Day.today();

    final Day asOf;
    final int elapsedDays;
    if (now < range.start) {
      asOf = range.start;
      elapsedDays = 0;
    } else if (now >= range.end) {
      asOf = range.end;
      elapsedDays = range.dayCount;
    } else {
      asOf = now;
      elapsedDays = range.start.daysUntil(now) + 1;
    }

    final inRange = records.where((r) => range.contains(r.occurredOn)).toList();
    final expenses = inRange.where((r) => r.isExpense).toList();
    final income = inRange.where((r) => r.isIncome).toList();

    // Match the comparison window to however much of this period has actually
    // elapsed.
    final comparable = previousRange == null
        ? previousRecords
        : () {
            final window = elapsedDays < range.dayCount
                ? previousRange.firstDays(elapsedDays)
                : previousRange;
            return previousRecords
                .where((r) => window.contains(r.occurredOn))
                .toList();
          }();
    final previousExpenses = comparable.where((r) => r.isExpense).toList();

    return PeriodSummary(
      range: range,
      asOf: asOf,
      elapsedDays: elapsedDays,
      expenseTotal: expenses.map((r) => r.amount).sum(),
      incomeTotal: income.map((r) => r.amount).sum(),
      transactionCount: inRange.length,
      previousExpenseTotal: previousExpenses.map((r) => r.amount).sum(),
      categories: _categorySlices(expenses, previousExpenses),
      daily: _dailyPoints(expenses, range),
      dailyDiscretionary: _dailyPoints(
        expenses.where((r) => !r.isRecurring).toList(),
        range,
      ),
      fixedTotal: expenses
          .where((r) => r.isRecurring)
          .map((r) => r.amount)
          .sum(),
      discretionaryTotal: expenses
          .where((r) => !r.isRecurring)
          .map((r) => r.amount)
          .sum(),
      weekendTotal: expenses
          .where((r) => r.occurredOn.isWeekend)
          .map((r) => r.amount)
          .sum(),
      weekdayTotal: expenses
          .where((r) => !r.occurredOn.isWeekend)
          .map((r) => r.amount)
          .sum(),
      topMerchants: _topMerchants(expenses),
      largest: _largest(expenses),
    );
  }

  List<CategorySlice> _categorySlices(
    List<SpendRecord> expenses,
    List<SpendRecord> previousExpenses,
  ) {
    final total = expenses.map((r) => r.amount).sum();

    final grouped = <int, List<SpendRecord>>{};
    for (final r in expenses) {
      grouped.putIfAbsent(r.categoryId, () => []).add(r);
    }

    final previousByCategory = <int, Money>{};
    for (final r in previousExpenses) {
      previousByCategory[r.categoryId] =
          (previousByCategory[r.categoryId] ?? Money.zero) + r.amount;
    }

    final slices = <CategorySlice>[];
    for (final entry in grouped.entries) {
      final items = entry.value;
      final subtotal = items.map((r) => r.amount).sum();
      final first = items.first;
      slices.add(
        CategorySlice(
          categoryId: entry.key,
          name: first.categoryName,
          icon: first.categoryIcon,
          color: first.categoryColor,
          total: subtotal,
          count: items.length,
          // Guarded against a zero total, which happens when a period contains
          // only a refund that nets out.
          share: total.isZero ? 0 : subtotal.minor / total.minor,
          previousTotal: previousByCategory[entry.key] ?? Money.zero,
        ),
      );
    }

    slices.sort((a, b) => b.total.compareTo(a.total));
    return slices;
  }

  /// Every day in the range, including those with no transactions.
  List<DailyPoint> _dailyPoints(List<SpendRecord> expenses, DateRange range) {
    final totals = <Day, Money>{};
    final counts = <Day, int>{};
    for (final r in expenses) {
      totals[r.occurredOn] = (totals[r.occurredOn] ?? Money.zero) + r.amount;
      counts[r.occurredOn] = (counts[r.occurredOn] ?? 0) + 1;
    }
    return [
      for (final day in range.days)
        DailyPoint(
          day: day,
          total: totals[day] ?? Money.zero,
          count: counts[day] ?? 0,
        ),
    ];
  }

  List<MerchantTotal> _topMerchants(
    List<SpendRecord> expenses, {
    int limit = 5,
  }) {
    final totals = <String, Money>{};
    final counts = <String, int>{};
    for (final r in expenses) {
      final name = r.merchant.trim();
      if (name.isEmpty) continue;
      totals[name] = (totals[name] ?? Money.zero) + r.amount;
      counts[name] = (counts[name] ?? 0) + 1;
    }
    final list = [
      for (final e in totals.entries)
        MerchantTotal(merchant: e.key, total: e.value, count: counts[e.key]!),
    ]..sort((a, b) => b.total.compareTo(a.total));
    return list.take(limit).toList();
  }

  SpendRecord? _largest(List<SpendRecord> expenses) {
    if (expenses.isEmpty) return null;
    return expenses.reduce((a, b) => b.amount > a.amount ? b : a);
  }

  /// Monthly expense totals over the [months] months ending with [range].
  ///
  /// Feeds the composition chart and gives the anomaly rules a baseline to
  /// judge the current month against.
  List<({Day month, Money total})> monthlyTotals(
    List<SpendRecord> records, {
    required Day endMonth,
    int months = 6,
  }) {
    final start = endMonth.firstOfMonth.addMonths(-(months - 1));
    final buckets = <String, Money>{};
    for (var m = start; m <= endMonth.firstOfMonth; m = m.addMonths(1)) {
      buckets[m.isoMonth] = Money.zero;
    }
    for (final r in records) {
      if (!r.isExpense) continue;
      final key = r.occurredOn.isoMonth;
      if (!buckets.containsKey(key)) continue;
      buckets[key] = buckets[key]! + r.amount;
    }
    return [
      for (var m = start; m <= endMonth.firstOfMonth; m = m.addMonths(1))
        (month: m, total: buckets[m.isoMonth]!),
    ];
  }

  /// Per-category monthly totals, for spotting a category trending up or down
  /// over time rather than only against last month.
  Map<int, List<Money>> categoryMonthlyTotals(
    List<SpendRecord> records, {
    required Day endMonth,
    int months = 6,
  }) {
    final start = endMonth.firstOfMonth.addMonths(-(months - 1));
    final monthKeys = <String>[];
    for (var m = start; m <= endMonth.firstOfMonth; m = m.addMonths(1)) {
      monthKeys.add(m.isoMonth);
    }

    final result = <int, List<Money>>{};
    for (final r in records) {
      if (!r.isExpense) continue;
      final index = monthKeys.indexOf(r.occurredOn.isoMonth);
      if (index < 0) continue;
      final series = result.putIfAbsent(
        r.categoryId,
        () => List.filled(monthKeys.length, Money.zero, growable: false),
      );
      series[index] = series[index] + r.amount;
    }
    return result;
  }
}
