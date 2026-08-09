import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'backup_service.dart';

/// Rolling unattended snapshots.
///
/// Manual exports only protect people who remember to make them. The failure
/// this guards against is the quiet one: a bad import, an accidental bulk
/// delete, or a corrupted file noticed weeks later. Keeping a short history of
/// automatic snapshots means there is always something to fall back to, without
/// the user having done anything.
///
/// Snapshots live beside the database in Application Support rather than in
/// Documents, so they are not something the user trips over — but they are
/// plain files in a discoverable folder, not hidden state.
class AutoBackup {
  final BackupService _service;

  AutoBackup(this._service);

  /// How many snapshots to retain. Ten at roughly one a day covers the window
  /// in which a mistake is still likely to be noticed, without letting a large
  /// database quietly consume disk space.
  static const keepCount = 10;

  /// Minimum gap between snapshots. Launching the app five times in an
  /// afternoon should not burn through the whole history.
  static const minInterval = Duration(hours: 12);

  static const _prefix = 'auto-';

  Future<Directory> directory() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/backups');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Existing snapshots, newest first.
  ///
  /// Returns empty rather than throwing when the folder cannot be read. Being
  /// unable to *list* the safety net is not itself an error worth showing the
  /// user, and the same tolerance keeps this callable from a widget test where
  /// no platform directory exists.
  Future<List<File>> snapshots() async {
    try {
      final dir = await directory();
      final files = await dir
          .list()
          .where(
            (e) =>
                e is File &&
                e.uri.pathSegments.last.startsWith(_prefix) &&
                e.path.endsWith('.${BackupService.fileExtension}'),
          )
          .cast<File>()
          .toList();

      // Sorted by name, which is why the timestamp is zero-padded and
      // most-significant-first — it makes lexical order match chronological.
      files.sort((a, b) => b.path.compareTo(a.path));
      return files;
    } on Object {
      return const [];
    }
  }

  /// Writes a snapshot if enough time has passed, and returns it.
  ///
  /// Returns null when one was written recently. Failures are swallowed
  /// deliberately: a snapshot is a safety net, and being unable to write one
  /// must never stop the app from starting.
  Future<File?> snapshotIfDue({DateTime? now}) async {
    try {
      final existing = await snapshots();
      final at = now ?? DateTime.now();

      if (existing.isNotEmpty) {
        final last = await existing.first.lastModified();
        if (at.difference(last) < minInterval) return null;
      }

      final file = await _write(at);
      await _prune();
      return file;
    } on Object {
      return null;
    }
  }

  /// Writes a snapshot unconditionally, for "back up now".
  Future<File> snapshotNow({DateTime? now}) async {
    final file = await _write(now ?? DateTime.now());
    await _prune();
    return file;
  }

  Future<File> _write(DateTime at) async {
    final dir = await directory();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${at.year}${two(at.month)}${two(at.day)}-${two(at.hour)}${two(at.minute)}';
    return _service.writeArchiveTo(
      '${dir.path}/$_prefix$stamp.${BackupService.fileExtension}',
    );
  }

  /// Deletes the oldest snapshots beyond [keepCount].
  Future<void> _prune() async {
    final files = await snapshots();
    if (files.length <= keepCount) return;
    for (final file in files.skip(keepCount)) {
      try {
        await file.delete();
      } on Object {
        // A snapshot we cannot delete is not worth failing over.
      }
    }
  }
}
