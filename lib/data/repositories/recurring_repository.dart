import 'package:drift/drift.dart';

import '../../core/day.dart';
import '../../core/money.dart';
import '../../domain/entities/enums.dart';
import '../db/database.dart';

/// Reads and writes recurring commitments: rent, subscriptions, gym.
class RecurringRepository {
  final SpendDatabase _db;

  RecurringRepository(this._db);

  Stream<List<RecurringRule>> watchActive() =>
      (_db.select(_db.recurringRules)
            ..where((r) => r.isActive.equals(true))
            ..orderBy([(r) => OrderingTerm.desc(r.amountMinor)]))
          .watch();

  Stream<List<RecurringRule>> watchAll() =>
      (_db.select(_db.recurringRules)..orderBy([
            (r) =>
                OrderingTerm(expression: r.isActive, mode: OrderingMode.desc),
            (r) => OrderingTerm.desc(r.amountMinor),
          ]))
          .watch();

  Future<int> add({
    required String label,
    required Money amount,
    required int categoryId,
    required Cadence cadence,
    required Day nextDueOn,
  }) => _db
      .into(_db.recurringRules)
      .insert(
        RecurringRulesCompanion.insert(
          label: label.trim(),
          amountMinor: amount,
          categoryId: categoryId,
          cadence: cadence,
          nextDueOn: nextDueOn,
        ),
      );

  Future<void> update({
    required int id,
    String? label,
    Money? amount,
    int? categoryId,
    Cadence? cadence,
    Day? nextDueOn,
    bool? isActive,
  }) => (_db.update(_db.recurringRules)..where((r) => r.id.equals(id))).write(
    RecurringRulesCompanion(
      label: label == null ? const Value.absent() : Value(label.trim()),
      amountMinor: amount == null ? const Value.absent() : Value(amount),
      categoryId: categoryId == null ? const Value.absent() : Value(categoryId),
      cadence: cadence == null ? const Value.absent() : Value(cadence),
      nextDueOn: nextDueOn == null ? const Value.absent() : Value(nextDueOn),
      isActive: isActive == null ? const Value.absent() : Value(isActive),
    ),
  );

  /// Deletes a rule. Transactions it produced keep their history — the
  /// schema's SET NULL detaches them rather than deleting them.
  Future<void> delete(int id) =>
      (_db.delete(_db.recurringRules)..where((r) => r.id.equals(id))).go();

  /// Records that a rule fired: writes the transaction and advances the due
  /// date by one cadence step.
  ///
  /// Advancing from the *scheduled* date rather than today keeps a monthly
  /// charge anchored to its day of the month even when logged a few days late.
  Future<void> markPaid(RecurringRule rule, {Day? on}) async {
    final paidOn = on ?? rule.nextDueOn;
    await _db.transaction(() async {
      await _db
          .into(_db.transactions)
          .insert(
            TransactionsCompanion.insert(
              amountMinor: rule.amountMinor,
              categoryId: rule.categoryId,
              occurredOn: paidOn,
              merchant: Value(rule.label),
              recurringRuleId: Value(rule.id),
            ),
          );
      await (_db.update(
        _db.recurringRules,
      )..where((r) => r.id.equals(rule.id))).write(
        RecurringRulesCompanion(
          nextDueOn: Value(advance(rule.nextDueOn, rule.cadence)),
        ),
      );
    });
  }

  /// The next occurrence after [from] for a given cadence.
  static Day advance(Day from, Cadence cadence) => switch (cadence) {
    Cadence.weekly => from.addDays(7),
    Cadence.fortnightly => from.addDays(14),
    Cadence.monthly => from.addMonths(1),
    Cadence.quarterly => from.addMonths(3),
    Cadence.yearly => from.addYears(1),
  };

  /// What these commitments cost per month on average.
  ///
  /// Normalises differently-paced charges onto one figure so a €120 quarterly
  /// bill and a €40 monthly one can be compared. Uses occurrences per year
  /// divided by twelve rather than naive day arithmetic, so a weekly charge
  /// correctly costs more than four times its amount each month.
  static Money monthlyEquivalent(Iterable<RecurringRule> rules) {
    var totalMinor = 0.0;
    for (final r in rules) {
      totalMinor += r.amountMinor.minor * r.cadence.occurrencesPerYear / 12;
    }
    return Money(totalMinor.round());
  }

  /// Rules due on or before [through], soonest first.
  Future<List<RecurringRule>> dueBy(Day through) async {
    final rows =
        await (_db.select(_db.recurringRules)
              ..where((r) => r.isActive.equals(true))
              ..orderBy([(r) => OrderingTerm(expression: r.nextDueOn)]))
            .get();
    return rows.where((r) => r.nextDueOn <= through).toList();
  }
}
