import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';

import '../../core/day.dart';
import '../../core/money.dart';
import '../../domain/entities/enums.dart';
import '../db/database.dart';
import 'backup_format.dart';

/// How an archive should be applied to the existing database.
enum RestoreMode {
  /// Everything currently stored is discarded and replaced by the archive.
  replace,

  /// The archive is added to what is already there, skipping anything that
  /// looks like it is already present.
  merge;

  String get label => switch (this) {
    RestoreMode.replace => 'Replace everything',
    RestoreMode.merge => 'Merge with existing',
  };
}

/// What a restore did, so the user can be told rather than left guessing.
class RestoreReport {
  final RestoreMode mode;
  final int categoriesAdded;
  final int transactionsAdded;
  final int transactionsSkipped;
  final int budgetsAdded;
  final int recurringAdded;

  const RestoreReport({
    required this.mode,
    this.categoriesAdded = 0,
    this.transactionsAdded = 0,
    this.transactionsSkipped = 0,
    this.budgetsAdded = 0,
    this.recurringAdded = 0,
  });

  String get summary {
    final parts = <String>[
      '$transactionsAdded transactions',
      if (categoriesAdded > 0) '$categoriesAdded categories',
      if (budgetsAdded > 0) '$budgetsAdded budgets',
      if (recurringAdded > 0) '$recurringAdded recurring',
    ];
    final skipped = transactionsSkipped > 0
        ? ' · $transactionsSkipped duplicate${transactionsSkipped == 1 ? "" : "s"} skipped'
        : '';
    return 'Restored ${parts.join(", ")}$skipped';
  }
}

/// Exports and restores the whole database.
class BackupService {
  final SpendDatabase _db;
  final String appVersion;

  BackupService(this._db, {this.appVersion = 'dev'});

  static const fileExtension = 'spendbak';

  // -------------------------------------------------------------- exporting

  Future<BackupPayload> _collect() async {
    final categories = await _db.select(_db.categories).get();
    final recurring = await _db.select(_db.recurringRules).get();
    final transactions = await _db.select(_db.transactions).get();
    final budgets = await _db.select(_db.budgets).get();
    final settings = await _db.select(_db.appSettings).get();

    return BackupPayload(
      categories: [
        for (final c in categories)
          {
            'id': c.id,
            'name': c.name,
            'icon_name': c.iconName,
            'color_value': c.colorValue,
            'parent_id': c.parentId,
            'kind': c.kind.name,
            'is_archived': c.isArchived,
            'sort_order': c.sortOrder,
          },
      ],
      recurringRules: [
        for (final r in recurring)
          {
            'id': r.id,
            'label': r.label,
            // Minor units, matching storage. Writing "10.99" would reintroduce
            // the floating-point rounding the whole app avoids.
            'amount_minor': r.amountMinor.minor,
            'category_id': r.categoryId,
            'cadence': r.cadence.name,
            'next_due_on': r.nextDueOn.iso,
            'is_active': r.isActive,
          },
      ],
      transactions: [
        for (final t in transactions)
          {
            'id': t.id,
            'amount_minor': t.amountMinor.minor,
            'category_id': t.categoryId,
            'occurred_on': t.occurredOn.iso,
            'note': t.note,
            'merchant': t.merchant,
            'payment_method': t.paymentMethod,
            'recurring_rule_id': t.recurringRuleId,
            'created_at': t.createdAt.toUtc().toIso8601String(),
            'updated_at': t.updatedAt.toUtc().toIso8601String(),
          },
      ],
      budgets: [
        for (final b in budgets)
          {
            'id': b.id,
            'category_id': b.categoryId,
            'period': b.period.name,
            'amount_minor': b.amountMinor.minor,
            'starts_on': b.startsOn.iso,
            'ends_on': b.endsOn?.iso,
          },
      ],
      settings: [
        for (final s in settings) {'key': s.key, 'value': s.value},
      ],
    );
  }

  /// Builds a complete archive in memory.
  Future<Uint8List> buildArchive() async {
    final payload = await _collect();
    final dataBytes = encodePayload(payload);

    final manifest = BackupManifest(
      formatVersion: BackupManifest.currentFormatVersion,
      schemaVersion: _db.schemaVersion,
      appVersion: appVersion,
      exportedAt: DateTime.now(),
      dataChecksum: checksumOf(dataBytes),
      counts: payload.counts,
    );
    final manifestBytes = Uint8List.fromList(
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
      ),
    );

    final archive = Archive()
      ..addFile(
        ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
      )
      ..addFile(ArchiveFile('data.json', dataBytes.length, dataBytes));

    final encoded = ZipEncoder().encode(archive);
    return Uint8List.fromList(encoded);
  }

  Future<File> writeArchiveTo(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(await buildArchive(), flush: true);
    return file;
  }

  /// A filename carrying the date, so a folder of backups sorts usefully.
  static String suggestedFileName([DateTime? now]) {
    final d = now ?? DateTime.now();
    final stamp =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    return 'spend-$stamp.$fileExtension';
  }

  // -------------------------------------------------------------- inspecting

  /// Reads and validates an archive without touching the database.
  ///
  /// Always call this before [restore] so a corrupt or incompatible file is
  /// rejected while the live data is still untouched.
  Future<({BackupManifest manifest, BackupPayload payload})> inspect(
    Uint8List archiveBytes,
  ) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(archiveBytes);
    } catch (_) {
      throw const BackupFormatException(
        'This file could not be opened as a Spend backup.',
      );
    }

    ArchiveFile? entry(String name) {
      for (final f in archive.files) {
        if (f.name == name) return f;
      }
      return null;
    }

    final manifestFile = entry('manifest.json');
    final dataFile = entry('data.json');
    if (manifestFile == null || dataFile == null) {
      throw const BackupFormatException(
        'This archive is missing its manifest or data — it may not be a Spend '
        'backup.',
      );
    }

    final manifest = BackupManifest.fromJson(
      jsonDecode(utf8.decode(manifestFile.content as List<int>))
          as Map<String, Object?>,
    );
    manifest.assertReadable(currentSchemaVersion: _db.schemaVersion);

    final dataBytes = Uint8List.fromList(dataFile.content as List<int>);
    verifyChecksum(manifest, dataBytes);

    final payload = BackupPayload.fromJson(
      jsonDecode(utf8.decode(dataBytes)) as Map<String, Object?>,
    );

    // The checksum covers data.json but not the manifest, so the counts shown
    // in the restore dialog are unverified on their own. That dialog is where
    // an irreversible "Replace everything" gets chosen, so a manifest claiming
    // "0 transactions" over a payload holding hundreds must not be possible.
    final actual = payload.counts;
    for (final entry in manifest.counts.entries) {
      final real = actual[entry.key];
      if (real != null && real != entry.value) {
        throw BackupFormatException(
          'This backup is inconsistent: the manifest says ${entry.value} '
          '${entry.key} but it contains $real. Nothing has been changed.',
        );
      }
    }

    return (manifest: manifest, payload: payload);
  }

  // --------------------------------------------------------------- restoring

  /// Applies a validated payload.
  ///
  /// Runs inside one transaction, so a failure part way through leaves the
  /// database exactly as it was rather than half-imported.
  Future<RestoreReport> restore(
    BackupPayload payload, {
    required RestoreMode mode,
  }) => _db.transaction(() async {
    return switch (mode) {
      RestoreMode.replace => _restoreReplacing(payload),
      RestoreMode.merge => _restoreMerging(payload),
    };
  });

  Future<RestoreReport> _restoreReplacing(BackupPayload payload) async {
    // Children before parents, or the foreign keys refuse the deletes.
    await _db.delete(_db.transactions).go();
    await _db.delete(_db.budgets).go();
    await _db.delete(_db.recurringRules).go();
    await _db.delete(_db.categories).go();
    await _db.delete(_db.appSettings).go();

    // Ids are preserved on replace, so every reference in the archive stays
    // valid without remapping.
    for (final c in payload.categories) {
      await _db
          .into(_db.categories)
          .insert(_categoryRow(c), mode: InsertMode.insertOrReplace);
    }
    for (final r in payload.recurringRules) {
      await _db
          .into(_db.recurringRules)
          .insert(_recurringRow(r), mode: InsertMode.insertOrReplace);
    }
    for (final t in payload.transactions) {
      await _db
          .into(_db.transactions)
          .insert(_transactionRow(t), mode: InsertMode.insertOrReplace);
    }
    for (final b in payload.budgets) {
      await _db
          .into(_db.budgets)
          .insert(_budgetRow(b), mode: InsertMode.insertOrReplace);
    }
    for (final s in payload.settings) {
      await _db
          .into(_db.appSettings)
          .insert(
            AppSettingsCompanion.insert(
              key: s['key'] as String,
              value: s['value'] as String? ?? '',
            ),
            mode: InsertMode.insertOrReplace,
          );
    }

    return RestoreReport(
      mode: RestoreMode.replace,
      categoriesAdded: payload.categories.length,
      transactionsAdded: payload.transactions.length,
      budgetsAdded: payload.budgets.length,
      recurringAdded: payload.recurringRules.length,
    );
  }

  Future<RestoreReport> _restoreMerging(BackupPayload payload) async {
    // Categories are matched by name rather than id, because the same
    // "Groceries" on two machines will almost certainly have different ids.
    // Everything referencing a category is remapped through this table.
    final existing = await _db.select(_db.categories).get();
    final byName = {for (final c in existing) c.name.toLowerCase(): c.id};
    final categoryIdMap = <int, int>{};
    var categoriesAdded = 0;

    for (final c in payload.categories) {
      final oldId = (c['id'] as num).toInt();
      final name = (c['name'] as String).trim();
      final match = byName[name.toLowerCase()];
      if (match != null) {
        categoryIdMap[oldId] = match;
      } else {
        // Inserted without a parent for now; parents are wired up in a second
        // pass below, once every archive id has a local counterpart.
        final newId = await _db
            .into(_db.categories)
            .insert(_categoryRow(c, withId: false, dropParent: true));
        categoryIdMap[oldId] = newId;
        byName[name.toLowerCase()] = newId;
        categoriesAdded++;
      }
    }

    // Second pass for subcategory parents.
    //
    // The archive's ids mean nothing here, so a parent reference has to be
    // translated through the id map. Carried over unmapped it would point at
    // an unrelated category or fail the foreign key. Two passes rather than
    // one because a child can appear before its parent in the archive.
    for (final c in payload.categories) {
      final archiveParent = (c['parent_id'] as num?)?.toInt();
      if (archiveParent == null) continue;

      final localId = categoryIdMap[(c['id'] as num).toInt()];
      final localParent = categoryIdMap[archiveParent];
      if (localId == null || localParent == null) continue;
      // Never let a category parent itself: two archive ids can collapse onto
      // one local category when both match the same name.
      if (localId == localParent) continue;

      await (_db.update(_db.categories)..where((t) => t.id.equals(localId)))
          .write(CategoriesCompanion(parentId: Value(localParent)));
    }

    // Recurring rules dedupe on label, amount and category, the same way
    // transactions do. Without it, merging one backup twice left two active
    // copies of every subscription — and each copy would go on to log the
    // charge again every month.
    final existingRules = await _db.select(_db.recurringRules).get();
    String ruleKey(String label, int amountMinor, int categoryId) =>
        '${label.trim().toLowerCase()}|$amountMinor|$categoryId';
    final rulesByKey = {
      for (final r in existingRules)
        ruleKey(r.label, r.amountMinor.minor, r.categoryId): r.id,
    };

    final recurringIdMap = <int, int>{};
    var recurringAdded = 0;
    for (final r in payload.recurringRules) {
      final oldId = (r['id'] as num).toInt();
      final categoryId = categoryIdMap[(r['category_id'] as num).toInt()];
      if (categoryId == null) continue;

      final key = ruleKey(
        r['label'] as String,
        (r['amount_minor'] as num).toInt(),
        categoryId,
      );
      final existing = rulesByKey[key];
      if (existing != null) {
        // Already present: reuse it so transactions still link correctly.
        recurringIdMap[oldId] = existing;
        continue;
      }

      final newId = await _db
          .into(_db.recurringRules)
          .insert(_recurringRow(r, withId: false, categoryId: categoryId));
      rulesByKey[key] = newId;
      recurringIdMap[oldId] = newId;
      recurringAdded++;
    }

    // Duplicate detection. Ids cannot be used — a merge is precisely the case
    // where two databases assigned different ids to the same purchase — so
    // identity is the natural key a human would use.
    final current = await _db.select(_db.transactions).get();
    final seen = <String>{
      for (final t in current)
        _transactionKey(
          amountMinor: t.amountMinor.minor,
          occurredOn: t.occurredOn.iso,
          categoryId: t.categoryId,
          merchant: t.merchant,
          note: t.note,
        ),
    };

    var added = 0;
    var skipped = 0;
    for (final t in payload.transactions) {
      final categoryId = categoryIdMap[(t['category_id'] as num).toInt()];
      if (categoryId == null) continue;

      final key = _transactionKey(
        amountMinor: (t['amount_minor'] as num).toInt(),
        occurredOn: t['occurred_on'] as String,
        categoryId: categoryId,
        merchant: t['merchant'] as String? ?? '',
        note: t['note'] as String? ?? '',
      );
      if (!seen.add(key)) {
        skipped++;
        continue;
      }

      final oldRuleId = (t['recurring_rule_id'] as num?)?.toInt();
      await _db
          .into(_db.transactions)
          .insert(
            _transactionRow(
              t,
              withId: false,
              categoryId: categoryId,
              recurringRuleId: oldRuleId == null
                  ? null
                  : recurringIdMap[oldRuleId],
            ),
          );
      added++;
    }

    // Budgets are not merged. A limit is a current intention, not history, and
    // silently combining two machines' limits would produce a figure the user
    // never chose. Existing budgets win; the archive's are ignored.
    return RestoreReport(
      mode: RestoreMode.merge,
      categoriesAdded: categoriesAdded,
      transactionsAdded: added,
      transactionsSkipped: skipped,
      recurringAdded: recurringAdded,
    );
  }

  static String _transactionKey({
    required int amountMinor,
    required String occurredOn,
    required int categoryId,
    required String merchant,
    required String note,
  }) =>
      '$occurredOn|$amountMinor|$categoryId|'
      '${merchant.trim().toLowerCase()}|${note.trim().toLowerCase()}';

  // ------------------------------------------------------------ row builders

  CategoriesCompanion _categoryRow(
    Map<String, Object?> c, {
    bool withId = true,

    /// Merge inserts without a parent and fixes them up afterwards, because
    /// the archive's parent id is meaningless against a different database.
    bool dropParent = false,
  }) => CategoriesCompanion.insert(
    id: withId ? Value((c['id'] as num).toInt()) : const Value.absent(),
    name: c['name'] as String,
    iconName: Value(c['icon_name'] as String? ?? 'tag'),
    colorValue: (c['color_value'] as num).toInt(),
    kind: _enumByName(
      c['kind'] as String?,
      CategoryKind.values,
      CategoryKind.expense,
    ),
    parentId: Value(dropParent ? null : (c['parent_id'] as num?)?.toInt()),
    isArchived: Value(c['is_archived'] as bool? ?? false),
    sortOrder: Value((c['sort_order'] as num?)?.toInt() ?? 0),
  );

  RecurringRulesCompanion _recurringRow(
    Map<String, Object?> r, {
    bool withId = true,
    int? categoryId,
  }) => RecurringRulesCompanion.insert(
    id: withId ? Value((r['id'] as num).toInt()) : const Value.absent(),
    label: r['label'] as String,
    amountMinor: Money((r['amount_minor'] as num).toInt()),
    categoryId: categoryId ?? (r['category_id'] as num).toInt(),
    cadence: _enumByName(
      r['cadence'] as String?,
      Cadence.values,
      Cadence.monthly,
    ),
    nextDueOn: Day.parse(r['next_due_on'] as String),
    isActive: Value(r['is_active'] as bool? ?? true),
  );

  TransactionsCompanion _transactionRow(
    Map<String, Object?> t, {
    bool withId = true,
    int? categoryId,
    int? recurringRuleId,
  }) => TransactionsCompanion.insert(
    id: withId ? Value((t['id'] as num).toInt()) : const Value.absent(),
    amountMinor: Money((t['amount_minor'] as num).toInt()),
    categoryId: categoryId ?? (t['category_id'] as num).toInt(),
    occurredOn: Day.parse(t['occurred_on'] as String),
    note: Value(t['note'] as String? ?? ''),
    merchant: Value(t['merchant'] as String? ?? ''),
    paymentMethod: Value(t['payment_method'] as String?),
    recurringRuleId: Value(
      withId ? (t['recurring_rule_id'] as num?)?.toInt() : recurringRuleId,
    ),
    createdAt: Value(
      DateTime.tryParse(t['created_at'] as String? ?? '') ?? DateTime.now(),
    ),
    updatedAt: Value(
      DateTime.tryParse(t['updated_at'] as String? ?? '') ?? DateTime.now(),
    ),
  );

  BudgetsCompanion _budgetRow(Map<String, Object?> b, {bool withId = true}) =>
      BudgetsCompanion.insert(
        id: withId ? Value((b['id'] as num).toInt()) : const Value.absent(),
        categoryId: Value((b['category_id'] as num?)?.toInt()),
        period: _enumByName(
          b['period'] as String?,
          BudgetPeriod.values,
          BudgetPeriod.monthly,
        ),
        amountMinor: Money((b['amount_minor'] as num).toInt()),
        startsOn: Day.parse(b['starts_on'] as String),
        endsOn: Value(
          b['ends_on'] == null ? null : Day.parse(b['ends_on'] as String),
        ),
      );

  /// Resolves an enum by name, falling back rather than throwing.
  ///
  /// A backup from a build that had an extra enum value should still restore
  /// its transactions; losing one field's precision beats refusing the whole
  /// archive.
  static T _enumByName<T extends Enum>(
    String? name,
    List<T> values,
    T fallback,
  ) {
    if (name == null) return fallback;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }
}
