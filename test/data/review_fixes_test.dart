import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:spend/core/day.dart';
import 'package:spend/core/money.dart';
import 'package:spend/data/backup/backup_format.dart';
import 'package:spend/data/backup/backup_service.dart';
import 'package:spend/data/db/database.dart';
import 'package:spend/data/repositories/category_repository.dart';
import 'package:spend/data/repositories/transaction_repository.dart';
import 'package:spend/domain/entities/enums.dart';

/// Regressions for the data-integrity problems found in review.
///
/// Each of these was a silent failure — nothing threw, nothing looked wrong on
/// screen, and the damage only showed up as missing or duplicated rows later.
/// They are the failures a test suite has to carry, because the UI will not
/// tell you about them.
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

  group('history is not silently truncated', () {
    test(
      'watchAll returns every transaction, past any recent-list cap',
      () async {
        // 60 rows against a 50-row cap: the tenth-oldest is exactly what the
        // History screen used to lose.
        for (var i = 0; i < 60; i++) {
          await addTxn(minor: 100 + i, on: Day(2026, 1, 1).addDays(i));
        }

        final all = await transactions.watchAll().first;
        final recent = await transactions.watchRecent().first;

        expect(all.length, 60);
        expect(recent.length, 50, reason: 'the capped list is still capped');
        expect(all.first.occurredOn, Day(2026, 3, 1), reason: 'newest first');
        expect(
          all.last.occurredOn,
          Day(2026, 1, 1),
          reason: 'oldest still there',
        );
      },
    );
  });

  group('import de-duplication', () {
    test('the description is part of a transaction identity', () {
      // Two transit fares, same day, same amount, same category. Keying on
      // date+amount+category alone collapses them into one and loses a real
      // purchase.
      String key(String description) => TransactionRepository.transactionKey(
        amountMinor: 320,
        occurredOn: '2026-07-25',
        categoryId: 1,
        description: description,
      );

      expect(key('NS'), isNot(key('GVB')));
      expect(key('NS'), key(' ns '), reason: 'trimmed and case-folded');
    });

    test('existingKeys agrees with transactionKey', () async {
      await addTxn(minor: 320, on: Day(2026, 7, 25), merchant: 'NS');
      final keys = await transactions.existingKeys();

      expect(
        keys,
        contains(
          TransactionRepository.transactionKey(
            amountMinor: 320,
            occurredOn: '2026-07-25',
            categoryId: 1,
            description: 'NS',
          ),
        ),
      );
      expect(
        keys,
        isNot(
          contains(
            TransactionRepository.transactionKey(
              amountMinor: 320,
              occurredOn: '2026-07-25',
              categoryId: 1,
              description: 'GVB',
            ),
          ),
        ),
      );
    });
  });

  group('category usage counts every reference', () {
    test('a category used only by a recurring rule is still in use', () async {
      final repo = CategoryRepository(db);
      final categoryId = await db
          .into(db.categories)
          .insert(
            CategoriesCompanion.insert(
              name: 'Streaming',
              colorValue: 0xFF00FF,
              kind: CategoryKind.expense,
            ),
          );

      expect(await repo.usageCount(categoryId), 0);

      await db
          .into(db.recurringRules)
          .insert(
            RecurringRulesCompanion.insert(
              label: 'Netflix',
              amountMinor: Money(1399),
              categoryId: categoryId,
              cadence: Cadence.monthly,
              nextDueOn: Day(2026, 9, 1),
            ),
          );

      // Both tables hold a RESTRICT foreign key, so counting only transactions
      // let this pass the check and then throw from the delete.
      expect(await repo.usageCount(categoryId), 1);
      expect(await repo.deleteIfUnused(categoryId), isFalse);
    });
  });

  group('backup archives are validated, not trusted', () {
    late BackupService service;
    setUp(() => service = BackupService(db, appVersion: '1.0.0-test'));

    /// Rebuilds an archive with the manifest counts tampered with, leaving the
    /// data checksum intact — the checksum covers `data.json` only.
    Uint8List forgeCounts(Uint8List original, Map<String, int> counts) {
      final archive = ZipDecoder().decodeBytes(original);
      final manifestFile = archive.files.firstWhere(
        (f) => f.name == 'manifest.json',
      );
      final dataFile = archive.files.firstWhere((f) => f.name == 'data.json');

      final manifest =
          jsonDecode(utf8.decode(manifestFile.content as List<int>))
              as Map<String, Object?>;
      manifest['counts'] = counts;
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(manifest)));

      final rebuilt = Archive()
        ..addFile(ArchiveFile('manifest.json', bytes.length, bytes))
        ..addFile(
          ArchiveFile(
            'data.json',
            dataFile.content.length,
            dataFile.content as List<int>,
          ),
        );
      return Uint8List.fromList(ZipEncoder().encode(rebuilt));
    }

    test('a manifest that disagrees with its payload is rejected', () async {
      await addTxn(minor: 1240, on: Day(2026, 7, 25), merchant: 'AH');
      await addTxn(minor: 890, on: Day(2026, 7, 26), merchant: 'Coffee');
      final good = await service.buildArchive();

      // Sanity: untampered, it inspects fine.
      final ok = await service.inspect(good);
      expect(ok.payload.transactions.length, 2);

      // The restore dialog shows these numbers, and "Replace everything" is
      // chosen from that dialog — a manifest claiming zero over a payload of
      // hundreds must not be possible.
      final forged = forgeCounts(good, {
        ...ok.manifest.counts,
        'transactions': 0,
      });
      expect(
        () => service.inspect(forged),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });

  group('merging a backup', () {
    late BackupService service;
    setUp(() => service = BackupService(db, appVersion: '1.0.0-test'));

    test(
      'merging the same archive twice adds nothing the second time',
      () async {
        await addTxn(minor: 1240, on: Day(2026, 7, 25), merchant: 'AH');
        await db
            .into(db.recurringRules)
            .insert(
              RecurringRulesCompanion.insert(
                label: 'Rent',
                amountMinor: Money(120000),
                categoryId: 1,
                cadence: Cadence.monthly,
                nextDueOn: Day(2026, 8, 1),
              ),
            );

        final archive = await service.buildArchive();
        final inspected = await service.inspect(archive);

        final first = await service.restore(
          inspected.payload,
          mode: RestoreMode.merge,
        );
        final second = await service.restore(
          inspected.payload,
          mode: RestoreMode.merge,
        );

        expect(first.recurringAdded, 0, reason: 'the rule is already present');
        expect(second.recurringAdded, 0);
        expect(second.transactionsAdded, 0);

        // Two copies of a monthly rule would post the charge twice, every month,
        // forever — the failure that made this worth a test.
        final rules = await db.select(db.recurringRules).get();
        expect(rules.length, 1);
      },
    );

    test('subcategory parents survive the id remap', () async {
      // An archive from a *different* machine: ids that will not match this
      // database, and a child that appears before its parent.
      const payload = BackupPayload(
        categories: [
          {
            'id': 900,
            'name': 'Fresh produce',
            'color_value': 0x00FF00,
            'kind': 'expense',
            'parent_id': 901,
            'is_archived': false,
            'sort_order': 1,
          },
          {
            'id': 901,
            'name': 'Food shopping',
            'color_value': 0xFF0000,
            'kind': 'expense',
            'parent_id': null,
            'is_archived': false,
            'sort_order': 0,
          },
        ],
        recurringRules: [],
        transactions: [],
        budgets: [],
        settings: [],
      );

      await service.restore(payload, mode: RestoreMode.merge);

      final rows = await db.select(db.categories).get();
      final child = rows.firstWhere((c) => c.name == 'Fresh produce');
      final parent = rows.firstWhere((c) => c.name == 'Food shopping');

      // Carried over unmapped, 901 would point at an unrelated local category.
      expect(child.parentId, parent.id);
      expect(child.parentId, isNot(901));
      expect(parent.parentId, isNull);
    });

    test('a category is never left parenting itself', () async {
      // Both archive ids collapse onto one local category, which is exactly
      // the case that would write a self-referencing parent.
      final id = await db
          .into(db.categories)
          .insert(
            CategoriesCompanion.insert(
              name: 'Food',
              colorValue: 0xFF0000,
              kind: CategoryKind.expense,
            ),
          );

      const payload = BackupPayload(
        categories: [
          {
            'id': 700,
            'name': 'Food',
            'color_value': 0xFF0000,
            'kind': 'expense',
            'parent_id': 700,
            'is_archived': false,
            'sort_order': 0,
          },
        ],
        recurringRules: [],
        transactions: [],
        budgets: [],
        settings: [],
      );

      await service.restore(payload, mode: RestoreMode.merge);

      final row = await (db.select(
        db.categories,
      )..where((c) => c.id.equals(id))).getSingle();
      expect(row.parentId, isNull);
    });
  });
}
