import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/ai_providers.dart';
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
  late final TextEditingController _host;
  late final TextEditingController _pullModel;
  String? _hostError;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController();
    _pullModel = TextEditingController(text: OllamaProvider.defaultModel);
  }

  @override
  void dispose() {
    _host.dispose();
    _pullModel.dispose();
    super.dispose();
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
    final pull = ref.watch(modelPullProvider);

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
                                    DropdownMenuItem(
                                      value: m,
                                      child: _ModelLabel(m),
                                    ),
                                ],
                                onChanged: (v) => v == null
                                    ? null
                                    : db.setSetting(SettingKeys.ollamaModel, v),
                              ),
                            ],
                            if (a.reachable) ...[
                              const SizedBox(height: 12),
                              _PullSection(
                                controller: _pullModel,
                                pullState: pull,
                                onPull: () => ref
                                    .read(modelPullProvider.notifier)
                                    .pull(_pullModel.text),
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

/// Displays the model name with a "recommended" badge for the default model.
class _ModelLabel extends StatelessWidget {
  final String name;
  const _ModelLabel(this.name);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRecommended = name == OllamaProvider.defaultModel;
    return Row(
      children: [
        Expanded(child: Text(name)),
        if (isRecommended) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'recommended',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The pull-model row: a text field pre-filled with the recommended model, a
/// Pull button, and a progress bar + status line while the download runs.
class _PullSection extends StatelessWidget {
  final TextEditingController controller;
  final ModelPullState pullState;
  final VoidCallback onPull;

  const _PullSection({
    required this.controller,
    required this.pullState,
    required this.onPull,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPulling = pullState.isPulling;
    final isDone = pullState.status == PullStatus.done;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !isPulling,
                decoration: const InputDecoration(
                  labelText: 'Pull a model',
                  hintText: OllamaProvider.defaultModel,
                  isDense: true,
                  helperText: '~2 GB · comfortable on 16 GB RAM',
                ),
                onSubmitted: (_) => onPull(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: isPulling ? null : onPull,
              child: const Text('Pull'),
            ),
          ],
        ),
        if (isPulling || isDone || pullState.status == PullStatus.failed) ...[
          const SizedBox(height: 8),
          if (isPulling)
            LinearProgressIndicator(value: pullState.fraction)
          else
            const SizedBox(height: 4),
          const SizedBox(height: 4),
          Text(
            pullState.error ??
                (isDone ? '✓ Done' : pullState.statusMessage),
            style: theme.textTheme.bodySmall?.copyWith(
              color: pullState.error != null
                  ? theme.colorScheme.error
                  : isDone
                  ? theme.colorScheme.decrease
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
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
            'To start Ollama, from the project folder:',
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
