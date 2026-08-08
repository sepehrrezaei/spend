import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:spend/core/day.dart';
import 'package:spend/core/money.dart';
import 'package:spend/data/backup/backup_format.dart';
import 'package:spend/data/backup/backup_service.dart';
import 'package:spend/data/db/database.dart';
import 'package:spend/domain/entities/enums.dart';

void main() {
  late SpendDatabase db;
  late BackupService service;

  setUp(() {
    db = SpendDatabase.memory();
    service = BackupService(db, appVersion: '1.0.0-test');
  });
  tearDown(() => db.close());

  Future<void> seed() async {
    await db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            amountMinor: Money(1240),
            categoryId: 1,
            occurredOn: Day(2026, 7, 25),
            merchant: const Value('Albert Heijn'),
            note: const Value('weekly shop'),
          ),
        );
    await db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            amountMinor: Money(-350),
            categoryId: 1,
            occurredOn: Day(2026, 7, 26),
            merchant: const Value('Albert Heijn'),
            note: const Value('refund'),
          ),
        );
    final ruleId = await db
        .into(db.recurringRules)
        .insert(
          RecurringRulesCompanion.insert(
            label: 'Rent',
            amountMinor: Money(120000),
            categoryId: 4,
            cadence: Cadence.monthly,
            nextDueOn: Day(2026, 8, 1),
          ),
        );
    await db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            amountMinor: Money(120000),
            categoryId: 4,
            occurredOn: Day(2026, 7, 1),
            recurringRuleId: Value(ruleId),
          ),
        );
    await db
        .into(db.budgets)
        .insert(
          BudgetsCompanion.insert(
            categoryId: const Value(1),
            period: BudgetPeriod.monthly,
            amountMinor: Money(45000),
            startsOn: Day(2026, 7, 1),
          ),
        );
    await db.setSetting('currency', 'EUR');
  }

  /// Aggregate fingerprint of the database, for comparing before and after.
  Future<Map<String, Object?>> fingerprint(SpendDatabase d) async {
    final txns = await d.select(d.transactions).get();
    final cats = await d.select(d.categories).get();
    return {
      'txnCount': txns.length,
      'catCount': cats.length,
      // The exact sum in minor units. Any precision loss anywhere in the
      // round trip shows up here.
      'sumMinor': txns.fold<int>(0, (a, t) => a + t.amountMinor.minor),
      'dates': (txns.map((t) => t.occurredOn.iso).toList()..sort()).join(','),
      'merchants': (txns.map((t) => t.merchant).toList()..sort()).join(','),
      'budgetCount': (await d.select(d.budgets).get()).length,
      'ruleCount': (await d.select(d.recurringRules).get()).length,
    };
  }

  group('round trip', () {
    test('export, wipe, restore reproduces the database exactly', () async {
      await seed();
      final before = await fingerprint(db);
      expect(before['sumMinor'], 1240 - 350 + 120000);

      final archive = await service.buildArchive();
      expect(archive, isNotEmpty);

      // Wipe everything, children first.
      await db.delete(db.transactions).go();
      await db.delete(db.budgets).go();
      await db.delete(db.recurringRules).go();
      await db.delete(db.categories).go();
      await db.delete(db.appSettings).go();
      expect(await db.select(db.transactions).get(), isEmpty);

      final read = await service.inspect(archive);
      await service.restore(read.payload, mode: RestoreMode.replace);

      expect(await fingerprint(db), before);
      expect(await db.settingValue('currency'), 'EUR');
    });

    test('negative amounts and links survive the trip', () async {
      await seed();
      final archive = await service.buildArchive();
      await db.delete(db.transactions).go();
      await db.delete(db.budgets).go();
      await db.delete(db.recurringRules).go();
      await db.delete(db.categories).go();

      final read = await service.inspect(archive);
      await service.restore(read.payload, mode: RestoreMode.replace);

      final refund = await (db.select(
        db.transactions,
      )..where((t) => t.note.equals('refund'))).getSingle();
      expect(refund.amountMinor, Money(-350));

      final linked = await (db.select(
        db.transactions,
      )..where((t) => t.recurringRuleId.isNotNull())).getSingle();
      expect(linked.amountMinor, Money(120000));
      // The rule it points at must exist, or foreign keys would have rejected
      // the insert.
      final rule = await (db.select(
        db.recurringRules,
      )..where((r) => r.id.equals(linked.recurringRuleId!))).getSingle();
      expect(rule.label, 'Rent');
    });

    test('the manifest describes what is inside', () async {
      await seed();
      final read = await service.inspect(await service.buildArchive());
      expect(read.manifest.formatVersion, BackupManifest.currentFormatVersion);
      expect(read.manifest.schemaVersion, db.schemaVersion);
      expect(read.manifest.appVersion, '1.0.0-test');
      expect(read.manifest.counts['transactions'], 3);
      expect(read.manifest.counts['categories'], 11);
      expect(read.manifest.totalRows, greaterThan(13));
    });

    test('a suggested filename carries the date and extension', () {
      final name = BackupService.suggestedFileName(DateTime(2026, 7, 5));
      expect(name, 'spend-2026-07-05.spendbak');
    });
  });

  group('refusing bad archives', () {
    test('a corrupted payload is caught by the checksum', () async {
      await seed();
      final good = await service.inspect(await service.buildArchive());

      // Rebuild the archive with the manifest intact but the data altered,
      // exactly what silent bit-rot or a truncated copy would look like.
      final tampered = BackupPayload(
        categories: good.payload.categories,
        recurringRules: good.payload.recurringRules,
        transactions: [
          for (final t in good.payload.transactions)
            {...t, 'amount_minor': 999999},
        ],
        budgets: good.payload.budgets,
        settings: good.payload.settings,
      );
      final dataBytes = encodePayload(tampered);
      final manifestBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(good.manifest.toJson())),
      );
      final archive = Archive()
        ..addFile(
          ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
        )
        ..addFile(ArchiveFile('data.json', dataBytes.length, dataBytes));
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

      await expectLater(
        service.inspect(bytes),
        throwsA(isA<BackupFormatException>()),
      );
      // And crucially, the live data is untouched.
      expect(await db.select(db.transactions).get(), hasLength(3));
    });

    test(
      'a backup from a newer schema is refused rather than half-applied',
      () async {
        await seed();
        final good = await service.inspect(await service.buildArchive());

        final future = BackupManifest(
          formatVersion: BackupManifest.currentFormatVersion,
          schemaVersion: db.schemaVersion + 5,
          appVersion: '99.0.0',
          exportedAt: DateTime.now(),
          dataChecksum: good.manifest.dataChecksum,
          counts: good.manifest.counts,
        );
        expect(
          () => future.assertReadable(currentSchemaVersion: db.schemaVersion),
          throwsA(isA<BackupFormatException>()),
        );
      },
    );

    test('an older schema is accepted for migration', () {
      final old = BackupManifest(
        formatVersion: 1,
        schemaVersion: 1,
        appVersion: '0.1.0',
        exportedAt: DateTime.now(),
        dataChecksum: 'x',
        counts: const {},
      );
      expect(
        () => old.assertReadable(currentSchemaVersion: 7),
        returnsNormally,
      );
    });

    test('a file that is not a zip is rejected clearly', () async {
      await expectLater(
        service.inspect(Uint8List.fromList(utf8.encode('not a backup'))),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('a zip without a manifest is rejected', () async {
      final junk = Uint8List.fromList(utf8.encode('{}'));
      final archive = Archive()
        ..addFile(ArchiveFile('random.json', junk.length, junk));
      await expectLater(
        service.inspect(Uint8List.fromList(ZipEncoder().encode(archive))),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });

  group('merging', () {
    test('duplicate transactions are skipped, new ones added', () async {
      await seed();
      final archive = await service.buildArchive();
      final read = await service.inspect(archive);

      // Restoring the same archive over itself should add nothing at all.
      final report = await service.restore(
        read.payload,
        mode: RestoreMode.merge,
      );
      expect(report.transactionsAdded, 0);
      expect(report.transactionsSkipped, 3);
      expect(await db.select(db.transactions).get(), hasLength(3));
    });

    test('merging into a database with different ids remaps categories', () async {
      await seed();
      final archive = await service.buildArchive();
      final read = await service.inspect(archive);

      // A fresh database whose category ids differ: inserting an extra
      // category first shifts everything that follows.
      final other = SpendDatabase.memory();
      addTearDown(other.close);
      await other
          .into(other.categories)
          .insert(
            CategoriesCompanion.insert(
              name: 'Coffee',
              colorValue: 0xFF000000,
              kind: CategoryKind.expense,
            ),
          );
      final otherService = BackupService(other, appVersion: 'test');
      final report = await otherService.restore(
        read.payload,
        mode: RestoreMode.merge,
      );

      expect(report.transactionsAdded, 3);
      expect(report.transactionsSkipped, 0);

      // Every restored transaction must point at a category that exists, and
      // at the right one by name.
      final joined = await other
          .customSelect(
            'SELECT c.name AS name, t.amount_minor AS amt FROM transactions t '
            'JOIN categories c ON c.id = t.category_id ORDER BY t.amount_minor',
          )
          .get();
      expect(joined, hasLength(3));
      expect(joined.map((r) => r.read<String>('name')).toSet(), {
        'Groceries',
        'Rent',
      });

      // Matching by name rather than id means "Groceries" was reused, not
      // duplicated.
      final groceries = await (other.select(
        other.categories,
      )..where((c) => c.name.equals('Groceries'))).get();
      expect(groceries, hasLength(1));
    });

    test('a genuinely different transaction on the same day is kept', () async {
      await seed();
      final read = await service.inspect(await service.buildArchive());

      // Same day and category as an existing row but a different amount.
      final altered = BackupPayload(
        categories: read.payload.categories,
        recurringRules: const [],
        transactions: [
          {
            ...read.payload.transactions.first,
            'id': 999,
            'amount_minor': 555,
            'recurring_rule_id': null,
          },
        ],
        budgets: const [],
        settings: const [],
      );
      final report = await service.restore(altered, mode: RestoreMode.merge);
      expect(report.transactionsAdded, 1);
      expect(report.transactionsSkipped, 0);
      expect(await db.select(db.transactions).get(), hasLength(4));
    });

    test('merge leaves existing budgets alone', () async {
      await seed();
      final read = await service.inspect(await service.buildArchive());
      final before = await db.select(db.budgets).get();

      await service.restore(read.payload, mode: RestoreMode.merge);

      final after = await db.select(db.budgets).get();
      expect(after, hasLength(before.length));
      expect(after.single.amountMinor, Money(45000));
    });
  });
}
