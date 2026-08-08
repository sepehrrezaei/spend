import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/backup/backup_format.dart';
import '../../data/backup/backup_service.dart';
import 'csv_import_dialog.dart';

/// Backup, restore and interchange.
class DataSection extends ConsumerStatefulWidget {
  const DataSection({super.key});

  @override
  ConsumerState<DataSection> createState() => _DataSectionState();
}

class _DataSectionState extends ConsumerState<DataSection> {
  bool _busy = false;

  void _say(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on BackupFormatException catch (e) {
      _say(e.message, error: true);
    } on Object catch (e) {
      _say('Something went wrong: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportBackup() => _guard(() async {
    final location = await getSaveLocation(
      suggestedName: BackupService.suggestedFileName(),
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Spend backup',
          extensions: [BackupService.fileExtension],
        ),
      ],
    );
    if (location == null) return; // user cancelled

    final file = await ref
        .read(backupServiceProvider)
        .writeArchiveTo(location.path);
    final size = await file.length();
    _say('Backup saved (${_readableSize(size)})');
  });

  Future<void> _restoreBackup() => _guard(() async {
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Spend backup',
          extensions: [BackupService.fileExtension, 'zip'],
        ),
      ],
    );
    if (picked == null) return;

    final service = ref.read(backupServiceProvider);
    // Validated before anything is written, so a corrupt file cannot damage
    // the live database.
    final read = await service.inspect(await picked.readAsBytes());

    if (!mounted) return;
    final mode = await showDialog<RestoreMode>(
      context: context,
      builder: (_) => _RestoreConfirmDialog(manifest: read.manifest),
    );
    if (mode == null) return;

    final report = await service.restore(read.payload, mode: mode);
    ref.invalidate(autoSnapshotsProvider);
    _say(report.summary);
  });

  Future<void> _exportCsv() => _guard(() async {
    final location = await getSaveLocation(
      suggestedName: 'spend-export.csv',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'CSV', extensions: ['csv']),
      ],
    );
    if (location == null) return;

    final records = await ref
        .read(transactionRepositoryProvider)
        .allForExport();
    final text = csvServiceProvider.export([
      for (final r in records)
        (
          date: r.occurredOn,
          amount: r.amount,
          category: r.categoryName,
          merchant: r.merchant,
          note: r.note,
        ),
    ]);
    await File(location.path).writeAsString(text, flush: true);
    _say('Exported ${records.length} transactions');
  });

  Future<void> _importCsv() => _guard(() async {
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'CSV', extensions: ['csv', 'txt']),
      ],
    );
    if (picked == null) return;

    final text = await picked.readAsString();
    final table = csvServiceProvider.parseTable(text);
    if (table.isEmpty) {
      _say('That file has no rows to import', error: true);
      return;
    }
    if (!mounted) return;
    await showCsvImportDialog(context, table: table, fileName: picked.name);
  });

  Future<void> _snapshotNow() => _guard(() async {
    final file = await ref.read(autoBackupProvider).snapshotNow();
    ref.invalidate(autoSnapshotsProvider);
    _say('Snapshot saved: ${file.uri.pathSegments.last}');
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshots = ref.watch(autoSnapshotsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Your data', style: theme.textTheme.titleSmall),
            const Spacer(),
            if (_busy)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              _Action(
                icon: Icons.save_alt,
                title: 'Save a backup',
                subtitle:
                    'One .spendbak file with everything in it, checksummed.',
                onTap: _busy ? null : _exportBackup,
              ),
              const Divider(height: 1),
              _Action(
                icon: Icons.restore,
                title: 'Restore from a backup',
                subtitle:
                    'Verified before anything is changed. You choose whether '
                    'to replace or merge.',
                onTap: _busy ? null : _restoreBackup,
              ),
              const Divider(height: 1),
              _Action(
                icon: Icons.upload_file,
                title: 'Import a bank CSV',
                subtitle:
                    'Columns are detected automatically; you confirm before '
                    'anything is added.',
                onTap: _busy ? null : _importCsv,
              ),
              const Divider(height: 1),
              _Action(
                icon: Icons.table_view,
                title: 'Export to CSV',
                subtitle:
                    'For spreadsheets. Not a backup — no settings or budgets.',
                onTap: _busy ? null : _exportCsv,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Text('Automatic snapshots', style: theme.textTheme.titleSmall),
            const Spacer(),
            TextButton(
              onPressed: _busy ? null : _snapshotNow,
              child: const Text('Snapshot now'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: snapshots.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('Could not list snapshots: $e'),
              data: (files) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    files.isEmpty
                        ? 'None yet. One is taken automatically when you open '
                              'the app, at most twice a day.'
                        : '${files.length} kept, newest first. Taken '
                              'automatically on launch, at most twice a day.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (files.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    for (final f in files.take(5))
                      Text(
                        f.uri.pathSegments.last,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _readableSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _Action({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, size: 20),
      title: Text(title, style: theme.textTheme.bodyMedium),
      subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: onTap,
      enabled: onTap != null,
    );
  }
}

/// Shows what is in an archive and asks how to apply it.
///
/// Deliberately a blocking decision rather than a default: replacing is
/// destructive and merging is not, and guessing wrong either way loses data or
/// creates duplicates.
class _RestoreConfirmDialog extends StatelessWidget {
  final BackupManifest manifest;

  const _RestoreConfirmDialog({required this.manifest});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counts = manifest.counts;

    return AlertDialog(
      title: const Text('Restore this backup?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Taken ${manifest.exportedAt.toLocal()}'.split('.').first,
              style: theme.textTheme.bodySmall,
            ),
            Text(
              'App version ${manifest.appVersion} · schema v${manifest.schemaVersion}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Contains ${counts['transactions'] ?? 0} transactions, '
              '${counts['categories'] ?? 0} categories, '
              '${counts['budgets'] ?? 0} budgets.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Text(
              'Replacing discards everything currently stored. Merging keeps '
              'what you have and adds only what is missing, matching '
              'categories by name and skipping duplicate transactions.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(RestoreMode.merge),
          child: const Text('Merge'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(RestoreMode.replace),
          child: const Text('Replace everything'),
        ),
      ],
    );
  }
}
