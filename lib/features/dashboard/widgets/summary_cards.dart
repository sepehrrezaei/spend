import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../domain/analytics/period_summary.dart';

/// The headline figures for the selected period.
class SummaryCards extends ConsumerWidget {
  final PeriodSummary summary;

  const SummaryCards({required this.summary, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyFormatterProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Two columns when the window is narrow, four when there is room.
        final columns = constraints.maxWidth < 620 ? 2 : 4;
        const spacing = 12.0;
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;

        // A fixed height rather than an aspect ratio. Aspect ratios couple
        // card height to window width, so narrowing the window silently
        // clipped the captions — three lines of text need the space they need
        // regardless of how wide the card is.
        final cards = <Widget>[
          _Card(
            label: 'Spent',
            value: money.format(summary.expenseTotal),
            caption:
                '${summary.transactionCount} '
                '${summary.transactionCount == 1 ? "entry" : "entries"}',
          ),
          _DeltaCard(summary: summary),
          _Card(
            label: 'Daily average',
            value: money.format(summary.dailyAverage),
            caption:
                'over ${summary.elapsedDays} '
                '${summary.elapsedDays == 1 ? "day" : "days"}',
          ),
          _Card(
            label: summary.isPartial ? 'On pace for' : 'Period total',
            value: money.format(summary.projectedTotal),
            caption: summary.isPartial
                ? 'if this rate holds'
                : 'period complete',
            // Projection is an extrapolation, not a fact. Muting it keeps
            // it from reading with the same authority as money actually
            // spent.
            muted: summary.isPartial,
          ),
        ];

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final card in cards)
              SizedBox(width: itemWidth, height: 96, child: card),
          ],
        );
      },
    );
  }
}

/// Period-over-period change.
///
/// Split into its own card because it is the only figure whose colour carries
/// meaning, and because "no comparison available" is a real state that must
/// not render as a misleading 0%.
class _DeltaCard extends ConsumerWidget {
  final PeriodSummary summary;

  const _DeltaCard({required this.summary});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyFormatterProvider);
    final scheme = Theme.of(context).colorScheme;
    final fraction = summary.deltaFraction;

    if (fraction == null) {
      return const _Card(
        label: 'vs previous',
        value: '—',
        caption: 'nothing to compare',
      );
    }

    final up = summary.delta.isPositive;
    final percent = (fraction.abs() * 100);
    return _Card(
      label: 'vs previous',
      value:
          '${up ? "+" : "−"}${percent.toStringAsFixed(percent < 10 ? 1 : 0)}%',
      caption:
          '${money.formatSigned(summary.delta)}'
          '${summary.isPartial ? " · same days" : ""}',
      valueColor: summary.delta.isZero
          ? null
          : (up ? scheme.increase : scheme.decrease),
    );
  }
}

class _Card extends StatelessWidget {
  final String label;
  final String value;
  final String caption;
  final Color? valueColor;
  final bool muted;

  const _Card({
    required this.label,
    required this.value,
    required this.caption,
    this.valueColor,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 0.7,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color:
                      valueColor ??
                      (muted ? theme.colorScheme.onSurfaceVariant : null),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
