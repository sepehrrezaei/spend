import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/chat_providers.dart';
import '../../ai/chat_service.dart';
import '../../ai/chat_tools.dart';
import '../shell/content_width.dart';

/// Ask questions about your own spending.
///
/// The model has no access to transactions. It chooses a query, the app runs
/// it, and the exact results come back for it to phrase — and those results
/// are shown under every answer, so a figure can be checked rather than
/// trusted.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    ref.read(chatConversationProvider.notifier).ask(text);
    _focus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatConversationProvider);
    final service = ref.watch(chatServiceProvider);
    final busy = ref.watch(chatConversationProvider.notifier).isBusy;

    ref.listen(chatConversationProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ask'),
        centerTitle: false,
        actions: [
          if (messages.isNotEmpty)
            TextButton(
              onPressed: busy
                  ? null
                  : ref.read(chatConversationProvider.notifier).clear,
              child: const Text('Clear'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ContentWidth(
              maxWidth: 760,
              child: service == null
                  ? const _Unavailable()
                  : messages.isEmpty
                  ? _Suggestions(
                      onPick: (q) {
                        _input.text = q;
                        _send();
                      },
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      itemCount: messages.length,
                      itemBuilder: (context, i) =>
                          _Bubble(message: messages[i]),
                    ),
            ),
          ),
          if (service != null)
            ContentWidth(
              maxWidth: 760,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        focusNode: _focus,
                        autofocus: true,
                        enabled: !busy,
                        // Single line deliberately. A multiline field swallows
                        // Enter as a newline and never fires onSubmitted, so
                        // the only way to send would be the button — and
                        // questions here are one sentence anyway.
                        maxLines: 1,
                        decoration: InputDecoration(
                          hintText: busy
                              ? 'Looking it up…'
                              : 'Ask about your spending',
                          isDense: true,
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: busy ? null : _send,
                      icon: const Icon(Icons.arrow_upward, size: 18),
                      tooltip: 'Ask',
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;

  const _Bubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (message.fromUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, left: 60),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            message.text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16, right: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.evidence.isNotEmpty) ...[
            _Evidence(results: message.evidence),
            const SizedBox(height: 8),
          ],
          if (message.error != null)
            Text(
              message.error!,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            )
          else if (message.text.isEmpty && message.streaming)
            Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  message.evidence.isEmpty
                      ? 'Working out which figures to look up…'
                      : 'Writing the answer…',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            )
          else
            SelectableText(
              message.text.trim(),
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
        ],
      ),
    );
  }
}

/// The queries behind an answer.
///
/// Shown by default rather than hidden behind a disclosure. The point of the
/// tool design is that answers are checkable, which only helps if the check is
/// in front of you.
class _Evidence extends StatelessWidget {
  final List<ToolResult> results;

  const _Evidence({required this.results});

  static const _labels = {
    'list_categories': 'Looked up your categories',
    'total_spent': 'Totalled your spending',
    'spend_by_category': 'Broke it down by category',
    'top_merchants': 'Ranked where you spent',
    'find_transactions': 'Searched your transactions',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in results)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    r.failed ? Icons.error_outline : Icons.search,
                    size: 13,
                    color: r.failed ? scheme.error : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      r.failed
                          ? '${_labels[r.tool] ?? r.tool} — ${r.error}'
                          : '${_labels[r.tool] ?? r.tool}: ${r.evidence}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: r.failed
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Suggestions extends StatelessWidget {
  final ValueChanged<String> onPick;

  const _Suggestions({required this.onPick});

  static const _examples = [
    'How much did I spend on groceries last month?',
    'What did I spend most on in July?',
    'Where do I shop the most?',
    'Show me anything over 100 euros this year',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 34,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text('Ask about your spending', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'Answers come from real queries against your database, and the '
              'queries are shown underneath so you can check them.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            for (final q in _examples)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OutlinedButton(
                  onPressed: () => onPick(q),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    minimumSize: const Size(double.infinity, 0),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(q, style: theme.textTheme.bodySmall),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 34,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text('No local model running', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'This tab needs one, unlike the rest of the app. Start it with '
              '"docker compose up -d", then check the connection in Settings.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
