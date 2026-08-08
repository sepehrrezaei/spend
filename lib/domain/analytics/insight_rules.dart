/// Observations derived from spending, computed arithmetically.
///
/// This is the floor the Insights tab stands on. Every card here is produced
/// by explicit rules over real figures, so the tab is useful with no language
/// model installed at all. When a model *is* available it receives these same
/// facts and rewrites them as prose — it never generates the numbers, and it
/// never decides what is worth pointing out.
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../../core/date_range.dart';
import '../../core/day.dart';
import '../../core/money.dart';
import '../entities/spend_record.dart';
import 'budget_status.dart';
import 'period_summary.dart';

enum InsightSeverity {
  /// Something went well and is worth reinforcing.
  good,

  /// Neutral context.
  info,

  /// Worth a look.
  caution,

  /// Needs action now.
  alert;

  /// Ordering weight for surfacing the most important first.
  int get weight => switch (this) {
    InsightSeverity.alert => 3,
    InsightSeverity.caution => 2,
    InsightSeverity.good => 1,
    InsightSeverity.info => 0,
  };
}

/// One observation.
@immutable
class Insight {
  /// Stable identifier for the rule that produced this, so the UI can pick an
  /// icon and tests can assert on rules rather than on wording.
  final String rule;

  final InsightSeverity severity;

  /// A short factual headline.
  final String title;

  /// The supporting numbers, in plain language.
  final String detail;

  /// The same information structured, for the language model. Kept separate
  /// from [detail] so the model reasons over values rather than parsing
  /// English back into numbers.
  final Map<String, Object?> facts;

  const Insight({
    required this.rule,
    required this.severity,
    required this.title,
    required this.detail,
    this.facts = const {},
  });
}

class InsightRules {
  const InsightRules(this.money);

  /// Formats an amount for display.
  ///
  /// Injected rather than imported so this file stays free of locale and
  /// Flutter concerns, while the text it produces still reads as "€12.40"
  /// instead of the bare "12.4" that Money.toString gives.
  final String Function(Money) money;

  /// Below this, a change is not worth mentioning however large it looks in
  /// percentage terms. A category going from €2 to €6 is a 200% rise and
  /// completely meaningless.
  static const _materialAmount = Money(2000); // €20

  /// Evaluates every rule and returns the results, most important first.
  List<Insight> evaluate({
    required PeriodSummary summary,
    List<BudgetStatus> budgets = const [],
    Map<int, List<Money>> categoryHistory = const {},
    List<SpendRecord> historyRecords = const [],
    Map<int, String> categoryNames = const {},
    required Day today,
  }) {
    final insights = <Insight>[
      ..._budgetInsights(budgets, categoryNames),
      ..._categoryAnomalies(summary, categoryHistory),
      ..._growthInsights(summary),
      ..._paceInsight(summary),
      ..._fixedCostInsight(summary),
      ..._weekendInsight(summary),
      ..._largePurchaseInsight(summary),
      ..._streakInsight(summary),
      ..._newRecurringInsights(historyRecords, today),
    ];

    insights.sort((a, b) => b.severity.weight.compareTo(a.severity.weight));
    return insights;
  }

  // ------------------------------------------------------------------ budget

  Iterable<Insight> _budgetInsights(
    List<BudgetStatus> budgets,
    Map<int, String> categoryNames,
  ) sync* {
    for (final b in budgets) {
      if (!b.health.needsAttention) continue;

      // Name the category. "This category is over budget" leaves the reader
      // to work out which one, which is the only thing they wanted to know.
      final name = b.budget.isOverall
          ? 'Overall spending'
          : categoryNames[b.budget.categoryId] ?? 'One category';
      final scope = b.budget.isOverall ? 'overall' : 'category';

      if (b.isExceeded) {
        yield Insight(
          rule: 'budget_exceeded',
          severity: InsightSeverity.alert,
          title: '$name is over budget',
          detail:
              'Over by ${money(b.remaining.abs())} with ${b.daysRemaining} '
              '${b.daysRemaining == 1 ? "day" : "days"} left in the period.',
          facts: {
            'scope': scope,
            if (!b.budget.isOverall) 'category': name,
            'limit_minor': b.limit.minor,
            'spent_minor': b.spent.minor,
            'over_by_minor': b.remaining.abs().minor,
            'days_remaining': b.daysRemaining,
          },
        );
      } else if (b.health == BudgetHealth.overPace) {
        yield Insight(
          rule: 'budget_over_pace',
          severity: InsightSeverity.caution,
          title: '$name is running ahead of budget',
          detail:
              '${(b.elapsedFraction * 100).round()}% through the period but '
              '${((b.usedFraction ?? 0) * 100).round()}% of the limit spent. '
              'At this rate it lands at ${money(b.projected)}.',
          facts: {
            'scope': scope,
            if (!b.budget.isOverall) 'category': name,
            'limit_minor': b.limit.minor,
            'spent_minor': b.spent.minor,
            'projected_minor': b.projected.minor,
            'percent_of_limit_spent': ((b.usedFraction ?? 0) * 100).round(),
            'percent_of_period_elapsed': (b.elapsedFraction * 100).round(),
            'daily_allowance_minor': b.allowancePerRemainingDay.minor,
          },
        );
      }
    }
  }

  // --------------------------------------------------------------- anomalies

  /// Flags a category well outside its own recent norm.
  ///
  /// Uses a z-score against the previous months rather than a fixed
  /// percentage, because "normal" differs wildly per category: groceries vary
  /// a little each month, and a category that is usually zero jumping to €40
  /// matters far more than dining moving by the same amount.
  Iterable<Insight> _categoryAnomalies(
    PeriodSummary summary,
    Map<int, List<Money>> history,
  ) sync* {
    final candidates = <({Insight insight, double magnitude})>[];

    for (final slice in summary.categories) {
      final series = history[slice.categoryId];
      // The last entry is the current month, so drop it from the baseline —
      // comparing a value against a mean that includes it dampens exactly the
      // signal being looked for.
      if (series == null || series.length < 4) continue;
      final prior = series.sublist(0, series.length - 1);

      // Months with nothing in them are not evidence about what is normal for
      // a category — usually they just predate the app being used. Averaging
      // them in drags the mean toward zero and makes ordinary spending look
      // extraordinary, which flagged six categories at once on a database
      // holding two months of history. A category needs a real track record
      // before it can be called abnormal.
      final observed = prior.where((m) => !m.isZero).toList();
      if (observed.length < 3) continue;

      final values = observed.map((m) => m.minor.toDouble()).toList();
      final mean = values.reduce((a, b) => a + b) / values.length;
      if (mean <= 0) continue;

      final variance =
          values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
          values.length;
      final stdDev = variance <= 0 ? 0.0 : math.sqrt(variance);

      // A category with identical months has zero deviation, which would make
      // any change look infinitely significant. Floor it at 15% of the mean.
      final effectiveDev = stdDev < mean * 0.15 ? mean * 0.15 : stdDev;

      final current = slice.total.minor.toDouble();
      final z = (current - mean) / effectiveDev;
      final difference = Money((current - mean).round());

      if (z.abs() < 1.5) continue;
      if (difference.abs() < _materialAmount) continue;

      final up = z > 0;
      candidates.add((
        magnitude: z.abs(),
        insight: Insight(
          rule: up ? 'category_unusually_high' : 'category_unusually_low',
          severity: up ? InsightSeverity.caution : InsightSeverity.good,
          title: '${slice.name} is unusually ${up ? "high" : "low"}',
          detail:
              '${money(slice.total)} this period against a '
              '${observed.length}-month average of ${money(Money(mean.round()))}'
              ' — ${up ? "up" : "down"} ${money(difference.abs())}.',
          facts: {
            'category': slice.name,
            'category_id': slice.categoryId,
            'current_minor': slice.total.minor,
            'average_minor': mean.round(),
            'difference_minor': difference.minor,
            // Deliberately no z-score. It is how the rule decides, not
            // something to quote at a person, and a bare 2.14 in the facts is
            // one more number for the model to misattribute.
            'months_of_history': observed.length,
          },
        ),
      ));
    }

    // Only the two most extreme. A wall of "unusually high" cards is noise
    // that buries whichever one actually matters.
    candidates.sort((a, b) => b.magnitude.compareTo(a.magnitude));
    for (final c in candidates.take(2)) {
      yield c.insight;
    }
  }

  // ------------------------------------------------------------------ growth

  Iterable<Insight> _growthInsights(PeriodSummary summary) sync* {
    // Only the single fastest riser, and only when the money involved is
    // material. Listing every category that moved would bury the one that
    // matters.
    CategorySlice? worst;
    var worstFraction = 0.0;

    for (final slice in summary.categories) {
      final fraction = slice.deltaFraction;
      if (fraction == null || fraction <= 0.25) continue;
      if (slice.delta < _materialAmount) continue;
      if (fraction > worstFraction) {
        worstFraction = fraction;
        worst = slice;
      }
    }

    if (worst == null) return;
    yield Insight(
      rule: 'category_growing',
      severity: InsightSeverity.caution,
      title: '${worst.name} is growing fastest',
      detail:
          'Up ${money(worst.delta)} on the comparable period — '
          '${money(worst.previousTotal)} to ${money(worst.total)}.',
      facts: {
        'category': worst.name,
        'category_id': worst.categoryId,
        'previous_minor': worst.previousTotal.minor,
        'current_minor': worst.total.minor,
        'increase_minor': worst.delta.minor,
        // A whole-number percentage rather than a raw fraction. Handed
        // "10.476", a small model reads it as "10.476 times" — the figure is
        // correct and the sentence is nonsense.
        'increase_percent': (worstFraction * 100).round(),
      },
    );
  }

  // -------------------------------------------------------------------- pace

  Iterable<Insight> _paceInsight(PeriodSummary summary) sync* {
    if (!summary.isPartial || summary.isEmpty) return;
    final fraction = summary.deltaFraction;
    if (fraction == null) return;
    if (fraction.abs() < 0.12) return;
    if (summary.delta.abs() < _materialAmount) return;

    final up = fraction > 0;
    yield Insight(
      rule: up ? 'period_ahead' : 'period_behind',
      severity: up ? InsightSeverity.caution : InsightSeverity.good,
      title: up
          ? 'Spending faster than last period'
          : 'Spending less than last period',
      detail:
          '${money(summary.expenseTotal)} over the first ${summary.elapsedDays} days '
          'against ${money(summary.previousExpenseTotal)} over the same stretch last '
          'time. On pace for ${money(summary.projectedTotal)}.',
      facts: {
        'current_minor': summary.expenseTotal.minor,
        'previous_same_days_minor': summary.previousExpenseTotal.minor,
        'change_percent': (fraction * 100).round(),
        'projected_minor': summary.projectedTotal.minor,
        'elapsed_days': summary.elapsedDays,
        'period_days': summary.range.dayCount,
      },
    );
  }

  // ------------------------------------------------------------- composition

  Iterable<Insight> _fixedCostInsight(PeriodSummary summary) sync* {
    if (summary.expenseTotal.isZero || summary.fixedTotal.isZero) return;
    final share = summary.fixedTotal.ratioTo(summary.expenseTotal);
    if (share == null || share < 0.55) return;

    yield Insight(
      rule: 'fixed_cost_heavy',
      severity: InsightSeverity.info,
      title: 'Most of this period is committed spending',
      detail:
          '${(share * 100).round()}% of it (${money(summary.fixedTotal)}) is rent and '
          'subscriptions. Only ${money(summary.discretionaryTotal)} was discretionary.',
      facts: {
        'fixed_minor': summary.fixedTotal.minor,
        'discretionary_minor': summary.discretionaryTotal.minor,
        'fixed_percent': (share * 100).round(),
      },
    );
  }

  Iterable<Insight> _weekendInsight(PeriodSummary summary) sync* {
    if (summary.expenseTotal.isZero) return;

    // Per-day rates, not totals. There are only two weekend days in five
    // weekdays, so raw totals would always favour weekdays and say nothing.
    var weekendDays = 0;
    var weekdayDays = 0;
    for (final d in summary.daily) {
      if (d.day > summary.asOf) break;
      d.day.isWeekend ? weekendDays++ : weekdayDays++;
    }
    if (weekendDays == 0 || weekdayDays == 0) return;

    final weekendRate = summary.weekendTotal.dividedBy(weekendDays);
    final weekdayRate = summary.weekdayTotal.dividedBy(weekdayDays);
    if (weekdayRate.isZero) return;

    final ratio = weekendRate.ratioTo(weekdayRate);
    if (ratio == null || ratio < 1.6) return;
    if (weekendRate - weekdayRate < Money(1000)) return;

    yield Insight(
      rule: 'weekend_heavy',
      severity: InsightSeverity.info,
      title: 'Weekends cost noticeably more',
      detail:
          '${money(weekendRate)} a day at weekends against '
          '${money(weekdayRate)} on weekdays — '
          '${ratio.toStringAsFixed(1)} times as much.',
      facts: {
        'weekend_daily_minor': weekendRate.minor,
        'weekday_daily_minor': weekdayRate.minor,
        'weekend_percent_of_weekday': (ratio * 100).round(),
      },
    );
  }

  Iterable<Insight> _largePurchaseInsight(PeriodSummary summary) sync* {
    final largest = summary.largest;
    if (largest == null || summary.expenseTotal.isZero) return;
    if (largest.isRecurring) return; // rent dominating is not news

    final share = largest.amount.ratioTo(summary.expenseTotal);
    if (share == null || share < 0.25) return;

    yield Insight(
      rule: 'single_large_purchase',
      severity: InsightSeverity.info,
      title: 'One purchase dominates this period',
      detail:
          '${money(largest.amount)} on ${largest.displayLabel} is '
          '${(share * 100).round()}% of everything spent.',
      facts: {
        'amount_minor': largest.amount.minor,
        'label': largest.displayLabel,
        'category': largest.categoryName,
        'percent_of_period': (share * 100).round(),
      },
    );
  }

  Iterable<Insight> _streakInsight(PeriodSummary summary) sync* {
    if (summary.longestNoSpendStreak < 3) return;
    yield Insight(
      rule: 'no_spend_streak',
      severity: InsightSeverity.good,
      title: '${summary.longestNoSpendStreak} days in a row without spending',
      detail: '${summary.noSpendDays} no-spend days so far this period.',
      facts: {
        'longest_streak': summary.longestNoSpendStreak,
        'current_streak': summary.currentNoSpendStreak,
        'no_spend_days': summary.noSpendDays,
      },
    );
  }

  // ----------------------------------------------------------- new recurring

  /// Spots a charge that looks like a subscription but has not been recorded
  /// as one.
  ///
  /// Three months, same merchant, near-identical amount. Catching these is
  /// what keeps the fixed-versus-discretionary split honest — an unrecorded
  /// subscription otherwise pollutes discretionary spending every month.
  Iterable<Insight> _newRecurringInsights(
    List<SpendRecord> records,
    Day today,
  ) sync* {
    if (records.isEmpty) return;

    final byMerchant = <String, List<SpendRecord>>{};
    for (final r in records) {
      if (r.isRecurring || !r.isExpense) continue;
      final key = r.merchant.trim().toLowerCase();
      if (key.isEmpty) continue;
      byMerchant.putIfAbsent(key, () => []).add(r);
    }

    for (final entry in byMerchant.entries) {
      final items = entry.value;
      if (items.length < 3) continue;

      final months = items.map((r) => r.occurredOn.isoMonth).toSet();
      if (months.length < 3) continue;

      // One charge per month, not several — three coffees in a month is not a
      // subscription.
      if (items.length > months.length + 1) continue;

      final amounts = items.map((r) => r.amount.minor).toList();
      final min = amounts.reduce((a, b) => a < b ? a : b);
      final max = amounts.reduce((a, b) => a > b ? a : b);
      if (min <= 0) continue;
      // Allow small variation: a subscription can change price slightly.
      if ((max - min) / min > 0.1) continue;

      final typical = Money(amounts.reduce((a, b) => a + b) ~/ amounts.length);
      if (typical < Money(200)) continue;

      yield Insight(
        rule: 'possible_subscription',
        severity: InsightSeverity.info,
        title: '${items.first.merchant} looks like a subscription',
        detail:
            '${money(typical)} charged in ${months.length} different months '
            'but not '
            'recorded as recurring.',
        facts: {
          'merchant': items.first.merchant,
          'typical_minor': typical.minor,
          'months_seen': months.length,
          'category': items.first.categoryName,
        },
      );
    }
  }
}

/// Everything the language model is allowed to see.
///
/// A closed set of already-computed values. The model receives this and writes
/// prose about it; it is never given raw transactions to add up, and anything
/// it says that is not derivable from here is a fabrication.
@immutable
class FinanceBrief {
  final DateRange period;
  final String currency;
  final Money spent;
  final Money previousSpent;
  final Money projected;
  final Money dailyAverage;
  final int elapsedDays;
  final int periodDays;
  final List<({String name, Money total, double share})> topCategories;
  final List<Insight> insights;

  const FinanceBrief({
    required this.period,
    required this.comparisonPeriod,
    required this.currency,
    required this.spent,
    required this.previousSpent,
    required this.projected,
    required this.dailyAverage,
    required this.elapsedDays,
    required this.periodDays,
    required this.topCategories,
    required this.insights,
  });

  /// The window [previousSpent] covers, stated so it cannot be guessed at.
  final DateRange comparisonPeriod;

  factory FinanceBrief.from({
    required PeriodSummary summary,
    required List<Insight> insights,
    required String currency,
  }) => FinanceBrief(
    period: summary.range,
    // Truncated to the elapsed length when the current period is still
    // running, matching how the engine computed the comparison.
    comparisonPeriod: summary.isPartial
        ? summary.range.previous().firstDays(summary.elapsedDays)
        : summary.range.previous(),
    currency: currency,
    spent: summary.expenseTotal,
    previousSpent: summary.previousExpenseTotal,
    projected: summary.projectedTotal,
    dailyAverage: summary.dailyAverage,
    elapsedDays: summary.elapsedDays,
    periodDays: summary.range.dayCount,
    topCategories: [
      for (final c in summary.categories.take(5))
        (name: c.name, total: c.total, share: c.share),
    ],
    insights: insights,
  );

  /// Amounts are given in major units here, unlike everywhere else in the
  /// app. The model is writing prose for a person, and "1240" would be read
  /// as one thousand two hundred and forty.
  Map<String, Object?> toJson() => {
    'period': '${period.start.iso} to ${period.end.iso}',
    'currency': currency,
    'days_elapsed': elapsedDays,
    'days_in_period': periodDays,
    'spent': spent.major,
    // Named with its actual dates. Left as a bare
    // "spent_same_days_last_period" the model confidently described the
    // previous *month* as "last year's same period".
    'comparison': {
      'what': 'the immediately preceding period, same number of elapsed days',
      'dates': '${comparisonPeriod.start.iso} to ${comparisonPeriod.end.iso}',
      'spent': previousSpent.major,
    },
    'projected_period_total': projected.major,
    'daily_average': dailyAverage.major,
    'top_categories': [
      for (final c in topCategories)
        {
          'name': c.name,
          'amount': c.total.major,
          'share_percent': (c.share * 100).round(),
        },
    ],
    'observations': [
      for (final i in insights)
        {
          'rule': i.rule,
          'severity': i.severity.name,
          'summary': i.title,
          'facts': _majorUnits(i.facts),
        },
    ],
  };

  /// Rewrites minor-unit fact keys into major units.
  ///
  /// The rules record amounts in cents like the rest of the app, but a model
  /// handed `increase_minor: 10466` has no way to know the unit — it wrote
  /// "an increase in minor expenses of €10466", echoing the key name and
  /// inflating the figure a hundredfold. Stripping the suffix and dividing
  /// removes the ambiguity entirely rather than hoping the prompt covers it.
  static Map<String, Object?> _majorUnits(Map<String, Object?> facts) {
    const suffix = '_minor';
    return {
      for (final e in facts.entries)
        if (e.key.endsWith(suffix) && e.value is int)
          e.key.substring(0, e.key.length - suffix.length):
              (e.value as int) / 100
        else
          e.key: e.value,
    };
  }
}
