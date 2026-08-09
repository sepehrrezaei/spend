import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/day.dart';
import '../core/providers.dart';
import 'ai_provider.dart';
import 'ai_providers.dart';
import 'chat_service.dart';
import 'chat_tools.dart';

final chatToolsProvider = Provider<ChatTools>((ref) {
  return ChatTools(
    repository: ref.watch(transactionRepositoryProvider),
    categories: ref.watch(allCategoriesProvider).value ?? const [],
    money: ref.watch(moneyFormatterProvider).format,
    currency: ref.watch(currencyProvider).value ?? 'EUR',
  );
});

/// The chat back end, or null when no model is reachable.
///
/// Null rather than a throwing stub, so the screen can render a plain
/// explanation instead of an error.
final chatServiceProvider = Provider<ChatService?>((ref) {
  final enabled = (ref.watch(aiEnabledProvider).value ?? 'true') == 'true';
  if (!enabled) return null;

  final availability = ref.watch(aiAvailabilityProvider).value;
  if (availability == null || !availability.hasModel) return null;

  final service = ChatService(
    host: ref.watch(ollamaHostProvider).value ?? '',
    model: availability.activeModel ?? '',
    tools: ref.watch(chatToolsProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

class ChatConversation extends Notifier<List<ChatMessage>> {
  StreamSubscription<String>? _subscription;

  @override
  List<ChatMessage> build() {
    ref.onDispose(() => _subscription?.cancel());
    return const [];
  }

  bool get isBusy => state.isNotEmpty && state.last.streaming;

  Future<void> ask(String question) async {
    final text = question.trim();
    if (text.isEmpty || isBusy) return;

    state = [
      ...state,
      ChatMessage(fromUser: true, text: text),
      const ChatMessage(fromUser: false, text: '', streaming: true),
    ];

    final service = ref.read(chatServiceProvider);
    if (service == null) {
      // Say so rather than returning quietly. A silent no-op here looks
      // identical to a broken send button.
      state = [
        ...state.take(state.length - 1),
        const ChatMessage(
          fromUser: false,
          text: '',
          error:
              'No local model is reachable. Start it with "docker compose up '
              '-d" and check the connection in Settings.',
        ),
      ];
      return;
    }

    final buffer = StringBuffer();

    void updateLast(ChatMessage Function(ChatMessage) change) {
      if (state.isEmpty) return;
      final updated = [...state];
      updated[updated.length - 1] = change(updated.last);
      state = updated;
    }

    await _subscription?.cancel();
    _subscription = service
        .ask(
          text,
          today: Day.today(),
          // Evidence arrives before the prose, so the user can see what
          // was queried while the answer is still being written.
          onEvidence: (results) =>
              updateLast((m) => m.copyWith(evidence: results)),
        )
        .listen(
          (chunk) {
            buffer.write(chunk);
            updateLast((m) => m.copyWith(text: buffer.toString()));
          },
          onError: (Object e) => updateLast(
            (m) => m.copyWith(
              streaming: false,
              error: e is AiException ? e.message : e.toString(),
            ),
          ),
          onDone: () => updateLast(
            (m) => m.copyWith(
              streaming: false,
              error: buffer.isEmpty && m.error == null
                  ? 'The model did not produce an answer.'
                  : null,
            ),
          ),
        );
  }

  void clear() {
    _subscription?.cancel();
    state = const [];
  }
}

final chatConversationProvider =
    NotifierProvider<ChatConversation, List<ChatMessage>>(ChatConversation.new);
