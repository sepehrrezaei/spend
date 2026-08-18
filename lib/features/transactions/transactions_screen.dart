import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/category_icons.dart';
import '../../core/day.dart';
import '../../core/money.dart';
import '../../core/platform.dart';
import '../../core/providers.dart';
import '../../domain/entities/spend_record.dart';
import '../shell/content_width.dart';

/// The searchable transaction history.
class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});

  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  Timer? _debounce;

  /// Long enough to swallow a typing burst, short enough not to feel laggy.
  ///
  /// Without it every keystroke builds a fresh uncapped query: typing a
  /// twelve-character merchant name ran twelve full-table scans, each mapping
  /// its whole result set into SpendRecords on the way back.
  static const _debounceDelay = Duration(milliseconds: 250);

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    // An empty box is the unfiltered list rather than a query, so there is
    // nothing to rate-limit and waiting would just feel unresponsive.
    if (value.trim().isEmpty) {
      setState(() => _query = value);
      return;
    }
    _debounce = Timer(_debounceDelay, () {
      if (mounted) setState(() => _query = value);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(transactionRepositoryProvider);
    // The whole ledger, not the capped "recent" list: this screen is the only
    // place older entries can be found, so a limit here would hide them.
    final stream = _query.trim().isEmpty
        ? ref.watch(allTransactionsProvider)
        : ref.watch(_searchProvider(_query));

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        centerTitle: false,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: ContentWidth(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                controller: _searchController,
                onChanged: _onQueryChanged,
                decoration: InputDecoration(
                  hintText: 'Search merchant, note or category',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _debounce?.cancel();
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
      body: stream.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load history: $e')),
        data: (records) {
          if (records.isEmpty) {
            return _EmptyHistory(searching: _query.trim().isNotEmpty);
          }
          return ContentWidth(
            child: _GroupedList(
              records: records,
              onDelete: (record) async {
                await repo.delete(record.id);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(
                    SnackBar(
                      content: Text('Deleted ${record.displayLabel}'),
                      action: SnackBarAction(
                        label: 'Undo',
                        // Reinserts under the original id so the row returns
                        // exactly as it was rather than as a duplicate.
                        onPressed: () => repo.restore(record),
                      ),
                    ),
                  );
              },
            ),
          );
        },
      ),
    );
  }
}

/// Search results for a term.
///
/// `autoDispose` is the load-bearing part. `StreamProvider.family` is *not*
/// auto-dispose by default in Riverpod 3 — `StreamProviderFamily` declares
/// `isAutoDispose = false` — so without this every prefix the user typed keeps
/// a live drift subscription for the lifetime of the app. Typing "Albert"
/// leaves six of them, each re-running its query on every write to
/// transactions or categories.
///
/// That was survivable while `search` was capped at 200 rows. It is not now
/// that the cap is gone, which is why the two changes belong in one commit.
final _searchProvider = StreamProvider.autoDispose
    .family<List<SpendRecord>, String>(
      (ref, term) => ref.watch(transactionRepositoryProvider).search(term),
    );

/// Transactions under sticky per-day headers carrying that day's total.
class _GroupedList extends ConsumerWidget {
  final List<SpendRecord> records;
  final ValueChanged<SpendRecord> onDelete;

  const _GroupedList({required this.records, required this.onDelete});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyFormatterProvider);
    final dates = ref.watch(dayFormatterProvider);

    // Records arrive newest-first, so grouping preserves that order.
    final groups = <Day, List<SpendRecord>>{};
    for (final r in records) {
      groups.putIfAbsent(r.occurredOn, () => []).add(r);
    }
    final days = groups.keys.toList();

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: days.length,
      itemBuilder: (context, i) {
        final day = days[i];
        final items = groups[day]!;
        final total = items.map((r) => r.amount).sum();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DayHeader(
              label: _relativeLabel(day, dates),
              total: money.format(total),
            ),
            for (final r in items)
              _TransactionTile(record: r, onDelete: () => onDelete(r)),
          ],
        );
      },
    );
  }

  static String _relativeLabel(Day day, dynamic dates) {
    final today = Day.today();
    if (day == today) return 'Today';
    if (day == today.addDays(-1)) return 'Yesterday';
    return dates.medium(day.toLocalDateTime()) as String;
  }
}

class _DayHeader extends StatelessWidget {
  final String label;
  final String total;

  const _DayHeader({required this.label, required this.total});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            total,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _TransactionTile extends ConsumerWidget {
  final SpendRecord record;
  final VoidCallback onDelete;

  const _TransactionTile({required this.record, required this.onDelete});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final money = ref.watch(moneyFormatterProvider);
    final color = Color(record.categoryColor);

    return ListTile(
      leading: CircleAvatar(
        radius: 17,
        backgroundColor: color.withValues(alpha: 0.16),
        child: Icon(iconFor(record.categoryIcon), size: 18, color: color),
      ),
      title: Text(record.displayLabel),
      subtitle: Row(
        children: [
          Text(record.categoryName, style: theme.textTheme.bodySmall),
          if (record.isRecurring) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.autorenew,
              size: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            money.format(record.amount),
            style: theme.textTheme.titleSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: record.isIncome ? theme.colorScheme.primary : null,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: 'Delete',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  final bool searching;
  const _EmptyHistory({required this.searching});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            searching ? Icons.search_off : Icons.receipt_long_outlined,
            size: 44,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            searching
                ? 'Nothing matches that search'
                : 'No spending logged yet',
            style: theme.textTheme.titleMedium,
          ),
          if (!searching) ...[
            const SizedBox(height: 4),
            Text(
              AppPlatform.hasKeyboardShortcuts
                  ? 'Press ⌘N to add your first entry'
                  : 'Tap Add to log your first entry',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
