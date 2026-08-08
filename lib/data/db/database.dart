import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/day.dart';
import '../../core/money.dart';
import '../../domain/entities/enums.dart';
import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [Categories, RecurringRules, Transactions, Budgets, AppSettings],
)
class SpendDatabase extends _$SpendDatabase {
  SpendDatabase([QueryExecutor? executor]) : super(executor ?? _open());

  /// Opens the on-disk database in Application Support.
  ///
  /// drift_flutter defaults to the documents directory, which on macOS is
  /// user-facing space meant for files a person opens and manages themselves.
  /// A database is application state, so it belongs in Application Support —
  /// where it also stays out of iCloud Drive's sync on iOS, which would
  /// otherwise try to sync a live SQLite file.
  static QueryExecutor _open() => driftDatabase(
    name: 'spend',
    native: DriftNativeOptions(
      databaseDirectory: getApplicationSupportDirectory,
    ),
  );

  /// An isolated in-memory database, for tests and for verifying a backup
  /// archive before it is allowed to touch the real file.
  SpendDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _seedDefaultCategories();
    },
    beforeOpen: (details) async {
      // SQLite ships with foreign keys disabled. Without this pragma the
      // RESTRICT and SET NULL actions declared in the schema are inert, and
      // deleting a category would orphan its transactions rather than fail.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Starter categories, so the first launch is usable without setup.
  ///
  /// Everything here is editable and archivable — these are a starting point,
  /// not a fixed taxonomy.
  Future<void> _seedDefaultCategories() async {
    const seeds = <({String name, String icon, int color, CategoryKind kind})>[
      (
        name: 'Groceries',
        icon: 'shopping_cart',
        color: 0xFF4CAF50,
        kind: CategoryKind.expense,
      ),
      (
        name: 'Dining',
        icon: 'restaurant',
        color: 0xFFFF7043,
        kind: CategoryKind.expense,
      ),
      (
        name: 'Transport',
        icon: 'directions_transit',
        color: 0xFF42A5F5,
        kind: CategoryKind.expense,
      ),
      (
        name: 'Rent',
        icon: 'home',
        color: 0xFF7E57C2,
        kind: CategoryKind.expense,
      ),
      (
        name: 'Utilities',
        icon: 'bolt',
        color: 0xFF26A69A,
        kind: CategoryKind.expense,
      ),
      (
        name: 'Subscriptions',
        icon: 'subscriptions',
        color: 0xFFEC407A,
        kind: CategoryKind.expense,
      ),
      (
        name: 'Health',
        icon: 'favorite',
        color: 0xFFEF5350,
        kind: CategoryKind.expense,
      ),
      (
        name: 'Shopping',
        icon: 'shopping_bag',
        color: 0xFFAB47BC,
        kind: CategoryKind.expense,
      ),
      (
        name: 'Entertainment',
        icon: 'movie',
        color: 0xFFFFCA28,
        kind: CategoryKind.expense,
      ),
      (
        name: 'Other',
        icon: 'tag',
        color: 0xFF78909C,
        kind: CategoryKind.expense,
      ),
      (
        name: 'Income',
        icon: 'payments',
        color: 0xFF66BB6A,
        kind: CategoryKind.income,
      ),
    ];

    await batch((b) {
      b.insertAll(categories, [
        for (final (index, s) in seeds.indexed)
          CategoriesCompanion.insert(
            name: s.name,
            iconName: Value(s.icon),
            colorValue: s.color,
            kind: s.kind,
            sortOrder: Value(index),
          ),
      ]);
    });
  }

  // ---------------------------------------------------------------- settings

  Future<String?> settingValue(String key) async {
    final row = await (select(
      appSettings,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setSetting(String key, String value) => into(
    appSettings,
  ).insertOnConflictUpdate(AppSettingsCompanion.insert(key: key, value: value));

  /// Watches a single setting, so a currency or theme change repaints the app
  /// without a manual refresh.
  Stream<String?> watchSetting(String key) =>
      (select(appSettings)..where((t) => t.key.equals(key)))
          .watchSingleOrNull()
          .map((row) => row?.value);
}
