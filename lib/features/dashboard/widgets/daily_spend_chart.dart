import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../core/providers.dart';
import '../../../domain/analytics/period_summary.dart';

/// Daily spending as bars, with a trailing average line over the top.
///
/// The bars show what actually happened; the line shows the underlying rate,
/// which is what you can act on. A single big purchase spikes one bar without
/// meaningfully moving the line, and that distinction is the point.
class DailySpendChart extends ConsumerWidget {
  final PeriodSummary summary;

  const DailySpendChart({required this.summary, super.key});

  /// Averaging window. Seven days so the line spans a whole week and is not
  /// dominated by the weekday/weekend rhythm.
  static const _window = 7;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyFormatterProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Day-to-day spending only. Recurring fixed costs land as single spikes
    // twenty times a normal day, which would flatten everything else.
    final daily = summary.dailyDiscretionary;
    if (daily.isEmpty) return const SizedBox.shrink();

    final average = PeriodSummary.movingAverageOf(daily, _window);
    final excludedFixed = !summary.fixedTotal.isZero;

    // Only chart days that have happened. Plotting the rest of the month as
    // zeroes would drag the average line toward the floor and imply a
    // collapse in spending that has not occurred.
    final upTo = daily.indexWhere((d) => d.day > summary.asOf);
    final visibleCount = upTo == -1 ? daily.length : upTo;
    if (visibleCount == 0) return const SizedBox.shrink();

    final maxSpend = daily
        .take(visibleCount)
        .map((d) => d.total.minor)
        .fold(0, (a, b) => a > b ? a : b);
    // A flat zero axis would make fl_chart divide by zero working out labels.
    final maxY = (maxSpend == 0 ? 1000 : maxSpend * 1.18).toDouble();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Daily spending', style: theme.textTheme.titleSmall),
                if (excludedFixed) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message:
                        'Recurring costs like rent land as one large payment '
                        'and would flatten the rest of the chart.',
                    child: Text(
                      'excl. ${money.format(summary.fixedTotal)} recurring',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                _LegendDot(color: scheme.primary, label: 'per day'),
                const SizedBox(width: 12),
                _LegendDot(
                  color: scheme.tertiary,
                  label: '$_window-day average',
                  line: true,
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: Stack(
                children: [
                  BarChart(
                    BarChartData(
                      maxY: maxY,
                      minY: 0,
                      alignment: BarChartAlignment.spaceAround,
                      barTouchData: BarTouchData(
                        touchTooltipData: BarTouchTooltipData(
                          getTooltipColor: (_) => scheme.inverseSurface,
                          getTooltipItem: (group, _, rod, _) {
                            final point = daily[group.x];
                            return BarTooltipItem(
                              '${point.day.iso}\n',
                              theme.textTheme.labelSmall!.copyWith(
                                color: scheme.onInverseSurface,
                              ),
                              children: [
                                TextSpan(
                                  text: money.format(point.total),
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: scheme.onInverseSurface,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(),
                        rightTitles: const AxisTitles(),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 46,
                            getTitlesWidget: (value, meta) {
                              if (value == 0 || value >= maxY) {
                                return const SizedBox.shrink();
                              }
                              return Text(
                                money.formatCompact(Money(value.round())),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              );
                            },
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 22,
                            getTitlesWidget: (value, meta) {
                              final i = value.toInt();
                              if (i < 0 || i >= daily.length) {
                                return const SizedBox.shrink();
                              }
                              final day = daily[i].day;

                              // Day-of-month numbers are meaningless once the
                              // range spans months — "1, 5, 12, 21" repeating
                              // across a year tells you nothing about when.
                              final String? label;
                              if (visibleCount > 62) {
                                label = day.day == 1
                                    ? _monthAbbr[day.month - 1]
                                    : null;
                              } else {
                                final step = (visibleCount / 6).ceil();
                                label = i % step == 0 ? '${day.day}' : null;
                              }
                              if (label == null) return const SizedBox.shrink();

                              return Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  label,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (_) => FlLine(
                          color: scheme.outlineVariant.withValues(alpha: 0.4),
                          strokeWidth: 1,
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      barGroups: [
                        for (var i = 0; i < visibleCount; i++)
                          BarChartGroupData(
                            x: i,
                            barRods: [
                              BarChartRodData(
                                toY: daily[i].total.minor.toDouble(),
                                color: daily[i].day.isWeekend
                                    ? scheme.primary.withValues(alpha: 0.55)
                                    : scheme.primary,
                                width: visibleCount > 45 ? 3 : 7,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  // Overlaid rather than combined, because fl_chart cannot
                  // draw bars and a line in one chart.
                  IgnorePointer(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 46, bottom: 22),
                      child: LineChart(
                        LineChartData(
                          maxY: maxY,
                          minY: 0,
                          minX: 0,
                          maxX: (visibleCount - 1).toDouble(),
                          titlesData: const FlTitlesData(show: false),
                          gridData: const FlGridData(show: false),
                          borderData: FlBorderData(show: false),
                          lineTouchData: const LineTouchData(enabled: false),
                          lineBarsData: [
                            LineChartBarData(
                              spots: [
                                for (var i = 0; i < visibleCount; i++)
                                  FlSpot(
                                    i.toDouble(),
                                    average[i].minor.toDouble(),
                                  ),
                              ],
                              isCurved: true,
                              curveSmoothness: 0.2,
                              color: scheme.tertiary,
                              barWidth: 2,
                              dotData: const FlDotData(show: false),
                            ),
                          ],
                        ),
                      ),
                    ),
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

const _monthAbbr = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  final bool line;

  const _LegendDot({
    required this.color,
    required this.label,
    this.line = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: line ? 12 : 8,
          height: line ? 2 : 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
