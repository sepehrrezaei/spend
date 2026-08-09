import 'package:drift/drift.dart';

import '../../core/day.dart';
import '../../core/money.dart';
import '../../domain/entities/budget_definition.dart';
import '../../domain/entities/enums.dart';
import '../db/database.dart';

/// Reads and writes spending limits.
class BudgetRepository {
  final SpendDatabase _db;

  BudgetRepository(this._db);

  BudgetDefinition _toDefinition(Budget row) => BudgetDefinition(
    id: row.id,
    categoryId: row.categoryId,
    period: row.period,
    limit: row.amountMinor,
    startsOn: row.startsOn,
    endsOn: row.endsOn,
  );

  /// Budgets currently in force.
  Stream<List<BudgetDefinition>> watchActive() =>
      (_db.select(_db.budgets)..where((b) => b.endsOn.isNull())).watch().map(
        (rows) => rows.map(_toDefinition).toList(),
      );

  Future<List<BudgetDefinition>> active() async {
    final rows = await (_db.select(
      _db.budgets,
    )..where((b) => b.endsOn.isNull())).get();
    return rows.map(_toDefinition).toList();
  }

  /// Sets the limit for a category, or the overall limit when [categoryId] is
  /// null.
  ///
  /// Supersedes rather than overwrites: the existing row is closed the day
  /// before the new one starts, so a completed month keeps being judged
  /// against the limit that was actually in force then. Editing in place would
  /// silently rewrite history.
  Future<void> setLimit({
    int? categoryId,
    required BudgetPeriod period,
    required Money limit,
    Day? effectiveFrom,
  }) async {
    final from = effectiveFrom ?? Day.today().firstOfMonth;

    await _db.transaction(() async {
      final existing =
          await (_db.select(_db.budgets)..where(
                (b) =>
                    b.endsOn.isNull() &
                    (categoryId == null
                        ? b.categoryId.isNull()
                        : b.categoryId.equals(categoryId)),
              ))
              .get();

      for (final row in existing) {
        if (row.startsOn >= from) {
          // The current row never applied to a completed period, so there is
          // no history to preserve — replace it outright.
          await (_db.delete(
            _db.budgets,
          )..where((b) => b.id.equals(row.id))).go();
        } else {
          await (_db.update(_db.budgets)..where((b) => b.id.equals(row.id)))
              .write(BudgetsCompanion(endsOn: Value(from.addDays(-1))));
        }
      }

      if (limit.isZero) return; // A zero limit means "no budget".

      await _db
          .into(_db.budgets)
          .insert(
            BudgetsCompanion.insert(
              categoryId: Value(categoryId),
              period: period,
              amountMinor: limit,
              startsOn: from,
            ),
          );
    });
  }

  /// Removes a budget entirely, including its history.
  Future<void> delete(int id) =>
      (_db.delete(_db.budgets)..where((b) => b.id.equals(id))).go();
}
