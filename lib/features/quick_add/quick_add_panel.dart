import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/category_icons.dart';
import '../../core/day.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import 'desktop_integration.dart';

/// The compact capture panel the global shortcut summons.
///
/// Ruthlessly stripped down: an amount, a category, Enter. No date picker
/// (today is nearly always right), no merchant, no notes. Anything more can be
/// added later from History — the only job here is to record the number before
/// you forget it.
class QuickAddPanel extends ConsumerStatefulWidget {
  const QuickAddPanel({super.key});

  @override
  ConsumerState<QuickAddPanel> createState() => _QuickAddPanelState();
}

class _QuickAddPanelState extends ConsumerState<QuickAddPanel> {
  final _amount = TextEditingController();
  final _focus = FocusNode();
  int? _categoryId;
  bool _saving = false;
  String? _error;

  /// How many category chips fit without the panel growing.
  static const _visibleCategories = 6;

  @override
  void dispose() {
    _amount.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    ref.read(quickAddModeProvider.notifier).exit();
    await WindowModes.hide();
  }

  Future<void> _save() async {
    if (_saving) return;

    final amount = Money.tryParse(_amount.text);
    if (amount == null || amount.isZero) {
      setState(() => _error = 'Enter an amount');
      _focus.requestFocus();
      return;
    }

    final categories = ref.read(frequentCategoriesProvider);
    // Fall back to the most-used category so a bare amount plus Enter still
    // records something. A miscategorised entry is recoverable; a forgotten
    // one is not.
    final categoryId =
        _categoryId ?? (categories.isEmpty ? null : categories.first.id);
    if (categoryId == null) {
      setState(() => _error = 'No categories available');
      return;
    }

    setState(() => _saving = true);
    await ref
        .read(transactionRepositoryProvider)
        .add(amount: amount, categoryId: categoryId, occurredOn: Day.today());

    if (!mounted) return;
    _amount.clear();
    setState(() {
      _saving = false;
      _error = null;
    });
    await _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final money = ref.watch(moneyFormatterProvider);
    final categories = ref
        .watch(frequentCategoriesProvider)
        .take(_visibleCategories)
        .toList();

    final selectedId =
        _categoryId ?? (categories.isEmpty ? null : categories.first.id);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: CallbackShortcuts(
        bindings: {
          // Escape must always get you out. A capture panel you cannot
          // dismiss is worse than no capture panel.
          const SingleActivator(LogicalKeyboardKey.escape): _dismiss,
        },
        // Deliberately no Focus(autofocus: true) wrapper here. It would win
        // the focus race against the amount field, leaving the panel open with
        // nothing focused — so the shortcut would summon it and typing would go
        // nowhere, defeating the entire point. CallbackShortcuts still receives
        // Escape through the focused field's ancestor chain.
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.bolt, size: 15, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    'Quick add',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'esc to close',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _amount,
                focusNode: _focus,
                autofocus: true,
                textAlign: TextAlign.center,
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]')),
                ],
                decoration: InputDecoration(
                  hintText: '0,00',
                  prefixText: '${money.symbol} ',
                  errorText: _error,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: [
                  for (final c in categories)
                    _CompactChip(
                      label: c.name,
                      icon: iconFor(c.iconName),
                      colour: Color(c.colorValue),
                      selected: c.id == selectedId,
                      onTap: () {
                        setState(() => _categoryId = c.id);
                        // Hand focus straight back to the amount field.
                        // Without this, focus sits on the chip and Enter
                        // re-toggles the category instead of saving, which
                        // breaks the type-pick-Enter rhythm the panel exists
                        // for.
                        _focus.requestFocus();
                      },
                    ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Saves to today',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving…' : 'Save  ⏎'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color colour;
  final bool selected;
  final VoidCallback onTap;

  const _CompactChip({
    required this.label,
    required this.icon,
    required this.colour,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? colour.withValues(alpha: 0.18) : null,
          border: Border.all(
            color: selected ? colour : scheme.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: colour),
            const SizedBox(width: 5),
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}
