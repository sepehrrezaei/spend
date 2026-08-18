import 'package:drift/drift.dart';

import '../../core/date_range.dart';
import '../../core/day.dart';
import '../../core/money.dart';
import '../../domain/entities/spend_record.dart';
import '../db/database.dart';

/// Reads and writes transactions, translating between database rows and the
/// [SpendRecord] shape the rest of the app reasons about.
class TransactionRepository {
  final SpendDatabase _db;

  TransactionRepository(this._db);

  /// Joins a transaction row onto its category.
  SpendRecord _toRecord(Transaction txn, Category cat) => SpendRecord(
    id: txn.id,
    amount: txn.amountMinor,
    occurredOn: txn.occurredOn,
    categoryId: cat.id,
    categoryName: cat.name,
    categoryIcon: cat.iconName,
    categoryColor: cat.colorValue,
    categoryKind: cat.kind,
    note: txn.note,
    merchant: txn.merchant,
    paymentMethod: txn.paymentMethod,
    recurringRuleId: txn.recurringRuleId,
  );

  JoinedSelectStatement<HasResultSet, dynamic> _joined() =>
      _db.select(_db.transactions).join([
        innerJoin(
          _db.categories,
          _db.categories.id.equalsExp(_db.transactions.categoryId),
        ),
      ]);

  List<SpendRecord> _map(List<TypedResult> rows) => [
    for (final r in rows)
      _toRecord(r.readTable(_db.transactions), r.readTable(_db.categories)),
  ];

  /// Every transaction in [range], newest first.
  ///
  /// Returned as a stream so the dashboard and lists recompute automatically
  /// when a transaction is added anywhere in the app — including from the
  /// menu-bar window, which is a separate route onto the same database.
  Stream<List<SpendRecord>> watchInRange(DateRange range) {
    final q = _joined()
      ..where(
        _db.transactions.occurredOn.isBiggerOrEqualValue(range.start.iso) &
            _db.transactions.occurredOn.isSmallerOrEqualValue(range.end.iso),
      )
      ..orderBy([
        OrderingTerm.desc(_db.transactions.occurredOn),
        OrderingTerm.desc(_db.transactions.id),
      ]);
    return q.watch().map(_map);
  }

  Future<List<SpendRecord>> inRange(DateRange range) async {
    final q = _joined()
      ..where(
        _db.transactions.occurredOn.isBiggerOrEqualValue(range.start.iso) &
            _db.transactions.occurredOn.isSmallerOrEqualValue(range.end.iso),
      )
      ..orderBy([OrderingTerm.desc(_db.transactions.occurredOn)]);
    return _map(await q.get());
  }

  /// Every transaction, newest first.
  ///
  /// Uncapped on purpose: this backs the History screen, and a limit there
  /// silently hides older entries once the ledger outgrows it.
  Stream<List<SpendRecord>> watchAll() {
    final q = _joined()
      ..orderBy([
        OrderingTerm.desc(_db.transactions.occurredOn),
        OrderingTerm.desc(_db.transactions.id),
      ]);
    return q.watch().map(_map);
  }

  /// The most recent transactions regardless of date, for the entry screen's
  /// "recently used" affordances. Never use this to display history.
  Stream<List<SpendRecord>> watchRecent({int limit = 50}) {
    final q = _joined()
      ..orderBy([
        OrderingTerm.desc(_db.transactions.occurredOn),
        OrderingTerm.desc(_db.transactions.id),
      ])
      ..limit(limit);
    return q.watch().map(_map);
  }

  /// Every transaction, oldest first, for CSV export.
  Future<List<SpendRecord>> allForExport() async {
    final q = _joined()
      ..orderBy([
        OrderingTerm.asc(_db.transactions.occurredOn),
        OrderingTerm.asc(_db.transactions.id),
      ]);
    return _map(await q.get());
  }

  /// Inserts many transactions in one batch, for CSV import.
  ///
  /// A single batch rather than a loop of inserts: importing a few thousand
  /// rows one statement at a time is slow enough to look frozen.
  Future<int> addAll(
    List<
      ({
        Money amount,
        int categoryId,
        Day occurredOn,
        String merchant,
        String note,
      })
    >
    entries,
  ) async {
    if (entries.isEmpty) return 0;
    await _db.batch((b) {
      b.insertAll(_db.transactions, [
        for (final e in entries)
          TransactionsCompanion.insert(
            amountMinor: e.amount,
            categoryId: e.categoryId,
            occurredOn: e.occurredOn,
            merchant: Value(e.merchant),
            note: Value(e.note),
          ),
      ]);
    });
    return entries.length;
  }

  /// Natural keys of existing transactions, for import de-duplication.
  ///
  /// Includes the description, so two genuinely separate purchases of the same
  /// amount on the same day — two transit fares, two coffees — stay two rows.
  /// Date, amount and category alone collapse them into one.
  ///
  /// Deliberately the same shape as the backup merge key, so the two paths
  /// agree on what "the same transaction" means.
  Future<Set<String>> existingKeys() async {
    final rows = await _db.select(_db.transactions).get();
    return {
      for (final t in rows)
        transactionKey(
          amountMinor: t.amountMinor.minor,
          occurredOn: t.occurredOn.iso,
          categoryId: t.categoryId,
          description: t.merchant.isNotEmpty ? t.merchant : t.note,
        ),
    };
  }

  /// The natural identity of a transaction, for de-duplication.
  static String transactionKey({
    required int amountMinor,
    required String occurredOn,
    required int categoryId,
    required String description,
  }) =>
      '$occurredOn|$amountMinor|$categoryId|'
      '${description.trim().toLowerCase()}';

  /// The earliest recorded date, or null when there is no history yet.
  /// Bounds the range pickers so they cannot wander into empty years.
  Future<Day?> earliestDate() async {
    final min = _db.transactions.occurredOn.min();
    final row = await (_db.selectOnly(
      _db.transactions,
    )..addColumns([min])).getSingleOrNull();
    final iso = row?.read(min);
    return iso == null ? null : Day.tryParse(iso);
  }

  Future<int> add({
    required Money amount,
    required int categoryId,
    required Day occurredOn,
    String note = '',
    String merchant = '',
    String? paymentMethod,
    int? recurringRuleId,
  }) => _db
      .into(_db.transactions)
      .insert(
        TransactionsCompanion.insert(
          amountMinor: amount,
          categoryId: categoryId,
          occurredOn: occurredOn,
          note: Value(note),
          merchant: Value(merchant),
          paymentMethod: Value(paymentMethod),
          recurringRuleId: Value(recurringRuleId),
        ),
      );

  Future<void> update({
    required int id,
    Money? amount,
    int? categoryId,
    Day? occurredOn,
    String? note,
    String? merchant,
    String? paymentMethod,
  }) => (_db.update(_db.transactions)..where((t) => t.id.equals(id))).write(
    TransactionsCompanion(
      amountMinor: amount == null ? const Value.absent() : Value(amount),
      categoryId: categoryId == null ? const Value.absent() : Value(categoryId),
      occurredOn: occurredOn == null ? const Value.absent() : Value(occurredOn),
      note: note == null ? const Value.absent() : Value(note),
      merchant: merchant == null ? const Value.absent() : Value(merchant),
      paymentMethod: paymentMethod == null
          ? const Value.absent()
          : Value(paymentMethod),
      updatedAt: Value(DateTime.now()),
    ),
  );

  Future<void> delete(int id) =>
      (_db.delete(_db.transactions)..where((t) => t.id.equals(id))).go();

  Future<void> deleteMany(Iterable<int> ids) =>
      (_db.delete(_db.transactions)..where((t) => t.id.isIn(ids))).go();

  /// Restores a deleted transaction under its original id, so an undo action
  /// puts the row back exactly as it was rather than appending a copy.
  Future<void> restore(SpendRecord record) => _db
      .into(_db.transactions)
      .insert(
        TransactionsCompanion.insert(
          id: Value(record.id),
          amountMinor: record.amount,
          categoryId: record.categoryId,
          occurredOn: record.occurredOn,
          note: Value(record.note),
          merchant: Value(record.merchant),
          paymentMethod: Value(record.paymentMethod),
          recurringRuleId: Value(record.recurringRuleId),
        ),
      );

  /// Free-text search over merchant, note and category name.
  ///
  /// Uncapped, like [watchAll]: this backs the History screen, and a limit
  /// there silently hides older matches once the ledger outgrows it. Search is
  /// the worse place for that than the plain list, because the user has
  /// explicitly asked for everything matching.
  ///
  /// No `limit` parameter on purpose. One would have no caller today, and its
  /// only effect would be to let a future one quietly reintroduce the
  /// truncation this exists to remove.
  Stream<List<SpendRecord>> search(String term) {
    final q = _joined()
      ..where(
        _db.transactions.merchant.like(
              _likePattern(term),
              escapeChar: _likeEscape,
            ) |
            _db.transactions.note.like(
              _likePattern(term),
              escapeChar: _likeEscape,
            ) |
            _db.categories.name.like(
              _likePattern(term),
              escapeChar: _likeEscape,
            ),
      )
      // The id tiebreaker matches every other list query here. Ordering by
      // date alone leaves same-day rows in whatever order SQLite happens to
      // scan them, so the list could reshuffle after any write, and clearing
      // the search box — which switches this screen to watchAll — could show
      // the same day's rows in a different order than the search just did.
      ..orderBy([
        OrderingTerm.desc(_db.transactions.occurredOn),
        OrderingTerm.desc(_db.transactions.id),
      ]);
    return q.watch().map(_map);
  }

  static const _likeEscape = '\\';

  /// Wraps [term] in wildcards, escaping the ones the user typed.
  ///
  /// `%` and `_` are LIKE metacharacters. Interpolated raw, a single `%`
  /// matches every transaction in the database and `Alb_rt` matches "Albert" —
  /// a literal search returning rows that do not contain the typed text. That
  /// was survivable while the query was capped at 200 rows; uncapped it means
  /// one keystroke can load the entire ledger.
  static String _likePattern(String term) {
    final escaped = term
        .trim()
        .replaceAll(_likeEscape, '$_likeEscape$_likeEscape')
        .replaceAll('%', '$_likeEscape%')
        .replaceAll('_', '${_likeEscape}_');
    return '%$escaped%';
  }

  /// Distinct merchant names, most used first, to power entry autocomplete.
  Future<List<String>> knownMerchants({int limit = 100}) async {
    final rows = await _db
        .customSelect(
          'SELECT merchant, COUNT(*) AS uses FROM transactions '
          "WHERE merchant <> '' GROUP BY merchant ORDER BY uses DESC LIMIT ?",
          variables: [Variable.withInt(limit)],
        )
        .get();
    return [for (final r in rows) r.read<String>('merchant')];
  }

  /// The category most recently used with [merchant], for suggesting one
  /// automatically as the merchant is typed.
  Future<int?> suggestedCategoryFor(String merchant) async {
    if (merchant.trim().isEmpty) return null;
    final row =
        await (_db.select(_db.transactions)
              ..where((t) => t.merchant.equals(merchant.trim()))
              ..orderBy([(t) => OrderingTerm.desc(t.occurredOn)])
              ..limit(1))
            .getSingleOrNull();
    return row?.categoryId;
  }
}
