import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/category_icons.dart';
import '../../core/day.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../data/db/database.dart';
import '../../domain/entities/enums.dart';

/// Fixed monthly commitments.
///
/// Kept alongside budgets because both answer forward-looking questions. This
/// one establishes the floor under your spending: money already committed
/// before any discretionary decision gets made.
class RecurringSection extends ConsumerWidget {
  const RecurringSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rulesAsync = ref.watch(activeRecurringProvider);
    final money = ref.watch(moneyFormatterProvider);
    final theme = Theme.of(context);
    final commitment = ref.watch(monthlyCommitmentProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Recurring', style: theme.textTheme.titleSmall),
            const Spacer(),
            if (!commitment.isZero)
              Text(
                '${money.format(commitment)} a month',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              tooltip: 'Add a recurring cost',
              onPressed: () => showRecurringEditor(context),
            ),
          ],
        ),
        const SizedBox(height: 4),
        rulesAsync.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('Could not load recurring costs: $e'),
          data: (rules) => rules.isEmpty
              ? Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 20,
                    ),
                    child: Text(
                      'Nothing recurring yet. Adding rent and subscriptions '
                      'here separates your fixed floor from the spending you '
                      'actually decide on each week.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : Card(
                  child: Column(
                    children: [
                      for (final (i, r) in rules.indexed) ...[
                        if (i > 0) const Divider(height: 1),
                        _RecurringTile(rule: r),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

class _RecurringTile extends ConsumerWidget {
  final RecurringRule rule;

  const _RecurringTile({required this.rule});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyFormatterProvider);
    final theme = Theme.of(context);
    final categories = ref.watch(allCategoriesProvider).value ?? const [];
    final category = categories
        .where((c) => c.id == rule.categoryId)
        .cast<Category?>()
        .firstWhere((c) => true, orElse: () => null);

    final today = Day.today();
    final daysUntil = today.daysUntil(rule.nextDueOn);
    final overdue = daysUntil < 0;
    final dueToday = daysUntil == 0;

    return ListTile(
      dense: true,
      leading: Icon(
        iconFor(category?.iconName ?? 'tag'),
        size: 18,
        color: Color(category?.colorValue ?? 0xFF78909C),
      ),
      title: Text(rule.label),
      subtitle: Text(
        '${rule.cadence.label} · '
        '${overdue
            ? "overdue by ${-daysUntil} ${-daysUntil == 1 ? "day" : "days"}"
            : dueToday
            ? "due today"
            : "next ${rule.nextDueOn.iso}"}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: overdue || dueToday
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            money.format(rule.amountMinor),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 6),
          if (overdue || dueToday)
            TextButton(
              onPressed: () =>
                  ref.read(recurringRepositoryProvider).markPaid(rule),
              child: const Text('Log it'),
            )
          else
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 16),
              tooltip: 'Edit',
              onPressed: () => showRecurringEditor(context, existing: rule),
            ),
        ],
      ),
    );
  }
}

Future<void> showRecurringEditor(
  BuildContext context, {
  RecurringRule? existing,
}) => showDialog<void>(
  context: context,
  builder: (_) => _RecurringEditorDialog(existing: existing),
);

class _RecurringEditorDialog extends ConsumerStatefulWidget {
  final RecurringRule? existing;

  const _RecurringEditorDialog({this.existing});

  @override
  ConsumerState<_RecurringEditorDialog> createState() =>
      _RecurringEditorDialogState();
}

class _RecurringEditorDialogState
    extends ConsumerState<_RecurringEditorDialog> {
  late final TextEditingController _label;
  late final TextEditingController _amount;
  late int? _categoryId;
  late Cadence _cadence;
  late Day _nextDue;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _label = TextEditingController(text: e?.label ?? '');
    _amount = TextEditingController(
      text: e == null ? '' : e.amountMinor.toString(),
    );
    _categoryId = e?.categoryId;
    _cadence = e?.cadence ?? Cadence.monthly;
    _nextDue = e?.nextDueOn ?? Day.today().firstOfMonth.addMonths(1);
  }

  @override
  void dispose() {
    _label.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = Money.tryParse(_amount.text);
    if (_label.text.trim().isEmpty) {
      setState(() => _error = 'Give it a name');
      return;
    }
    if (amount == null || amount.isZero) {
      setState(() => _error = 'Enter an amount');
      return;
    }
    if (_categoryId == null) {
      setState(() => _error = 'Pick a category');
      return;
    }

    final repo = ref.read(recurringRepositoryProvider);
    if (widget.existing == null) {
      await repo.add(
        label: _label.text,
        amount: amount,
        categoryId: _categoryId!,
        cadence: _cadence,
        nextDueOn: _nextDue,
      );
    } else {
      await repo.update(
        id: widget.existing!.id,
        label: _label.text,
        amount: amount,
        categoryId: _categoryId,
        cadence: _cadence,
        nextDueOn: _nextDue,
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final categories = (ref.watch(activeCategoriesProvider).value ?? const [])
        .where((c) => c.kind == CategoryKind.expense)
        .toList();
    final money = ref.watch(moneyFormatterProvider);

    return AlertDialog(
      title: Text(
        widget.existing == null
            ? 'Add a recurring cost'
            : 'Edit recurring cost',
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _label,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Rent, Spotify, gym',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Amount',
                  prefixText: '${money.symbol} ',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _categoryId,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final c in categories)
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() => _categoryId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<Cadence>(
                initialValue: _cadence,
                decoration: const InputDecoration(labelText: 'Repeats'),
                items: [
                  for (final c in Cadence.values)
                    DropdownMenuItem(value: c, child: Text(c.label)),
                ],
                onChanged: (v) => setState(() => _cadence = v ?? _cadence),
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(labelText: 'Next due'),
                child: Row(
                  children: [
                    Text(_nextDue.iso),
                    const Spacer(),
                    TextButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _nextDue.toLocalDateTime(),
                          firstDate: DateTime(2000),
                          lastDate: DateTime.now().add(
                            const Duration(days: 365 * 3),
                          ),
                        );
                        if (picked != null) {
                          setState(() => _nextDue = Day.fromDateTime(picked));
                        }
                      },
                      child: const Text('Change'),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(
            onPressed: () async {
              await ref
                  .read(recurringRepositoryProvider)
                  .delete(widget.existing!.id);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: Text(
              'Delete',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
