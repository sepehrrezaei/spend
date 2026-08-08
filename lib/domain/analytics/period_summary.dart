/// The computed result of analysing a period.
///
/// Every field here is derived arithmetic over [SpendRecord]s — no estimates,
/// no model output. This is also exactly what gets handed to the language
/// model as context, which is why it stays plain data.
library;

import 'package:meta/meta.dart';

import '../../core/date_range.dart';
import '../../core/day.dart';
import '../../core/money.dart';
import '../entities/spend_record.dart';

/// One category's share of a period.
@immutable
class CategorySlice {
  final int categoryId;
  final String name;
  final String icon;
  final int color;
  final Money total;
  final int count;

  /// This category's fraction of the period's expense total, 0.0 to 1.0.
  final double share;

  /// The same category's total in the comparison period.
  final Money previousTotal;

  const CategorySlice({
    required this.categoryId,
    required this.name,
    required this.icon,
    required this.color,
    required this.total,
    required this.count,
    required this.share,
    required this.previousTotal,
  });

  Money get delta => total - previousTotal;

  /// Proportional change against the comparison period.
  ///
  /// Null when the previous total was zero: there is no meaningful percentage
  /// increase from nothing, and rendering "+∞%" or "+100%" would both be lies.
  /// The UI shows "new" instead.
  double? get deltaFraction =>
      previousTotal.isZero ? null : delta.minor / previousTotal.minor.abs();

  bool get isNew => previousTotal.isZero && total.isPositive;
}

/// One day's spending, including days with none.
@immutable
class DailyPoint {
  final Day day;
  final Money total;
  final int count;

  const DailyPoint({
    required this.day,
    required this.total,
    required this.count,
  });

  bool get isNoSpend => total.isZero;
}

@immutable
class MerchantTotal {
  final String merchant;
  final Money total;
  final int count;

  const MerchantTotal({
    required this.merchant,
    required this.total,
    required this.count,
  });
}

/// Everything the dashboard and the insight rules need about one period.
@immutable
class PeriodSummary {
  final DateRange range;

  /// The last day with data to report on: today when the period is still
  /// running, otherwise the period's end.
  final Day asOf;

  /// Days of the period that have actually happened. The distinction from
  /// `range.dayCount` is what keeps a daily average honest on the 3rd of the
  /// month — dividing by 31 there would understate spending tenfold.
  final int elapsedDays;

  final Money expenseTotal;
  final Money incomeTotal;
  final int transactionCount;

  /// The comparison period's expense total, for period-over-period change.
  /// Already truncated to the same elapsed length as this period.
  final Money previousExpenseTotal;

  final List<CategorySlice> categories;

  /// Every day in the range, ascending, zero-filled. Charts need the gaps
  /// present or a quiet week silently compresses the x-axis.
  final List<DailyPoint> daily;

  /// The same series with recurring fixed costs removed.
  ///
  /// Rent lands once and is roughly twenty times a normal day's spending. On
  /// a shared axis it flattens every other bar to nothing and yanks the
  /// average line off the top of the chart, so the day-to-day view — the part
  /// you can actually act on — plots this instead.
  final List<DailyPoint> dailyDiscretionary;

  /// Spending attributable to recurring rules, and everything else.
  final Money fixedTotal;
  final Money discretionaryTotal;

  final Money weekendTotal;
  final Money weekdayTotal;

  final List<MerchantTotal> topMerchants;
  final SpendRecord? largest;

  const PeriodSummary({
    required this.range,
    required this.asOf,
    required this.elapsedDays,
    required this.expenseTotal,
    required this.incomeTotal,
    required this.transactionCount,
    required this.previousExpenseTotal,
    required this.categories,
    required this.daily,
    required this.dailyDiscretionary,
    required this.fixedTotal,
    required this.discretionaryTotal,
    required this.weekendTotal,
    required this.weekdayTotal,
    required this.topMerchants,
    required this.largest,
  });

  bool get isEmpty => transactionCount == 0;

  /// Whether the period is still running, which is what makes projection
  /// meaningful and makes a raw comparison against a complete previous period
  /// misleading.
  bool get isPartial => elapsedDays < range.dayCount;

  Money get net => incomeTotal - expenseTotal;

  /// Average spend per elapsed day.
  Money get dailyAverage => expenseTotal.dividedBy(elapsedDays);

  /// Where the period lands if the current daily rate holds.
  ///
  /// For a completed period this is just the actual total.
  Money get projectedTotal =>
      isPartial ? dailyAverage * range.dayCount : expenseTotal;

  /// Proportional change against the comparison period, or null when there is
  /// nothing to compare against.
  double? get deltaFraction => previousExpenseTotal.isZero
      ? null
      : (expenseTotal - previousExpenseTotal).minor /
            previousExpenseTotal.minor.abs();

  Money get delta => expenseTotal - previousExpenseTotal;

  /// Elapsed days on which nothing was spent.
  int get noSpendDays =>
      daily.where((d) => d.day <= asOf && d.isNoSpend).length;

  /// The longest run of consecutive no-spend days within the elapsed period.
  int get longestNoSpendStreak {
    var best = 0;
    var run = 0;
    for (final d in daily) {
      if (d.day > asOf) break;
      run = d.isNoSpend ? run + 1 : 0;
      if (run > best) best = run;
    }
    return best;
  }

  /// The no-spend streak still running as of [asOf].
  int get currentNoSpendStreak {
    var run = 0;
    for (final d in daily) {
      if (d.day > asOf) break;
      run = d.isNoSpend ? run + 1 : 0;
    }
    return run;
  }

  /// A centred-trailing moving average over [window] days.
  ///
  /// Trailing rather than centred so each point uses only data that existed by
  /// that date — a centred average would let future spending bend the line
  /// backwards, which reads as prediction rather than history.
  List<Money> movingAverage(int window) => movingAverageOf(daily, window);

  /// As [movingAverage], over an arbitrary daily series.
  static List<Money> movingAverageOf(List<DailyPoint> series, int window) {
    if (window < 1) return [for (final d in series) d.total];
    return [
      for (var i = 0; i < series.length; i++)
        () {
          final from = (i - window + 1).clamp(0, series.length);
          final slice = series.sublist(from, i + 1);
          return slice.map((d) => d.total).sum().dividedBy(slice.length);
        }(),
    ];
  }

  /// The busiest weekday, as an ISO weekday number, or null when empty.
  int? get heaviestWeekday {
    if (daily.isEmpty) return null;
    final byWeekday = <int, Money>{};
    for (final d in daily) {
      byWeekday[d.day.weekday] =
          (byWeekday[d.day.weekday] ?? Money.zero) + d.total;
    }
    final entries = byWeekday.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.first.value.isZero ? null : entries.first.key;
  }
}
