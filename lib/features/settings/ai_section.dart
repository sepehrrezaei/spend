import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/ai_providers.dart';
import '../../ai/ai_provider.dart';
import '../../ai/local_endpoint.dart';
import '../../ai/ollama_provider.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';

/// Configuration for the optional local model.
///
/// Written so that "not connected" reads as a normal state rather than a
/// fault, because it is one — the app is complete without it.
class AiSection extends ConsumerStatefulWidget {
  const AiSection({super.key});

  @override
  ConsumerState<AiSection> createState() => _AiSectionState();
}

class _AiSectionState extends ConsumerState<AiSection> {
  /// The download in flight, if any. Held here rather than in a provider
  /// because it belongs to this screen being open — navigating away should
  /// cancel it, not leave bytes arriving into nothing.
  StreamSubscription<PullProgress>? _pull;
  PullProgress? _progress;
  String? _pulling;
  late final TextEditingController _host;
  String? _hostError;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController();
  }

  @override
  void dispose() {
    _pull?.cancel();
    _host.dispose();
    super.dispose();
  }

  void _startPull(String name) {
    _pull?.cancel();
    setState(() {
      _pulling = name;
      _progress = const PullProgress(status: 'starting');
    });

    final provider = ref.read(aiProviderProvider);
    if (provider is! OllamaProvider) return;

    _pull = provider
        .pullModel(name)
        .listen(
          (p) {
            if (!mounted) return;
            setState(() => _progress = p);
            // Re-probe on success so the picker and the status line pick up the
            // new model without the user pressing Test.
            if (p.isDone) {
              ref.invalidate(aiAvailabilityProvider);
              _finishPull();
            }
            if (p.hasFailed) _finishPull(keepMessage: true);
          },
          onError: (Object e) {
            if (!mounted) return;
            setState(
              () => _progress = PullProgress(status: 'failed', error: '$e'),
            );
            _finishPull(keepMessage: true);
          },
        );
  }

  void _finishPull({bool keepMessage = false}) {
    _pull?.cancel();
    _pull = null;
    setState(() {
      _pulling = null;
      if (!keepMessage) _progress = null;
    });
  }

  void _cancelPull() {
    _pull?.cancel();
    _pull = null;
    setState(() {
      _pulling = null;
      _progress = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final db = ref.watch(databaseProvider);

    final enabled = (ref.watch(aiEnabledProvider).value ?? 'true') == 'true';
    final host =
        ref.watch(ollamaHostProvider).value ?? OllamaProvider.defaultHost;
    final model =
        ref.watch(ollamaModelProvider).value ?? OllamaProvider.defaultModel;
    final availability = ref.watch(aiAvailabilityProvider);

    if (_host.text != host && !_host.selection.isValid) _host.text = host;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Local AI', style: theme.textTheme.titleSmall),
            const SizedBox(width: 8),
            Text(
              'optional',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.outline,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => ref.invalidate(aiAvailabilityProvider),
              icon: const Icon(Icons.refresh, size: 15),
              label: const Text('Test'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                value: enabled,
                onChanged: (v) =>
                    db.setSetting(SettingKeys.ollamaEnabled, '$v'),
                secondary: const Icon(Icons.auto_awesome_outlined, size: 20),
                title: const Text('Use a local model for Insights'),
                subtitle: const Text(
                  'Narrates figures the app has already computed. Never used '
                  'to calculate anything.',
                ),
              ),
              if (enabled) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _host,
                        decoration: InputDecoration(
                          labelText: 'Ollama address',
                          isDense: true,
                          helperText: 'Loopback only — nothing leaves this Mac',
                          errorText: _hostError,
                        ),
                        // Rejected here as well as at the request boundary.
                        // The boundary is what makes the promise true; this is
                        // so a mistyped address says why instead of just
                        // reading as "not connected".
                        onChanged: (_) {
                          if (_hostError != null) {
                            setState(() => _hostError = null);
                          }
                        },
                        onSubmitted: (v) {
                          final problem = LocalEndpoint.describeProblem(v);
                          if (problem != null) {
                            setState(() => _hostError = problem);
                            return;
                          }
                          setState(() => _hostError = null);
                          db.setSetting(SettingKeys.ollamaHost, v.trim());
                          ref.invalidate(aiAvailabilityProvider);
                        },
                      ),
                      const SizedBox(height: 12),
                      availability.when(
                        loading: () => const LinearProgressIndicator(),
                        error: (e, _) => _Status(ok: false, message: '$e'),
                        data: (a) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _Status(
                              ok: a.hasModel,
                              message: a.hasModel
                                  ? 'Connected · ${a.models.length} '
                                        'model${a.models.length == 1 ? "" : "s"} '
                                        'installed'
                                  : a.reason ?? 'Not reachable',
                            ),
                            if (!a.hasModel && _hostError == null) ...[
                              const SizedBox(height: 10),
                              _PullPanel(
                                busyWith: _pulling,
                                progress: _progress,
                                onPull: _startPull,
                                onCancel: _cancelPull,
                              ),
                            ],
                            if (a.models.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              DropdownButtonFormField<String>(
                                initialValue: a.models.contains(model)
                                    ? model
                                    : a.models.first,
                                decoration: const InputDecoration(
                                  labelText: 'Model',
                                  isDense: true,
                                ),
                                items: [
                                  for (final m in a.models)
                                    DropdownMenuItem(value: m, child: Text(m)),
                                ],
                                onChanged: (v) => v == null
                                    ? null
                                    : db.setSetting(SettingKeys.ollamaModel, v),
                              ),
                            ],
                            if (!a.reachable) ...[
                              const SizedBox(height: 10),
                              const _StartHint(),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  final bool ok;
  final String message;

  const _Status({required this.ok, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = ok
        ? theme.colorScheme.decrease
        : theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: colour),
          ),
        ),
      ],
    );
  }
}

class _StartHint extends StatelessWidget {
  const _StartHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Starting Ollama is the one step that has to happen outside the '
            'app — a sandboxed app cannot start a container. From the project '
            'folder:',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            'docker compose up -d',
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'Menlo',
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Offers a model to download, and shows the download happening.
///
/// Only rendered when there is no usable model, because that is the only
/// moment it helps — once a model is installed this is clutter, and the
/// picker above is the thing to use.
class _PullPanel extends StatelessWidget {
  final String? busyWith;
  final PullProgress? progress;
  final ValueChanged<String> onPull;
  final VoidCallback onCancel;

  const _PullPanel({
    required this.busyWith,
    required this.progress,
    required this.onPull,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = busyWith != null;
    final failed = progress?.hasFailed ?? false;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            busy ? 'Downloading $busyWith' : 'Download a model',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 2),
          Text(
            busy
                ? 'This runs against the address above, so nothing leaves '
                      'this Mac.'
                : 'Ollama has to be running first. The download happens '
                      'here — no terminal needed.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),

          if (busy) ...[
            // Null while the server is doing something unmeasurable — a
            // determinate bar frozen at zero reads as broken, an indeterminate
            // one reads as busy, which is the truth.
            LinearProgressIndicator(value: progress?.fraction),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _describe(progress),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton(onPressed: onCancel, child: const Text('Cancel')),
              ],
            ),
          ] else ...[
            for (final m in SuggestedModel.catalogue)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(m.name, style: theme.textTheme.bodyMedium),
                              const SizedBox(width: 6),
                              Text(
                                m.size,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              if (m.recommended) ...[
                                const SizedBox(width: 6),
                                Text(
                                  'recommended',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          Text(
                            m.note,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () => onPull(m.name),
                      child: const Text('Get'),
                    ),
                  ],
                ),
              ),
          ],

          if (failed) ...[
            const SizedBox(height: 6),
            Text(
              progress!.error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Ollama reports per-layer bytes, so this says which step is happening
  /// rather than implying a total the server never gives.
  static String _describe(PullProgress? p) {
    if (p == null) return '';
    if (p.totalBytes <= 0) return p.status;
    final done = (p.completedBytes / 1024 / 1024).round();
    final total = (p.totalBytes / 1024 / 1024).round();
    return '${p.status} · $done of $total MB';
  }
}
