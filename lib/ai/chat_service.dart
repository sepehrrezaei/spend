import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/day.dart';
import 'ai_provider.dart';
import 'chat_tools.dart';
import 'local_endpoint.dart';

/// One turn in the conversation.
class ChatMessage {
  final bool fromUser;
  final String text;

  /// The queries that produced the figures in [text], shown so an answer can
  /// be checked rather than trusted.
  final List<ToolResult> evidence;

  final bool streaming;
  final String? error;

  const ChatMessage({
    required this.fromUser,
    required this.text,
    this.evidence = const [],
    this.streaming = false,
    this.error,
  });

  ChatMessage copyWith({
    String? text,
    List<ToolResult>? evidence,
    bool? streaming,
    String? error,
  }) => ChatMessage(
    fromUser: fromUser,
    text: text ?? this.text,
    evidence: evidence ?? this.evidence,
    streaming: streaming ?? this.streaming,
    error: error ?? this.error,
  );
}

/// Answers questions about your own spending, using tools rather than
/// arithmetic.
///
/// Two rounds per question:
///
///   1. The model is given the question and the tool schemas, and asked which
///      queries to run. No prose is expected from this round.
///   2. The real results are appended to the conversation and the model is
///      asked to answer from them, streaming.
///
/// If round one selects no tools, the answer is refused rather than guessed.
/// A finance answer with no query behind it is exactly what this design exists
/// to prevent.
class ChatService {
  final String host;
  final String model;
  final ChatTools tools;
  final http.Client _client;

  /// The validated address, or `null` when [host] is not loopback.
  ///
  /// Chat sends far more of the ledger than the Insights brief does — whole
  /// tool results, merchant names included — so the same guard the narration
  /// path uses is enforced here too, at the point requests are built rather
  /// than at the settings field that happens to set the value.
  final Uri? _base;

  ChatService({
    required this.host,
    required this.model,
    required this.tools,
    http.Client? client,
  }) : _base = LocalEndpoint.tryParse(host),
       _client = client ?? http.Client();

  /// The message shown when the configured address is not local.
  static const _notLocalReason =
      'The configured address is not on this machine. Only localhost, '
      '127.0.0.1 or ::1 are allowed, so nothing can leave your Mac.';

  /// The base URI for a request, or a refusal if the address is not local.
  Uri _endpoint(String path) {
    final base = _base;
    if (base == null) throw const AiException(_notLocalReason);
    return base.replace(path: path);
  }

  /// Cap on tool rounds. A small model will occasionally loop, asking for the
  /// same query repeatedly; this stops that becoming an infinite conversation.
  static const _maxToolRounds = 3;

  static const _requestTimeout = Duration(seconds: 60);
  static const _streamTimeout = Duration(minutes: 3);

  String _systemPrompt(Day today) =>
      '''
You answer questions about the user's own spending records.

You cannot see any transactions directly. To learn anything you MUST call one
of the provided tools. Never state a figure that did not come back from a tool
in this conversation — do not estimate, do not calculate, do not remember
figures from earlier questions.

Today is ${today.iso}. Work out the dates a question implies and pass them as
YYYY-MM-DD:
- "this month" = ${today.firstOfMonth.iso} to ${today.lastOfMonth.iso}
- "last month" = ${today.firstOfMonth.addMonths(-1).iso} to ${today.firstOfMonth.addDays(-1).iso}
- "this year" = ${today.year}-01-01 to ${today.iso}

To compare two periods, call total_spent twice with different dates. Never
subtract figures yourself — state both and describe the direction of the
difference in words.

When you have the results, answer in two or three plain sentences. Address the
user as "you".

All amounts are in ${tools.currency}. Write them in ${tools.currency} and never
in any other currency — a figure of 525.84 means 525.84 ${tools.currency}, not
dollars.

Never mention the tools, the queries, the data, or how you obtained anything.
Do not say "according to the tool" or "the exact amount returned". Just answer
the question as if you simply knew.

Do not generalise about items you have not individually checked. Naming the top
result and its figure is enough — do not add a summary clause about "the rest"
or "the others", because those claims are wrong far more often than they are
right.

If the results contain nothing useful, say so plainly.''';

  /// Answers [question], streaming the final prose.
  ///
  /// Emits the tool results through [onEvidence] as they are produced, so the
  /// UI can show what was actually queried while the answer is still being
  /// written.
  Stream<String> ask(
    String question, {
    required Day today,
    required void Function(List<ToolResult>) onEvidence,
  }) async* {
    final messages = <Map<String, Object?>>[
      {'role': 'system', 'content': _systemPrompt(today)},
      {'role': 'user', 'content': question},
    ];

    final gathered = <ToolResult>[];

    for (var round = 0; round < _maxToolRounds; round++) {
      final reply = await _chat(messages, withTools: true);
      final calls = _toolCalls(reply);

      if (calls.isEmpty) {
        // No tools requested. On the first round that means the model tried to
        // answer from nothing, which is refused; later it means it is done.
        if (round == 0 && gathered.isEmpty) {
          throw const AiException(
            'The model tried to answer without looking anything up, so the '
            'answer was discarded. Try rephrasing the question — naming a '
            'period like "in July" usually helps.',
          );
        }
        break;
      }

      messages.add({'role': 'assistant', 'content': '', 'tool_calls': calls});

      for (final call in calls) {
        final fn = call['function'] as Map<String, Object?>? ?? const {};
        final name = fn['name']?.toString() ?? '';
        final rawArgs = fn['arguments'];
        final args = rawArgs is Map
            ? {for (final e in rawArgs.entries) e.key.toString(): e.value}
            : <String, Object?>{};

        final result = await tools.call(name, args);
        gathered.add(result);

        messages.add({
          'role': 'tool',
          'content': jsonEncode(
            result.failed ? {'error': result.error} : result.data,
          ),
        });
      }

      onEvidence(List.unmodifiable(gathered));

      // Every call failed, so there is nothing to answer from.
      if (gathered.isNotEmpty && gathered.every((r) => r.failed)) {
        throw AiException(
          gathered.last.error ?? 'The queries did not return anything.',
        );
      }
    }

    if (gathered.isEmpty) {
      throw const AiException('No data was looked up, so there is no answer.');
    }

    yield* _stream(messages);
  }

  /// One non-streaming round, used for tool selection.
  Future<Map<String, Object?>> _chat(
    List<Map<String, Object?>> messages, {
    required bool withTools,
  }) async {
    final response = await _client
        .post(
          _endpoint('/api/chat'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'model': model,
            'stream': false,
            'messages': messages,
            if (withTools) 'tools': ChatTools.schemas,
            // Near-greedy. Tool selection is a classification problem, and
            // sampling widely just produces wrong function names.
            'options': {'temperature': 0.1, 'num_predict': 400},
          }),
        )
        .timeout(_requestTimeout);

    if (response.statusCode != 200) {
      throw AiException(
        'Ollama returned HTTP ${response.statusCode}. ${response.body.trim()}',
      );
    }
    return jsonDecode(response.body) as Map<String, Object?>;
  }

  List<Map<String, Object?>> _toolCalls(Map<String, Object?> reply) {
    final message = reply['message'];
    if (message is! Map) return const [];
    final calls = message['tool_calls'];
    if (calls is! List) return const [];
    return [
      for (final c in calls)
        if (c is Map) {for (final e in c.entries) e.key.toString(): e.value},
    ];
  }

  /// The final answering round, streamed.
  Stream<String> _stream(List<Map<String, Object?>> messages) async* {
    final request = http.Request('POST', _endpoint('/api/chat'))
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode({
        'model': model,
        'stream': true,
        'messages': messages,
        // Tools are deliberately withheld here. With them still offered the
        // model tends to request another query instead of answering the one
        // it already has results for.
        'options': {'temperature': 0.2, 'num_predict': 300},
      });

    final response = await _client.send(request).timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw AiException('Ollama returned HTTP ${response.statusCode}.');
    }

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(_streamTimeout);

    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      Map<String, Object?> chunk;
      try {
        chunk = jsonDecode(line) as Map<String, Object?>;
      } on Object {
        continue;
      }
      final message = chunk['message'];
      if (message is Map && message['content'] is String) {
        final content = message['content'] as String;
        if (content.isNotEmpty) yield content;
      }
      if (chunk['done'] == true) break;
    }
  }

  void dispose() => _client.close();
}
