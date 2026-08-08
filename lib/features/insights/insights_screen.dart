import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/ai_providers.dart';
import '../../core/platform.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/analytics/insight_rules.dart';
import '../shell/content_width.dart';

/// Observations about your spending, and optionally a narrated summary.
///
/// The cards below are computed arithmetically and are always present. The
/// model, when there is one, only rewrites them — so nothing here depends on
/// it, and the tab degrades to "slightly less prose" rather than to "broken".
class InsightsScreen extends ConsumerWidget {
  const InsightsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insightsAsync = ref.watch(insightsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Insights'), centerTitle: false),
      body: ContentWidth(
        maxWidth: 760,
        child: insightsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Could not work these out: $e')),
          data: (insights) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              // Only where a local model could exist. On a phone or tablet
              // there is nothing to connect to, and a card permanently
              // reading "unavailable" is worse than no card — every figure
              // below is computed in Dart and is unaffected.
              if (AppPlatform.supportsLocalAi) ...[
                const _NarrationCard(),
                const SizedBox(height: 16),
              ],
              if (insights.isEmpty)
                const _NothingToSay()
              else ...[
                Text(
                  'What the numbers say',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                for (final i in insights) ...[
                  _InsightCard(insight: i),
                  const SizedBox(height: 8),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _InsightCard extends StatelessWidget {
  final Insight insight;

  const _InsightCard({required this.insight});

  static IconData _iconFor(String rule) => switch (rule) {
    'budget_exceeded' => Icons.error_outline,
    'budget_over_pace' => Icons.speed,
    'category_unusually_high' => Icons.trending_up,
    'category_unusually_low' => Icons.trending_down,
    'category_growing' => Icons.show_chart,
    'period_ahead' => Icons.fast_forward,
    'period_behind' => Icons.check_circle_outline,
    'fixed_cost_heavy' => Icons.lock_outline,
    'weekend_heavy' => Icons.weekend_outlined,
    'single_large_purchase' => Icons.local_offer_outlined,
    'no_spend_streak' => Icons.emoji_events_outlined,
    'possible_subscription' => Icons.autorenew,
    _ => Icons.insights_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final colour = switch (insight.severity) {
      InsightSeverity.alert => scheme.error,
      InsightSeverity.caution => scheme.warning,
      InsightSeverity.good => scheme.decrease,
      InsightSeverity.info => scheme.onSurfaceVariant,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: colour.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(_iconFor(insight.rule), size: 17, color: colour),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    insight.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    insight.detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
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

/// The optional narrated summary, plus the model's connection state.
class _NarrationCard extends ConsumerWidget {
  const _NarrationCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final availability = ref.watch(aiAvailabilityProvider);
    final narration = ref.watch(narrationProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 16,
                  color: scheme.primary,
                ),
                const SizedBox(width: 7),
                Text('In a sentence', style: theme.textTheme.titleSmall),
                const Spacer(),
                availability.when(
                  loading: () => const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  error: (_, _) => const _Dot(ok: false, label: 'unavailable'),
                  data: (a) => _Dot(
                    ok: a.hasModel,
                    label: a.hasModel
                        ? (a.activeModel ?? 'ready')
                        : 'no local model',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            availability.when(
              loading: () => const SizedBox.shrink(),
              error: (e, _) => _Offline(message: '$e'),
              data: (a) => a.hasModel
                  ? _Narration(state: narration)
                  : _Offline(message: a.reason ?? 'No local model available.'),
            ),
            if (availability.value?.hasModel ?? false) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: narration.isRunning
                        ? null
                        : () => ref.read(narrationProvider.notifier).run(),
                    icon: Icon(
                      narration.hasText ? Icons.refresh : Icons.play_arrow,
                      size: 17,
                    ),
                    label: Text(
                      narration.isRunning
                          ? 'Writing…'
                          : narration.hasText
                          ? 'Write again'
                          : 'Summarise this period',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Runs entirely on your machine. Takes a few seconds.',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Narration extends StatelessWidget {
  final NarrationState state;

  const _Narration({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (state.status == NarrationStatus.failed && !state.hasText) {
      return Text(
        state.error ?? 'The model did not respond.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }

    if (!state.hasText) {
      return Text(
        'Everything below is already computed. This just puts it into a '
        'couple of sentences.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    return Text(
      state.text.trim(),
      style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
    );
  }
}

class _Offline extends StatelessWidget {
  final String message;

  const _Offline({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Nothing is missing from the observations below — they are computed '
          'from your data, not written by a model.',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  final bool ok;
  final String label;

  const _Dot({required this.ok, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = ok ? theme.colorScheme.decrease : theme.colorScheme.outline;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
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

class _NothingToSay extends StatelessWidget {
  const _NothingToSay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 26),
        child: Column(
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 32,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 10),
            Text('Nothing stands out', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'No budget is under pressure and no category is behaving oddly '
              'for this period.',
              textAlign: TextAlign.center,
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
