import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/category_icons.dart';
import '../../../core/money.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../domain/analytics/period_summary.dart';

/// Where the money went, as a ring plus a ranked list.
///
/// The ring answers "what dominates" at a glance; the list answers "by how
/// much, and is that different from last period". Neither alone is enough, so
/// they share a selection — hovering a slice highlights its row.
class CategoryBreakdown extends ConsumerStatefulWidget {
  final PeriodSummary summary;

  const CategoryBreakdown({required this.summary, super.key});

  @override
  ConsumerState<CategoryBreakdown> createState() => _CategoryBreakdownState();
}

class _CategoryBreakdownState extends ConsumerState<CategoryBreakdown> {
  int? _touchedIndex;

  @override
  Widget build(BuildContext context) {
    final slices = widget.summary.categories;
    final theme = Theme.of(context);

    if (slices.isEmpty) {
      return _EmptyCard(
        icon: Icons.donut_large_outlined,
        message: 'No spending in this period',
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('By category', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final ring = SizedBox(
                  height: 190,
                  child: _Ring(
                    slices: slices,
                    total: widget.summary.expenseTotal,
                    touchedIndex: _touchedIndex,
                    onTouched: (i) => setState(() => _touchedIndex = i),
                  ),
                );
                final list = _RankedList(
                  slices: slices,
                  // With no prior period, every category is trivially "new".
                  // Nine identical badges convey nothing, so drop them all.
                  hasComparison: !widget.summary.previousExpenseTotal.isZero,
                  highlighted: _touchedIndex,
                  onHover: (i) => setState(() => _touchedIndex = i),
                );

                // Side by side when there is room, stacked when there is not.
                if (constraints.maxWidth < 560) {
                  return Column(
                    children: [ring, const SizedBox(height: 16), list],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 210, child: ring),
                    const SizedBox(width: 20),
                    Expanded(child: list),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  final List<CategorySlice> slices;
  final Money total;
  final int? touchedIndex;
  final ValueChanged<int?> onTouched;

  const _Ring({
    required this.slices,
    required this.total,
    required this.touchedIndex,
    required this.onTouched,
  });

  @override
  Widget build(BuildContext context) {
    // Anything under 3% becomes an unreadable sliver and a label that
    // collides with its neighbours, so the tail is folded into one segment.
    const minShare = 0.03;
    final major = slices.where((s) => s.share >= minShare).toList();
    final tail = slices.where((s) => s.share < minShare).toList();
    final tailShare = tail.fold<double>(0, (a, s) => a + s.share);

    final scheme = Theme.of(context).colorScheme;

    return Stack(
      alignment: Alignment.center,
      children: [
        PieChart(
          PieChartData(
            sectionsSpace: 2,
            centerSpaceRadius: 54,
            startDegreeOffset: -90,
            pieTouchData: PieTouchData(
              touchCallback: (event, response) {
                if (!event.isInterestedForInteractions ||
                    response?.touchedSection == null) {
                  onTouched(null);
                  return;
                }
                onTouched(response!.touchedSection!.touchedSectionIndex);
              },
            ),
            sections: [
              for (final (i, s) in major.indexed)
                PieChartSectionData(
                  value: s.share,
                  color: Color(s.color),
                  radius: touchedIndex == i ? 32 : 27,
                  showTitle: false,
                ),
              if (tail.isNotEmpty)
                PieChartSectionData(
                  value: tailShare,
                  color: scheme.outlineVariant,
                  radius: 27,
                  showTitle: false,
                ),
            ],
          ),
        ),
        _RingCentre(total: total, touchedIndex: touchedIndex, major: major),
      ],
    );
  }
}

/// The hole in the middle: the total, or the hovered slice's detail.
class _RingCentre extends ConsumerWidget {
  final Money total;
  final List<CategorySlice> major;
  final int? touchedIndex;

  const _RingCentre({
    required this.total,
    required this.major,
    required this.touchedIndex,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyFormatterProvider);
    final theme = Theme.of(context);
    final touched = touchedIndex != null && touchedIndex! < major.length
        ? major[touchedIndex!]
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          touched == null ? 'Total' : touched.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          money.format(touched?.total ?? total),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (touched != null)
          Text(
            '${(touched.share * 100).toStringAsFixed(0)}%',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class _RankedList extends ConsumerWidget {
  final List<CategorySlice> slices;
  final bool hasComparison;
  final int? highlighted;
  final ValueChanged<int?> onHover;

  const _RankedList({
    required this.slices,
    required this.hasComparison,
    required this.highlighted,
    required this.onHover,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyFormatterProvider);
    final theme = Theme.of(context);

    return Column(
      children: [
        for (final (i, s) in slices.indexed)
          MouseRegion(
            onEnter: (_) => onHover(i),
            onExit: (_) => onHover(null),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
              decoration: BoxDecoration(
                color: highlighted == i
                    ? theme.colorScheme.surfaceContainerHighest
                    : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(iconFor(s.icon), size: 15, color: Color(s.color)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  if (hasComparison) _Delta(slice: s),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 40,
                    child: Text(
                      '${(s.share * 100).toStringAsFixed(0)}%',
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 92,
                    child: Text(
                      money.format(s.total),
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A category's movement against the comparison period.
class _Delta extends StatelessWidget {
  final CategorySlice slice;

  const _Delta({required this.slice});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    if (slice.isNew) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          'new',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSecondaryContainer,
          ),
        ),
      );
    }

    final fraction = slice.deltaFraction;
    if (fraction == null || fraction.abs() < 0.005) {
      return const SizedBox.shrink();
    }

    final up = fraction > 0;
    // Past a tripling, a percentage stops being legible — "+1048%" takes
    // real effort to parse, where "11.5x" does not.
    final label = fraction.abs() >= 2
        ? '${(1 + fraction.abs()).toStringAsFixed(1)}x'
        : '${(fraction.abs() * 100).toStringAsFixed(0)}%';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          up ? Icons.arrow_upward : Icons.arrow_downward,
          size: 11,
          color: up ? scheme.increase : scheme.decrease,
        ),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: up ? scheme.increase : scheme.decrease,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final IconData icon;
  final String message;

  const _EmptyCard({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: SizedBox(
        height: 160,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 30, color: theme.colorScheme.outline),
              const SizedBox(height: 8),
              Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
