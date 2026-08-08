// drift exports SQL helpers named `isNull`/`isNotNull` that collide with the
// matchers of the same name.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:spend/core/day.dart';
import 'package:spend/core/money.dart';
import 'package:spend/data/db/database.dart';
import 'package:spend/domain/entities/enums.dart';

void main() {
  late SpendDatabase db;

  setUp(() => db = SpendDatabase.memory());
  tearDown(() => db.close());

  Future<int> insertTxn({
    required int categoryId,
    required Money amount,
    required Day on,
    String note = '',
  }) => db
      .into(db.transactions)
      .insert(
        TransactionsCompanion.insert(
          amountMinor: amount,
          categoryId: categoryId,
          occurredOn: on,
          note: Value(note),
        ),
      );

  group('seeding', () {
    test('creates a usable starter set of categories', () async {
      final cats = await db.select(db.categories).get();
      expect(cats, hasLength(11));
      expect(cats.map((c) => c.name), contains('Groceries'));

      final income = cats.where((c) => c.kind == CategoryKind.income);
      expect(income, hasLength(1));
      expect(income.single.name, 'Income');
    });

    test('seeds are ordered for display', () async {
      final cats = await (db.select(
        db.categories,
      )..orderBy([(t) => OrderingTerm(expression: t.sortOrder)])).get();
      expect(cats.first.name, 'Groceries');
      expect(cats.map((c) => c.sortOrder), List.generate(11, (i) => i));
    });
  });

  group('value types survive SQLite', () {
    test(
      'money round-trips exactly, including large and negative amounts',
      () async {
        const amounts = [1, -1, 0, 1234, -8705, 99999999, -99999999];
        for (final minor in amounts) {
          final id = await insertTxn(
            categoryId: 1,
            amount: Money(minor),
            on: Day(2025, 7, 14),
          );
          final row = await (db.select(
            db.transactions,
          )..where((t) => t.id.equals(id))).getSingle();
          expect(row.amountMinor, Money(minor));
          expect(row.amountMinor.minor, minor);
        }
      },
    );

    test('a summed column stays exact across many rows', () async {
      for (var i = 0; i < 500; i++) {
        await insertTxn(categoryId: 1, amount: Money(10), on: Day(2025, 7, 14));
      }
      final total = db.transactions.amountMinor.sum();
      final row = await (db.selectOnly(
        db.transactions,
      )..addColumns([total])).getSingle();
      expect(row.read(total), 5000); // exactly €50.00
    });

    test('dates round-trip and sort chronologically as text', () async {
      final days = [Day(2025, 12, 31), Day(2024, 2, 29), Day(2025, 1, 5)];
      for (final d in days) {
        await insertTxn(categoryId: 1, amount: Money(100), on: d);
      }
      final rows = await (db.select(
        db.transactions,
      )..orderBy([(t) => OrderingTerm(expression: t.occurredOn)])).get();
      expect(rows.map((r) => r.occurredOn), [
        Day(2024, 2, 29),
        Day(2025, 1, 5),
        Day(2025, 12, 31),
      ]);
    });

    test('months group by ISO prefix', () async {
      await insertTxn(categoryId: 1, amount: Money(100), on: Day(2025, 7, 1));
      await insertTxn(categoryId: 1, amount: Money(200), on: Day(2025, 7, 31));
      await insertTxn(categoryId: 1, amount: Money(400), on: Day(2025, 8, 1));

      final rows = await db
          .customSelect(
            'SELECT substr(occurred_on, 1, 7) AS m, SUM(amount_minor) AS total '
            'FROM transactions GROUP BY m ORDER BY m',
          )
          .get();
      expect(rows.map((r) => r.read<String>('m')), ['2025-07', '2025-08']);
      expect(rows.map((r) => r.read<int>('total')), [300, 400]);
    });
  });

  group('referential integrity', () {
    test(
      'a category with history cannot be deleted out from under it',
      () async {
        await insertTxn(
          categoryId: 1,
          amount: Money(500),
          on: Day(2025, 7, 14),
        );

        // RESTRICT is only enforced because beforeOpen enables foreign keys.
        // If that pragma regresses, this insert-then-delete would silently
        // orphan the transaction instead of throwing.
        await expectLater(
          (db.delete(db.categories)..where((c) => c.id.equals(1))).go(),
          throwsA(isA<Exception>()),
        );

        expect(await db.select(db.transactions).get(), hasLength(1));
      },
    );

    test('an unused category deletes cleanly', () async {
      await (db.delete(db.categories)..where((c) => c.id.equals(1))).go();
      expect(await db.select(db.categories).get(), hasLength(10));
    });

    test(
      'transactions cannot reference a category that does not exist',
      () async {
        await expectLater(
          insertTxn(categoryId: 9999, amount: Money(100), on: Day(2025, 7, 14)),
          throwsA(isA<Exception>()),
        );
      },
    );

    test(
      'deleting a recurring rule detaches its transactions but keeps them',
      () async {
        final ruleId = await db
            .into(db.recurringRules)
            .insert(
              RecurringRulesCompanion.insert(
                label: 'Spotify',
                amountMinor: Money(1099),
                categoryId: 6,
                cadence: Cadence.monthly,
                nextDueOn: Day(2025, 8, 3),
              ),
            );
        await db
            .into(db.transactions)
            .insert(
              TransactionsCompanion.insert(
                amountMinor: Money(1099),
                categoryId: 6,
                occurredOn: Day(2025, 7, 3),
                recurringRuleId: Value(ruleId),
              ),
            );

        await (db.delete(
          db.recurringRules,
        )..where((r) => r.id.equals(ruleId))).go();

        final rows = await db.select(db.transactions).get();
        expect(rows, hasLength(1), reason: 'history must outlive the rule');
        expect(rows.single.recurringRuleId, isNull);
      },
    );
  });

  group('settings', () {
    test('write, overwrite and read back', () async {
      expect(await db.settingValue('currency'), isNull);
      await db.setSetting('currency', 'EUR');
      expect(await db.settingValue('currency'), 'EUR');
      await db.setSetting('currency', 'USD');
      expect(await db.settingValue('currency'), 'USD');
    });

    test('watching a setting emits current state, then each change', () async {
      final expectation = expectLater(
        db.watchSetting('theme'),
        emitsInOrder(<Object?>[null, 'dark', 'light']),
      );
      // Let the initial query settle, otherwise the first write can land
      // before the stream has observed the absent value.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await db.setSetting('theme', 'dark');
      await db.setSetting('theme', 'light');
      await expectation;
    });
  });
}
