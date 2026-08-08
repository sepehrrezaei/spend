/// Application-wide dependency injection.
///
/// Everything hangs off [databaseProvider], so a test can override that single
/// provider with an in-memory database and get the whole app wired to it.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/backup/auto_backup.dart';
import '../data/backup/backup_service.dart';
import '../data/csv/csv_service.dart';
import '../data/db/database.dart';
import '../data/repositories/category_repository.dart';
import '../data/repositories/budget_repository.dart';
import '../data/repositories/recurring_repository.dart';
import '../data/repositories/transaction_repository.dart';
import '../domain/analytics/analytics_engine.dart';
import '../domain/analytics/budget_status.dart';
import '../domain/analytics/period_summary.dart';
import '../domain/entities/budget_definition.dart';
import '../domain/entities/spend_record.dart';
import 'date_range.dart';
import 'day.dart';
import 'money.dart';
import 'money_format.dart';

/// Setting keys. Constants rather than bare strings so a typo is a compile
/// error instead of a silently missing preference.
abstract final class SettingKeys {
  static const currency = 'currency';
  static const themeMode = 'theme_mode';
  static const weekStartsOn = 'week_starts_on';
  static const ollamaEnabled = 'ollama_enabled';
  static const ollamaModel = 'ollama_model';
  static const ollamaHost = 'ollama_host';
}

final databaseProvider = Provider<SpendDatabase>((ref) {
  final db = SpendDatabase();
  ref.onDispose(db.close);
  return db;
});

final transactionRepositoryProvider = Provider<TransactionRepository>(
  (ref) => TransactionRepository(ref.watch(databaseProvider)),
);

final categoryRepositoryProvider = Provider<CategoryRepository>(
  (ref) => CategoryRepository(ref.watch(databaseProvider)),
);

// ------------------------------------------------------------------ settings

/// A single setting as a stream, falling back to [fallback] when unset.
StreamProvider<String> settingProvider(String key, String fallback) =>
    StreamProvider<String>(
      (ref) => ref
          .watch(databaseProvider)
          .watchSetting(key)
          .map((v) => v ?? fallback),
    );

final currencyProvider = settingProvider(SettingKeys.currency, 'EUR');
final themeModeSettingProvider = settingProvider(
  SettingKeys.themeMode,
  'system',
);
final weekStartSettingProvider = settingProvider(
  SettingKeys.weekStartsOn,
  '${DateTime.monday}',
);

final themeModeProvider = Provider<ThemeMode>((ref) {
  return switch (ref.watch(themeModeSettingProvider).value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
});

final weekStartsOnProvider = Provider<int>((ref) {
  final raw = ref.watch(weekStartSettingProvider).value;
  return int.tryParse(raw ?? '')?.clamp(1, 7) ?? DateTime.monday;
});

/// Formats money in the configured currency. Rebuilt only when the currency
/// changes, since constructing the underlying [NumberFormat] is not cheap.
final moneyFormatterProvider = Provider<MoneyFormatter>((ref) {
  final code = ref.watch(currencyProvider).value ?? 'EUR';
  return MoneyFormatter(currencyCode: code);
});

final dayFormatterProvider = Provider<DayFormatter>((ref) => DayFormatter());

// ---------------------------------------------------------------- categories

final activeCategoriesProvider = StreamProvider<List<Category>>(
  (ref) => ref.watch(categoryRepositoryProvider).watchActive(),
);

final allCategoriesProvider = StreamProvider<List<Category>>(
  (ref) => ref.watch(categoryRepositoryProvider).watchAll(),
);

/// Active categories ordered by how often they have been used recently.
///
/// Drives the quick-capture panel, where only a handful fit. Alphabetical or
/// manual order would bury the two or three categories that account for most
/// entries, which is exactly what makes fast logging slow.
final frequentCategoriesProvider = Provider<List<Category>>((ref) {
  final categories = ref.watch(activeCategoriesProvider).value ?? const [];
  final recent = ref.watch(recentTransactionsProvider).value ?? const [];

  final uses = <int, int>{};
  for (final r in recent) {
    uses[r.categoryId] = (uses[r.categoryId] ?? 0) + 1;
  }

  final sorted = [...categories]
    ..sort((a, b) {
      final byUse = (uses[b.id] ?? 0).compareTo(uses[a.id] ?? 0);
      if (byUse != 0) return byUse;
      return a.sortOrder.compareTo(b.sortOrder);
    });
  return sorted;
});

/// Whether the window is currently acting as a compact capture panel.
final quickAddModeProvider = NotifierProvider<QuickAddMode, bool>(
  QuickAddMode.new,
);

class QuickAddMode extends Notifier<bool> {
  @override
  bool build() => false;

  void enter() => state = true;
  void exit() => state = false;
}

// -------------------------------------------------------------------- period

/// The reporting window the dashboard is showing.
@immutable
class PeriodSelection {
  final PeriodType type;

  /// Any day inside the period. Kept rather than just the resolved range so
  /// stepping forward and back stays on calendar boundaries instead of
  /// accumulating drift.
  final Day anchor;

  /// Only used when [type] is [PeriodType.custom].
  final DateRange? customRange;

  const PeriodSelection({
    required this.type,
    required this.anchor,
    this.customRange,
  });

  DateRange resolve(int weekStartsOn) =>
      type == PeriodType.custom && customRange != null
      ? customRange!
      : DateRange.forPeriod(type, anchor: anchor, weekStartsOn: weekStartsOn);
}

class PeriodNotifier extends Notifier<PeriodSelection> {
  @override
  PeriodSelection build() =>
      PeriodSelection(type: PeriodType.month, anchor: Day.today());

  void setType(PeriodType type) =>
      state = PeriodSelection(type: type, anchor: Day.today());

  void setCustom(DateRange range) => state = PeriodSelection(
    type: PeriodType.custom,
    anchor: range.start,
    customRange: range,
  );

  /// Steps one whole period backwards or forwards.
  ///
  /// Moves the anchor by calendar units rather than by day count, so stepping
  /// through months never lands mid-month on a 31-day boundary.
  void step(int direction) {
    final s = state;
    final anchor = switch (s.type) {
      PeriodType.day => s.anchor.addDays(direction),
      PeriodType.week => s.anchor.addDays(7 * direction),
      PeriodType.month => s.anchor.firstOfMonth.addMonths(direction),
      PeriodType.quarter => s.anchor.firstOfMonth.addMonths(3 * direction),
      PeriodType.year => s.anchor.addYears(direction),
      PeriodType.custom => s.anchor,
    };
    if (s.type == PeriodType.custom) {
      final r = s.customRange;
      if (r == null) return;
      final shift = r.dayCount * direction;
      state = PeriodSelection(
        type: PeriodType.custom,
        anchor: r.start.addDays(shift),
        customRange: DateRange(r.start.addDays(shift), r.end.addDays(shift)),
      );
      return;
    }
    state = PeriodSelection(type: s.type, anchor: anchor);
  }

  void jumpToToday() =>
      state = PeriodSelection(type: state.type, anchor: Day.today());
}

final periodProvider = NotifierProvider<PeriodNotifier, PeriodSelection>(
  PeriodNotifier.new,
);

/// The resolved date range currently being reported on.
final currentRangeProvider = Provider<DateRange>((ref) {
  return ref.watch(periodProvider).resolve(ref.watch(weekStartsOnProvider));
});

/// Transactions inside the selected period.
final periodTransactionsProvider = StreamProvider<List<SpendRecord>>((ref) {
  final range = ref.watch(currentRangeProvider);
  return ref.watch(transactionRepositoryProvider).watchInRange(range);
});

/// The most recent entries, independent of the selected period.
final recentTransactionsProvider = StreamProvider<List<SpendRecord>>(
  (ref) => ref.watch(transactionRepositoryProvider).watchRecent(),
);

// ----------------------------------------------------------------- analytics

/// The period immediately before the selected one, for comparison.
final previousRangeProvider = Provider<DateRange>((ref) {
  return ref
      .watch(currentRangeProvider)
      .previous(weekStartsOn: ref.watch(weekStartsOnProvider));
});

final previousTransactionsProvider = StreamProvider<List<SpendRecord>>((ref) {
  final range = ref.watch(previousRangeProvider);
  return ref.watch(transactionRepositoryProvider).watchInRange(range);
});

/// The full analysis of the selected period.
///
/// Recomputed whenever either period's transactions change, so editing a
/// transaction updates every chart at once. The comparison period is passed
/// through rather than pre-reduced, because the engine truncates it to the
/// elapsed length itself.
final periodSummaryProvider = Provider<AsyncValue<PeriodSummary>>((ref) {
  final range = ref.watch(currentRangeProvider);
  final previousRange = ref.watch(previousRangeProvider);
  final previous = ref.watch(previousTransactionsProvider);

  return ref
      .watch(periodTransactionsProvider)
      .whenData(
        (records) => const AnalyticsEngine().summarise(
          records: records,
          range: range,
          // An unresolved comparison period simply means no delta yet, rather
          // than blocking the whole dashboard on a second query.
          previousRecords: previous.value ?? const [],
          previousRange: previousRange,
        ),
      );
});

/// Transactions in an arbitrary range, keyed by that range.
///
/// Separate from [periodTransactionsProvider] because budgets need their own
/// windows — a yearly limit is judged over a year regardless of what the
/// dashboard happens to be showing.
final transactionsInRangeProvider =
    StreamProvider.family<List<SpendRecord>, DateRange>(
      (ref, range) =>
          ref.watch(transactionRepositoryProvider).watchInRange(range),
    );

// ------------------------------------------------------------------- budgets

final budgetRepositoryProvider = Provider<BudgetRepository>(
  (ref) => BudgetRepository(ref.watch(databaseProvider)),
);

final activeBudgetsProvider = StreamProvider<List<BudgetDefinition>>(
  (ref) => ref.watch(budgetRepositoryProvider).watchActive(),
);

/// The widest window any active budget needs, so transactions are fetched once
/// rather than per budget.
final _budgetSpanProvider = Provider<DateRange?>((ref) {
  final budgets = ref.watch(activeBudgetsProvider).value;
  if (budgets == null || budgets.isEmpty) return null;
  return const BudgetEvaluator().spanFor(
    budgets,
    Day.today(),
    weekStartsOn: ref.watch(weekStartsOnProvider),
  );
});

final budgetStatusesProvider = Provider<AsyncValue<List<BudgetStatus>>>((ref) {
  final budgetsAsync = ref.watch(activeBudgetsProvider);
  final span = ref.watch(_budgetSpanProvider);
  final weekStart = ref.watch(weekStartsOnProvider);

  if (span == null) return budgetsAsync.whenData((_) => const <BudgetStatus>[]);

  return ref
      .watch(transactionsInRangeProvider(span))
      .whenData(
        (records) => const BudgetEvaluator().evaluate(
          budgets: budgetsAsync.value ?? const [],
          records: records,
          today: Day.today(),
          weekStartsOn: weekStart,
        ),
      );
});

// ----------------------------------------------------------------- recurring

final recurringRepositoryProvider = Provider<RecurringRepository>(
  (ref) => RecurringRepository(ref.watch(databaseProvider)),
);

final activeRecurringProvider = StreamProvider<List<RecurringRule>>(
  (ref) => ref.watch(recurringRepositoryProvider).watchActive(),
);

/// The normalised monthly cost of every active recurring rule.
final monthlyCommitmentProvider = Provider<Money>((ref) {
  final rules = ref.watch(activeRecurringProvider).value ?? const [];
  return RecurringRepository.monthlyEquivalent(rules);
});

// -------------------------------------------------------------------- backup

/// The running app's version, for stamping into backup manifests.
final appVersionProvider = FutureProvider<String>((ref) async {
  try {
    final info = await PackageInfo.fromPlatform();
    return '${info.version}+${info.buildNumber}';
  } on Object {
    // Not worth failing a backup over; the manifest is informational.
    return 'unknown';
  }
});

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(
    ref.watch(databaseProvider),
    appVersion: ref.watch(appVersionProvider).value ?? 'unknown',
  );
});

final autoBackupProvider = Provider<AutoBackup>(
  (ref) => AutoBackup(ref.watch(backupServiceProvider)),
);

final autoSnapshotsProvider = FutureProvider<List<FileSystemEntity>>(
  (ref) => ref.watch(autoBackupProvider).snapshots(),
);

const csvServiceProvider = CsvService();

/// Rolling monthly totals for the composition chart and trend rules.
final monthlyTotalsProvider = StreamProvider<List<({Day month, Money total})>>((
  ref,
) {
  final end = ref.watch(currentRangeProvider).end;
  final start = end.firstOfMonth.addMonths(-5);
  return ref
      .watch(transactionRepositoryProvider)
      .watchInRange(DateRange(start, end))
      .map(
        (records) => const AnalyticsEngine().monthlyTotals(
          records,
          endMonth: end,
          months: 6,
        ),
      );
});
