import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/category_icons.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/db/database.dart';
import '../../domain/analytics/budget_status.dart';
import '../shell/content_width.dart';
import 'budget_editor.dart';
import 'recurring_section.dart';

/// Spending limits and fixed commitments — the two forward-looking views.
class BudgetsScreen extends ConsumerWidget {
  const BudgetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusesAsync = ref.watch(budgetStatusesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Budgets'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Set a budget',
            onPressed: () => showBudgetEditor(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ContentWidth(
        maxWidth: 760,
        child: statusesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Could not load budgets: $e')),
          data: (statuses) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              if (statuses.isEmpty)
                const _NoBudgets()
              else
                for (final s in statuses) ...[
                  _BudgetCard(status: s),
                  const SizedBox(height: 10),
                ],
              const SizedBox(height: 18),
              const RecurringSection(),
            ],
          ),
        ),
      ),
    );
  }
}

class _BudgetCard extends ConsumerWidget {
  final BudgetStatus status;

  const _BudgetCard({required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyFormatterProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final categories = ref.watch(allCategoriesProvider).value ?? const [];

    final Category? category = status.budget.categoryId == null
        ? null
        : categories
              .where((c) => c.id == status.budget.categoryId)
              .cast<Category?>()
              .firstWhere((c) => true, orElse: () => null);

    final name = status.budget.isOverall
        ? 'Everything'
        : category?.name ?? 'Unknown category';
    final colour = status.budget.isOverall
        ? scheme.primary
        : Color(category?.colorValue ?? scheme.primary.toARGB32());

    // Semantic only — never the category's own colour.
    //
    // Category palettes span the full spectrum, including the reds and ambers
    // that mean "over" and "watch" here. Tinting a healthy bar with its
    // category made an orange category at 53% look more alarming than an
    // amber warning at 92%. Identity lives in the icon; the bar means state.
    final barColour = switch (status.health) {
      BudgetHealth.exceeded => scheme.error,
      BudgetHealth.overPace => scheme.error,
      BudgetHealth.watch => scheme.warning,
      BudgetHealth.onTrack => scheme.primary,
    };

    final used = status.usedFraction ?? 0;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showBudgetEditor(
          context,
          categoryId: status.budget.categoryId,
          existing: status.budget,
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    status.budget.isOverall
                        ? Icons.account_balance_wallet_outlined
                        : iconFor(category?.iconName ?? 'tag'),
                    size: 17,
                    color: colour,
                  ),
                  const SizedBox(width: 8),
                  Text(name, style: theme.textTheme.titleSmall),
                  const SizedBox(width: 6),
                  Text(
                    status.budget.period.label.toLowerCase(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${money.format(status.spent)} / ${money.format(status.limit)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Two bars stacked: spending against a faint marker for how far
              // through the period we are. Seeing them side by side is the
              // whole point — a full bar early is very different from a full
              // bar on the last day.
              _PacingBar(
                used: used.clamp(0.0, 1.0),
                elapsed: status.elapsedFraction,
                overflowing: used > 1,
                colour: barColour,
              ),
              const SizedBox(height: 8),
              Text(
                _pacingSentence(status, money),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: status.health.needsAttention
                      ? barColour
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One plain sentence explaining the state, in the terms a person thinks in.
  static String _pacingSentence(BudgetStatus s, dynamic money) {
    final elapsedPct = (s.elapsedFraction * 100).round();
    final usedPct = ((s.usedFraction ?? 0) * 100).round();

    if (s.isExceeded) {
      return 'Over by ${money.format(s.remaining.abs())} '
          'with ${s.daysRemaining} ${s.daysRemaining == 1 ? "day" : "days"} left';
    }
    final base = '$elapsedPct% through the period, $usedPct% of the budget';
    return switch (s.health) {
      BudgetHealth.overPace =>
        '$base — on pace for ${money.format(s.projected)}',
      BudgetHealth.watch => '$base — slightly ahead',
      BudgetHealth.onTrack =>
        s.daysRemaining > 0
            ? '$base · ${money.format(s.allowancePerRemainingDay)} a day left'
            : base,
      BudgetHealth.exceeded => base,
    };
  }
}

/// A progress bar with a tick showing how far through the period we are.
class _PacingBar extends StatelessWidget {
  final double used;
  final double elapsed;
  final bool overflowing;
  final Color colour;

  const _PacingBar({
    required this.used,
    required this.elapsed,
    required this.overflowing,
    required this.colour,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SizedBox(
          height: 10,
          child: Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              FractionallySizedBox(
                widthFactor: used,
                child: Container(
                  decoration: BoxDecoration(
                    color: colour,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
              // The time marker. Positioned rather than a second bar so it
              // reads as a target line, not as more spending.
              Positioned(
                left: (elapsed.clamp(0.0, 1.0) * width - 1).clamp(
                  0.0,
                  width - 2,
                ),
                top: -2,
                child: Container(
                  width: 2,
                  height: 14,
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NoBudgets extends StatelessWidget {
  const _NoBudgets();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        child: Column(
          children: [
            Icon(
              Icons.savings_outlined,
              size: 34,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 10),
            Text('No budgets set', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'A limit turns tracking into something you can act on — it is the '
              'difference between knowing what you spent and knowing whether '
              'that was too much.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () => showBudgetEditor(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Set a budget'),
            ),
          ],
        ),
      ),
    );
  }
}
