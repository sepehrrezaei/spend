import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_range.dart';
import '../../core/day.dart';
import '../../core/platform.dart';
import '../../core/providers.dart';
import '../../domain/analytics/period_summary.dart';
import '../shell/content_width.dart';
import 'widgets/category_breakdown.dart';
import 'widgets/daily_spend_chart.dart';
import 'widgets/summary_cards.dart';

/// The overview: what the selected period looks like.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(periodSummaryProvider);

    // The period bar sits at the top of the body rather than in the AppBar's
    // `bottom`.
    //
    // A PreferredSize is given a height rather than measuring its child, so
    // putting a bar there that changes height means computing that height
    // separately from the layout that produces it — two measurements that
    // have to agree, and did not: there was a band of widths where the bar
    // stacked while only the single-row height had been reserved, clipping
    // the title. Here the bar simply takes the height it needs.
    return Scaffold(
      appBar: AppBar(title: const Text('Overview'), centerTitle: false),
      body: Column(
        children: [
          Material(
            color: Theme.of(context).appBarTheme.backgroundColor,
            child: const ContentWidth(
              maxWidth: _PeriodBar.contentMaxWidth,
              child: _PeriodBar(),
            ),
          ),
          Expanded(
            child: summaryAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) =>
                  Center(child: Text('Could not analyse this period: $e')),
              data: (summary) => ContentWidth(
                maxWidth: 1000,
                child: summary.isEmpty
                    ? const _EmptyPeriod()
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                        children: [
                          SummaryCards(summary: summary),
                          const SizedBox(height: 12),
                          DailySpendChart(summary: summary),
                          const SizedBox(height: 12),
                          CategoryBreakdown(summary: summary),
                          const SizedBox(height: 12),
                          _FootNotes(summary: summary),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Period type selector plus back/forward stepping.
class _PeriodBar extends ConsumerWidget {
  const _PeriodBar();

  static const contentMaxWidth = 1000.0;

  /// Width the bar itself needs before the segments and the stepper are put on
  /// one line.
  ///
  /// Deliberately generous: measured, the row wants about 963. The first
  /// attempt at this number was 730, chosen by eye, and overflowed in
  /// production. Stacking early costs one line; guessing low costs a clipped
  /// layout, so the bias belongs on this side.
  ///
  /// The margin above it is thin — [contentMaxWidth] leaves 968 — which is why
  /// the date label in the single-row layout is [Flexible] rather than fixed.
  /// A threshold alone would be one long month name away from wrong again.
  static const wideEnough = 960.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(periodProvider);
    final range = ref.watch(currentRangeProvider);
    final notifier = ref.read(periodProvider.notifier);
    final theme = Theme.of(context);

    // Custom is reachable by picking dates, not by tapping a segment.
    const selectable = [
      PeriodType.day,
      PeriodType.week,
      PeriodType.month,
      PeriodType.quarter,
      PeriodType.year,
    ];

    final periods = SegmentedButton<PeriodType>(
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: [
        for (final p in selectable)
          ButtonSegment(value: p, label: Text(p.label)),
      ],
      selected: {
        selectable.contains(selection.type) ? selection.type : PeriodType.month,
      },
      onSelectionChanged: (s) => notifier.setType(s.first),
    );

    // The date label is the only part of the stepper that can give, and in
    // the single-row layout it has to: the row wants ~963pt against the 968
    // that [contentMaxWidth] leaves, so five points separate "fits" from
    // "clipped" — and "September 2026" is wider than the "August 2026" this
    // was measured against. An ellipsis is a worse label; an overflow is a
    // broken screen.
    //
    // It is only wrapped in Flexible on the Row branch. Flexible is a
    // ParentDataWidget for Flex, and putting one inside the stacked layout's
    // Wrap throws outright.
    final label = ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 150),
      child: Text(
        _rangeLabel(range, selection.type),
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall,
      ),
    );

    final previous = IconButton(
      icon: const Icon(Icons.chevron_left),
      tooltip: 'Previous',
      onPressed: () => notifier.step(-1),
    );

    final next = IconButton(
      icon: const Icon(Icons.chevron_right),
      tooltip: 'Next',
      // Stepping past today would only ever show an empty period.
      onPressed: range.end >= Day.today() ? null : () => notifier.step(1),
    );

    final today = TextButton(
      onPressed: notifier.jumpToToday,
      child: const Text('Today'),
    );

    // Measured here rather than from the window, so the decision is made
    // against the width the bar is actually given. Stacked, neither group can
    // overflow: the segments scroll and the stepper wraps.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= wideEnough) {
            return Row(
              children: [
                periods,
                const Spacer(),
                previous,
                Flexible(child: label),
                next,
                const SizedBox(width: 4),
                today,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: periods,
              ),
              const SizedBox(height: 4),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  previous,
                  label,
                  next,
                  const SizedBox(width: 4),
                  today,
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  static String _rangeLabel(DateRange range, PeriodType type) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return switch (type) {
      PeriodType.day => range.start.iso,
      PeriodType.month =>
        '${months[range.start.month - 1]} ${range.start.year}',
      PeriodType.year => '${range.start.year}',
      PeriodType.quarter =>
        'Q${((range.start.month - 1) ~/ 3) + 1} ${range.start.year}',
      _ => '${range.start.iso} – ${range.end.iso}',
    };
  }
}

/// Secondary observations that do not warrant their own chart.
class _FootNotes extends ConsumerWidget {
  final PeriodSummary summary;

  const _FootNotes({required this.summary});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyFormatterProvider);
    final theme = Theme.of(context);

    final notes = <(IconData, String)>[
      if (!summary.fixedTotal.isZero)
        (
          Icons.autorenew,
          '${money.format(summary.fixedTotal)} of this was recurring — '
              '${money.format(summary.discretionaryTotal)} was discretionary',
        ),
      if (!summary.weekendTotal.isZero)
        (
          Icons.weekend_outlined,
          '${money.format(summary.weekendTotal)} at weekends, '
              '${money.format(summary.weekdayTotal)} on weekdays',
        ),
      if (summary.largest != null)
        (
          Icons.trending_up,
          'Largest single entry: ${money.format(summary.largest!.amount)} '
              'on ${summary.largest!.categoryName.toLowerCase()}',
        ),
      if (summary.noSpendDays > 0)
        (
          Icons.check_circle_outline,
          '${summary.noSpendDays} no-spend '
              '${summary.noSpendDays == 1 ? "day" : "days"}'
              '${summary.longestNoSpendStreak > 1 ? " · longest run ${summary.longestNoSpendStreak}" : ""}',
        ),
      for (final m in summary.topMerchants.take(3))
        (
          Icons.storefront_outlined,
          '${m.merchant}: ${money.format(m.total)} over ${m.count} '
              '${m.count == 1 ? "visit" : "visits"}',
        ),
    ];

    if (notes.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Also worth noting', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            for (final (icon, text) in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      icon,
                      size: 15,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(text, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPeriod extends StatelessWidget {
  const _EmptyPeriod();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.pie_chart_outline,
            size: 44,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            'Nothing recorded in this period',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            AppPlatform.hasKeyboardShortcuts
                ? 'Press ⌘N to log something, or step back to an earlier period.'
                : 'Tap Add to log something, or step back to an earlier period.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
