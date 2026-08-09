import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/providers.dart';
import '../../domain/entities/budget_definition.dart';
import '../../domain/entities/enums.dart';

/// Opens the budget editor for a category, or for overall spending.
Future<void> showBudgetEditor(
  BuildContext context, {
  int? categoryId,
  BudgetDefinition? existing,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _BudgetEditorDialog(initialCategoryId: categoryId, existing: existing),
);

class _BudgetEditorDialog extends ConsumerStatefulWidget {
  final int? initialCategoryId;
  final BudgetDefinition? existing;

  const _BudgetEditorDialog({this.initialCategoryId, this.existing});

  @override
  ConsumerState<_BudgetEditorDialog> createState() =>
      _BudgetEditorDialogState();
}

class _BudgetEditorDialogState extends ConsumerState<_BudgetEditorDialog> {
  late final TextEditingController _amount;
  int? _categoryId;
  BudgetPeriod _period = BudgetPeriod.monthly;
  String? _error;

  /// Sentinel for the "everything" option, since a null category id is itself
  /// meaningful and cannot double as "nothing selected".
  static const _overallValue = -1;

  @override
  void initState() {
    super.initState();
    _categoryId = widget.initialCategoryId ?? widget.existing?.categoryId;
    _period = widget.existing?.period ?? BudgetPeriod.monthly;
    _amount = TextEditingController(
      text: widget.existing == null ? '' : widget.existing!.limit.toString(),
    );
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final limit = Money.tryParse(_amount.text);
    if (limit == null || limit.isNegative) {
      setState(() => _error = 'Enter an amount');
      return;
    }
    final repo = ref.read(budgetRepositoryProvider);
    await repo.setLimit(categoryId: _categoryId, period: _period, limit: limit);

    // setLimit keys on the category, so re-pointing an existing budget at a
    // different one writes a *second* budget and leaves the original in place.
    // Editing "Groceries" into "Dining" has to move the budget, not clone it.
    final existing = widget.existing;
    if (existing != null && existing.categoryId != _categoryId) {
      await repo.delete(existing.id);
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _remove() async {
    final existing = widget.existing;
    if (existing == null) return;
    await ref.read(budgetRepositoryProvider).delete(existing.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(activeCategoriesProvider).value ?? const [];
    final money = ref.watch(moneyFormatterProvider);
    final expenseCategories = categories
        .where((c) => c.kind == CategoryKind.expense)
        .toList();

    return AlertDialog(
      title: Text(widget.existing == null ? 'Set a budget' : 'Edit budget'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<int>(
              initialValue: _categoryId ?? _overallValue,
              decoration: const InputDecoration(labelText: 'Applies to'),
              items: [
                const DropdownMenuItem(
                  value: _overallValue,
                  child: Text('Everything'),
                ),
                for (final c in expenseCategories)
                  DropdownMenuItem(value: c.id, child: Text(c.name)),
              ],
              onChanged: (v) =>
                  setState(() => _categoryId = v == _overallValue ? null : v),
            ),
            const SizedBox(height: 14),
            SegmentedButton<BudgetPeriod>(
              showSelectedIcon: false,
              segments: [
                for (final p in BudgetPeriod.values)
                  ButtonSegment(value: p, label: Text(p.label)),
              ],
              selected: {_period},
              onSelectionChanged: (s) => setState(() => _period = s.first),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Limit',
                prefixText: '${money.symbol} ',
                errorText: _error,
                helperText: 'Leave at zero to remove the limit',
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(
            onPressed: _remove,
            child: Text(
              'Remove',
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
