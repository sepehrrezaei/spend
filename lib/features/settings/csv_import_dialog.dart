import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/day.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../data/csv/csv_service.dart';
import '../../domain/entities/enums.dart';

Future<void> showCsvImportDialog(
  BuildContext context, {
  required CsvTable table,
  required String fileName,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _CsvImportDialog(table: table, fileName: fileName),
);

/// Confirms a CSV import before it touches the database.
///
/// Bank exports vary enough that guessing silently is not acceptable — a
/// mis-detected sign or date column would corrupt months of history in one
/// click. Detection is offered as a starting point, every choice is
/// overridable, and the consequences are stated before the button is live.
class _CsvImportDialog extends ConsumerStatefulWidget {
  final CsvTable table;
  final String fileName;

  const _CsvImportDialog({required this.table, required this.fileName});

  @override
  ConsumerState<_CsvImportDialog> createState() => _CsvImportDialogState();
}

class _CsvImportDialogState extends ConsumerState<_CsvImportDialog> {
  CsvMapping? _mapping;
  int? _fallbackCategoryId;
  bool _skipDuplicates = true;
  bool _importing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _mapping = csvServiceProvider.detectMapping(widget.table);
  }

  CsvParseResult? get _preview => _mapping == null
      ? null
      : csvServiceProvider.interpret(widget.table, _mapping!);

  Future<void> _import() async {
    final mapping = _mapping;
    final preview = _preview;
    if (mapping == null || preview == null || preview.rows.isEmpty) return;
    if (_fallbackCategoryId == null) {
      setState(() => _error = 'Choose a category for imported rows');
      return;
    }

    setState(() {
      _importing = true;
      _error = null;
    });

    final repo = ref.read(transactionRepositoryProvider);
    final categories = ref.read(allCategoriesProvider).value ?? const [];
    final byName = {for (final c in categories) c.name.toLowerCase(): c.id};

    // Existing keys are read once up front rather than queried per row.
    final existing = _skipDuplicates ? await repo.existingKeys() : <String>{};

    final toInsert =
        <
          ({
            Money amount,
            int categoryId,
            Day occurredOn,
            String merchant,
            String note,
          })
        >[];
    var skipped = 0;

    for (final row in preview.rows) {
      // A category name in the file is honoured when it matches one that
      // exists; otherwise everything lands in the chosen fallback so nothing
      // is silently dropped.
      final categoryId =
          byName[row.categoryName?.toLowerCase() ?? ''] ?? _fallbackCategoryId!;

      final key = '${row.date.iso}|${row.amount.minor}|$categoryId';
      if (_skipDuplicates && existing.contains(key)) {
        skipped++;
        continue;
      }
      existing.add(key);

      toInsert.add((
        amount: row.amount,
        categoryId: categoryId,
        occurredOn: row.date,
        merchant: row.description,
        note: '',
      ));
    }

    final added = await repo.addAll(toInsert);

    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Imported $added transactions'
            '${skipped > 0 ? " · $skipped duplicates skipped" : ""}'
            '${preview.rejected.isNotEmpty ? " · ${preview.rejected.length} rows unreadable" : ""}',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final money = ref.watch(moneyFormatterProvider);
    final categories = (ref.watch(activeCategoriesProvider).value ?? const [])
        .where((c) => c.kind == CategoryKind.expense)
        .toList();
    final mapping = _mapping;
    final preview = _preview;

    return AlertDialog(
      title: Text('Import ${widget.fileName}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (mapping == null)
                Text(
                  'The columns in this file could not be recognised — no '
                  'column looks like a date. Nothing has been imported.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                )
              else ...[
                _ColumnPickers(
                  table: widget.table,
                  mapping: mapping,
                  onChanged: (m) => setState(() => _mapping = m),
                ),
                const SizedBox(height: 14),
                _SignSwitch(
                  mapping: mapping,
                  onChanged: (m) => setState(() => _mapping = m),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<int>(
                  initialValue: _fallbackCategoryId,
                  decoration: const InputDecoration(
                    labelText: 'Category for imported rows',
                    helperText:
                        'Used unless the file names a category you already have',
                  ),
                  items: [
                    for (final c in categories)
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: (v) => setState(() {
                    _fallbackCategoryId = v;
                    _error = null;
                  }),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _skipDuplicates,
                  onChanged: (v) => setState(() => _skipDuplicates = v ?? true),
                  title: const Text('Skip rows that already exist'),
                  subtitle: Text(
                    'Matched on date, amount and category',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 8),
                if (preview != null) _Summary(preview: preview, money: money),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _importing || preview == null || preview.rows.isEmpty
              ? null
              : _import,
          child: Text(
            _importing
                ? 'Importing…'
                : 'Import ${preview?.rows.length ?? 0} rows',
          ),
        ),
      ],
    );
  }
}

class _ColumnPickers extends StatelessWidget {
  final CsvTable table;
  final CsvMapping mapping;
  final ValueChanged<CsvMapping> onChanged;

  const _ColumnPickers({
    required this.table,
    required this.mapping,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    String label(int i) {
      final header = table.headers.length > i ? table.headers[i] : '';
      return header.isEmpty ? 'Column ${i + 1}' : header;
    }

    final items = [
      for (var i = 0; i < table.columnCount; i++)
        DropdownMenuItem(value: i, child: Text(label(i))),
    ];

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: mapping.dateColumn,
                decoration: const InputDecoration(labelText: 'Date column'),
                items: items,
                onChanged: (v) => v == null
                    ? null
                    : onChanged(mapping.copyWith(dateColumn: v)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<CsvDateFormat>(
                initialValue: mapping.dateFormat,
                decoration: const InputDecoration(labelText: 'Date format'),
                items: [
                  for (final f in CsvDateFormat.values)
                    DropdownMenuItem(value: f, child: Text(f.label)),
                ],
                onChanged: (v) => v == null
                    ? null
                    : onChanged(mapping.copyWith(dateFormat: v)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: mapping.amountColumn,
                decoration: const InputDecoration(labelText: 'Amount column'),
                items: items,
                onChanged: (v) => v == null
                    ? null
                    : onChanged(mapping.copyWith(amountColumn: v)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: mapping.descriptionColumn,
                decoration: const InputDecoration(
                  labelText: 'Description column',
                ),
                items: items,
                onChanged: (v) => v == null
                    ? null
                    : onChanged(mapping.copyWith(descriptionColumn: v)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SignSwitch extends StatelessWidget {
  final CsvMapping mapping;
  final ValueChanged<CsvMapping> onChanged;

  const _SignSwitch({required this.mapping, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      value: mapping.flipSigns,
      onChanged: (v) => onChanged(mapping.copyWith(flipSigns: v)),
      title: const Text('Flip signs'),
      subtitle: Text(
        'Banks record spending as negative. Leave this on unless the preview '
        'below shows expenses as income.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

/// What will actually happen, stated in figures the user can sanity-check.
class _Summary extends StatelessWidget {
  final CsvParseResult preview;
  final dynamic money;

  const _Summary({required this.preview, required this.money});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final expenses = preview.rows.where((r) => !r.isIncome).length;
    final income = preview.rows.length - expenses;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Preview', style: theme.textTheme.labelMedium),
          const SizedBox(height: 6),
          if (preview.rows.isEmpty)
            Text(
              'No rows could be read with these settings.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            )
          else ...[
            Text(
              '${preview.rows.length} rows · $expenses expenses'
              '${income > 0 ? ", $income income" : ""}',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              '${preview.earliest?.iso} to ${preview.latest?.iso}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            Text(
              'Net total ${money.format(preview.total)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            for (final r in preview.rows.take(3))
              Text(
                '${r.date.iso}  ${money.format(r.amount)}  '
                '${r.description.length > 34 ? "${r.description.substring(0, 34)}…" : r.description}',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
          ],
          if (preview.rejected.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '${preview.rejected.length} rows will be skipped '
              '(${preview.rejected.first.reason.toLowerCase()}, line '
              '${preview.rejected.first.sourceLine}…)',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
        ],
      ),
    );
  }
}
