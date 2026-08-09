/// The on-disk backup format.
///
/// A `.spendbak` file is a zip holding two entries:
///
///   manifest.json  what this archive is, and a checksum of the payload
///   data.json      every row, as plain JSON
///
/// JSON rather than a copy of the SQLite file. A raw database copy is easier
/// to produce but almost impossible to restore into a *different* schema
/// version, and it cannot be inspected or hand-repaired. Plain text means a
/// backup taken today is still readable by a future version that has since
/// migrated, and readable by you in a text editor if this app ever stops
/// working — which is the entire point of owning your own data.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// Raised when an archive cannot be trusted. Carries a message meant to be
/// shown to the user, not logged.
class BackupFormatException implements Exception {
  final String message;
  const BackupFormatException(this.message);

  @override
  String toString() => message;
}

@immutable
class BackupManifest {
  /// The layout of the archive itself. Bumped only if the envelope changes
  /// shape, which is separate from the database schema evolving.
  static const currentFormatVersion = 1;

  final int formatVersion;

  /// The Drift schema version the payload was written from. An older value is
  /// migratable; a newer one means this build cannot safely read it.
  final int schemaVersion;

  final String appVersion;
  final DateTime exportedAt;

  /// SHA-256 of the exact `data.json` bytes.
  final String dataChecksum;

  /// Row counts per table, so the user can be told what they are about to
  /// restore before anything is touched.
  final Map<String, int> counts;

  const BackupManifest({
    required this.formatVersion,
    required this.schemaVersion,
    required this.appVersion,
    required this.exportedAt,
    required this.dataChecksum,
    required this.counts,
  });

  Map<String, Object?> toJson() => {
    'format_version': formatVersion,
    'schema_version': schemaVersion,
    'app_version': appVersion,
    'exported_at': exportedAt.toUtc().toIso8601String(),
    'data_checksum': dataChecksum,
    'counts': counts,
  };

  factory BackupManifest.fromJson(Map<String, Object?> json) {
    Object? need(String key) {
      final v = json[key];
      if (v == null) {
        throw BackupFormatException(
          'This file is missing "$key" — it may not be a Spend backup.',
        );
      }
      return v;
    }

    return BackupManifest(
      formatVersion: (need('format_version') as num).toInt(),
      schemaVersion: (need('schema_version') as num).toInt(),
      appVersion: need('app_version') as String,
      exportedAt:
          DateTime.tryParse(need('exported_at') as String) ?? DateTime.now(),
      dataChecksum: need('data_checksum') as String,
      counts: {
        for (final e in (json['counts'] as Map? ?? {}).entries)
          e.key as String: (e.value as num).toInt(),
      },
    );
  }

  int get totalRows => counts.values.fold(0, (a, b) => a + b);

  /// Checks this archive can be read by the running build.
  ///
  /// Deliberately strict about the future and lenient about the past: an older
  /// backup can be migrated forward, but a backup written by a newer version
  /// may contain columns this build would silently drop, so it is refused
  /// rather than partially imported.
  void assertReadable({required int currentSchemaVersion}) {
    if (formatVersion > currentFormatVersion) {
      throw BackupFormatException(
        'This backup was written by a newer version of Spend '
        '(format $formatVersion, this build reads $currentFormatVersion). '
        'Update the app and try again.',
      );
    }
    if (schemaVersion > currentSchemaVersion) {
      throw BackupFormatException(
        'This backup comes from a newer database schema '
        '(v$schemaVersion, this build has v$currentSchemaVersion). '
        'Restoring it could lose data, so it has been refused.',
      );
    }
  }
}

/// Everything in the database, as JSON-ready maps.
@immutable
class BackupPayload {
  final List<Map<String, Object?>> categories;
  final List<Map<String, Object?>> recurringRules;
  final List<Map<String, Object?>> transactions;
  final List<Map<String, Object?>> budgets;
  final List<Map<String, Object?>> settings;

  const BackupPayload({
    required this.categories,
    required this.recurringRules,
    required this.transactions,
    required this.budgets,
    required this.settings,
  });

  Map<String, int> get counts => {
    'categories': categories.length,
    'recurring_rules': recurringRules.length,
    'transactions': transactions.length,
    'budgets': budgets.length,
    'settings': settings.length,
  };

  Map<String, Object?> toJson() => {
    // Order matters on restore: parents before the rows referencing them.
    'categories': categories,
    'recurring_rules': recurringRules,
    'transactions': transactions,
    'budgets': budgets,
    'settings': settings,
  };

  factory BackupPayload.fromJson(Map<String, Object?> json) {
    List<Map<String, Object?>> rows(String key) {
      final raw = json[key];
      if (raw == null) return const [];
      if (raw is! List) {
        throw BackupFormatException('"$key" is malformed in this backup.');
      }
      return [
        for (final r in raw)
          if (r is Map)
            {for (final e in r.entries) e.key as String: e.value}
          else
            throw const BackupFormatException(
              'A row in this backup is malformed.',
            ),
      ];
    }

    return BackupPayload(
      categories: rows('categories'),
      recurringRules: rows('recurring_rules'),
      transactions: rows('transactions'),
      budgets: rows('budgets'),
      settings: rows('settings'),
    );
  }
}

/// Canonical JSON encoding for the payload.
///
/// Fixed formatting so the checksum is reproducible: re-encoding the same rows
/// must produce byte-identical output, which it would not if key order or
/// whitespace could vary.
Uint8List encodePayload(BackupPayload payload) =>
    Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson())));

String checksumOf(Uint8List bytes) => sha256.convert(bytes).toString();

/// Verifies the payload matches what the manifest promised.
void verifyChecksum(BackupManifest manifest, Uint8List dataBytes) {
  final actual = checksumOf(dataBytes);
  if (actual != manifest.dataChecksum) {
    throw const BackupFormatException(
      'This backup appears to be corrupted — its contents do not match its '
      'checksum. Nothing has been changed.',
    );
  }
}
