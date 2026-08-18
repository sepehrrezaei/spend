import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:spend/core/day.dart';
import 'package:spend/core/money.dart';
import 'package:spend/data/db/database.dart';
import 'package:spend/data/repositories/transaction_repository.dart';

/// History search.
///
/// The 200-row cap this removes was doing three jobs, only one of them
/// written down. These pin all three so the next person to touch the query
/// finds out from a test rather than from a user with four years of history.
void main() {
  late SpendDatabase db;
  late TransactionRepository transactions;

  setUp(() {
    db = SpendDatabase.memory();
    transactions = TransactionRepository(db);
  });
  tearDown(() => db.close());

  Future<int> addTxn({
    required int minor,
    required Day on,
    int categoryId = 1,
    String merchant = '',
    String note = '',
  }) => db
      .into(db.transactions)
      .insert(
        TransactionsCompanion.insert(
          amountMinor: Money(minor),
          categoryId: categoryId,
          occurredOn: on,
          merchant: Value(merchant),
          note: Value(note),
        ),
      );

  group('nothing is silently truncated', () {
    test('every match comes back, past the old 200-row cap', () async {
      for (var i = 0; i < 210; i++) {
        await addTxn(
          minor: 100 + i,
          on: Day(2026, 1, 1).addDays(i),
          merchant: 'Albert Heijn',
        );
      }
      await addTxn(minor: 999, on: Day(2026, 1, 1), merchant: 'Jumbo');

      final results = await transactions.search('Albert').first;
      expect(results.length, 210);
    });
  });

  group('the term is matched literally', () {
    setUp(() async {
      await addTxn(minor: 1240, on: Day(2026, 7, 25), merchant: 'Albert Heijn');
      await addTxn(minor: 890, on: Day(2026, 7, 26), merchant: 'Jumbo');
      await addTxn(minor: 320, on: Day(2026, 7, 27), merchant: '50% off shop');
    });

    test('a lone % is a search for "%", not for everything', () async {
      // Unescaped, this matched every transaction in the database — and
      // uncapped that means one keystroke loads the whole ledger.
      final results = await transactions.search('%').first;
      expect(results.map((r) => r.merchant), ['50% off shop']);
    });

    test('_ does not stand in for an arbitrary character', () async {
      // Unescaped, "Alb_rt" matched "Albert Heijn": a literal search
      // returning a row that does not contain the typed text.
      expect(await transactions.search('Alb_rt').first, isEmpty);
      expect(await transactions.search('Albert').first, hasLength(1));
    });

    test('a backslash is matched as a backslash', () async {
      await addTxn(minor: 100, on: Day(2026, 7, 28), merchant: r'A\B Store');
      final results = await transactions.search(r'A\B').first;
      expect(results.map((r) => r.merchant), [r'A\B Store']);
    });

    test('escaping does not break ordinary searches', () async {
      expect(await transactions.search('jumbo').first, hasLength(1));
      expect(await transactions.search('  Albert  ').first, hasLength(1));
    });
  });

  group('ordering', () {
    test('same-day rows order deterministically, like watchAll', () async {
      // Three fares on one day. Ordering by date alone leaves these in
      // whatever order SQLite scans them, so the list can reshuffle after any
      // write and disagree with the unfiltered view when the box is cleared.
      for (var i = 0; i < 3; i++) {
        await addTxn(
          minor: 320,
          on: Day(2026, 7, 25),
          merchant: 'Transit $i',
          note: 'fare',
        );
      }

      final searched = await transactions.search('fare').first;
      final unfiltered = await transactions.watchAll().first;

      expect(searched.map((r) => r.id), unfiltered.map((r) => r.id));
      expect(searched.map((r) => r.id), [3, 2, 1], reason: 'newest id first');
    });

    test('newest day first', () async {
      await addTxn(minor: 100, on: Day(2026, 1, 1), merchant: 'AH');
      await addTxn(minor: 200, on: Day(2026, 6, 1), merchant: 'AH');
      final results = await transactions.search('AH').first;
      expect(results.first.occurredOn, Day(2026, 6, 1));
      expect(results.last.occurredOn, Day(2026, 1, 1));
    });
  });

  group('what search covers', () {
    test('merchant, note and category name', () async {
      await addTxn(minor: 100, on: Day(2026, 7, 1), merchant: 'Jumbo');
      await addTxn(minor: 200, on: Day(2026, 7, 2), note: 'weekly shop');

      expect(await transactions.search('Jumbo').first, hasLength(1));
      expect(await transactions.search('weekly').first, hasLength(1));
      // Category name is matched too, which the old docstring did not say.
      expect(await transactions.search('Groceries').first, hasLength(2));
    });
  });
}
