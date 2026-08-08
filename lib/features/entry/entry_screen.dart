import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/category_icons.dart';
import '../../core/day.dart';
import '../../core/money.dart';
import '../../core/platform.dart';
import '../../core/providers.dart';
import '../../data/db/database.dart';

/// Logging a spend.
///
/// Optimised for the case that actually matters: entering an amount and a
/// category in a couple of seconds, repeatedly. The amount field holds focus
/// throughout, Enter commits, and after saving the form keeps the category and
/// date but clears the amount — because the next entry is usually the same
/// kind of thing on the same day.
class EntryScreen extends ConsumerStatefulWidget {
  const EntryScreen({super.key});

  @override
  ConsumerState<EntryScreen> createState() => _EntryScreenState();
}

class _EntryScreenState extends ConsumerState<EntryScreen> {
  final _amountController = TextEditingController();
  final _merchantController = TextEditingController();
  final _noteController = TextEditingController();
  final _amountFocus = FocusNode();

  int? _categoryId;
  Day _date = Day.today();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _amountController.dispose();
    _merchantController.dispose();
    _noteController.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;

    final amount = Money.tryParse(_amountController.text);
    if (amount == null || amount.isZero) {
      setState(() => _error = 'Enter an amount');
      _amountFocus.requestFocus();
      return;
    }
    if (_categoryId == null) {
      setState(() => _error = 'Pick a category');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final repo = ref.read(transactionRepositoryProvider);
    final id = await repo.add(
      amount: amount,
      categoryId: _categoryId!,
      occurredOn: _date,
      merchant: _merchantController.text.trim(),
      note: _noteController.text.trim(),
    );

    if (!mounted) return;

    final formatter = ref.read(moneyFormatterProvider);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('Added ${formatter.format(amount)}'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => repo.delete(id),
          ),
        ),
      );

    // Category and date persist: the next entry is usually similar, and
    // re-picking them every time is the friction that kills daily logging.
    setState(() {
      _saving = false;
      _amountController.clear();
      _merchantController.clear();
      _noteController.clear();
    });
    _amountFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(activeCategoriesProvider);
    final formatter = ref.watch(moneyFormatterProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Add spend'), centerTitle: false),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: FocusTraversalGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _AmountField(
                    controller: _amountController,
                    focusNode: _amountFocus,
                    symbol: formatter.symbol,
                    onSubmitted: (_) => _save(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  _FieldLabel('Category'),
                  const SizedBox(height: 8),
                  categoriesAsync.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text('Could not load categories: $e'),
                    data: (categories) => _CategoryPicker(
                      categories: categories,
                      selectedId: _categoryId,
                      onSelected: (id) {
                        setState(() {
                          _categoryId = id;
                          _error = null;
                        });
                        // Return focus to the amount so Enter still commits
                        // after picking a category with the mouse.
                        _amountFocus.requestFocus();
                      },
                    ),
                  ),
                  const SizedBox(height: 24),
                  _FieldLabel('Date'),
                  const SizedBox(height: 8),
                  _DatePicker(
                    value: _date,
                    onChanged: (d) => setState(() => _date = d),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _merchantController,
                          decoration: const InputDecoration(
                            labelText: 'Where (optional)',
                            hintText: 'Albert Heijn',
                          ),
                          textInputAction: TextInputAction.next,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _noteController,
                          decoration: const InputDecoration(
                            labelText: 'Note (optional)',
                          ),
                          onSubmitted: (_) => _save(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.check),
                    label: Text(
                      _saving
                          ? 'Saving…'
                          // The return-key hint is meaningless on a touch
                          // keyboard.
                          : AppPlatform.hasKeyboardShortcuts
                          ? 'Save  ⏎'
                          : 'Save',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AmountField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String symbol;
  final ValueChanged<String> onSubmitted;

  const _AmountField({
    required this.controller,
    required this.focusNode,
    required this.symbol,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: true,
      textAlign: TextAlign.center,
      style: theme.textTheme.displaySmall?.copyWith(
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      // Permissive on purpose: both separators are accepted so the field
      // works the same whether the keyboard produces "." or ",".
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]')),
      ],
      decoration: InputDecoration(
        hintText: '0${_decimalSeparator}00',
        prefixText: '$symbol ',
        prefixStyle: theme.textTheme.headlineSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 20),
      ),
      onSubmitted: onSubmitted,
    );
  }

  static String get _decimalSeparator => ',';
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        letterSpacing: 0.8,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _CategoryPicker extends StatelessWidget {
  final List<Category> categories;
  final int? selectedId;
  final ValueChanged<int> onSelected;

  const _CategoryPicker({
    required this.categories,
    required this.selectedId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) {
      return const Text('No categories yet — add one in Settings.');
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in categories)
          _CategoryChip(
            category: c,
            selected: c.id == selectedId,
            onTap: () => onSelected(c.id),
          ),
      ],
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final Category category;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = Color(category.colorValue);
    return FilterChip(
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      avatar: Icon(
        iconFor(category.iconName),
        size: 18,
        color: selected ? color : color.withValues(alpha: 0.85),
      ),
      label: Text(category.name),
      selectedColor: color.withValues(alpha: 0.18),
      side: BorderSide(
        color: selected ? color : Theme.of(context).colorScheme.outlineVariant,
        width: selected ? 1.5 : 1,
      ),
    );
  }
}

class _DatePicker extends StatelessWidget {
  final Day value;
  final ValueChanged<Day> onChanged;

  const _DatePicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final today = Day.today();
    final yesterday = today.addDays(-1);
    final isOther = value != today && value != yesterday;

    return Row(
      children: [
        ChoiceChip(
          label: const Text('Today'),
          selected: value == today,
          onSelected: (_) => onChanged(today),
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          label: const Text('Yesterday'),
          selected: value == yesterday,
          onSelected: (_) => onChanged(yesterday),
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          avatar: const Icon(Icons.calendar_today, size: 15),
          label: Text(isOther ? value.iso : 'Pick…'),
          selected: isOther,
          onSelected: (_) async {
            final picked = await showDatePicker(
              context: context,
              initialDate: value.toLocalDateTime(),
              firstDate: DateTime(2000),
              lastDate: DateTime.now().add(const Duration(days: 365)),
            );
            if (picked != null) onChanged(Day.fromDateTime(picked));
          },
        ),
      ],
    );
  }
}
