import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/analytics/insight_rules.dart';
import 'ai_provider.dart';
import 'prompt_builder.dart';

/// Talks to a local Ollama instance over HTTP.
///
/// No API key, no account, nothing leaves the machine. Ollama is expected on
/// loopback; the app never starts or manages it, so the user is free to run it
/// in Docker, natively, or not at all.
class OllamaProvider implements AiProvider {
  final String host;
  final String model;
  final http.Client _client;

  OllamaProvider({
    this.host = defaultHost,
    this.model = defaultModel,
    http.Client? client,
  }) : _client = client ?? http.Client();

  static const defaultHost = 'http://127.0.0.1:11434';
  static const defaultModel = 'llama3.2:3b';

  /// Probes are short: if nothing answers in a couple of seconds there is
  /// nothing running, and the tab should settle into its offline state rather
  /// than hold a spinner.
  static const _probeTimeout = Duration(seconds: 2);

  /// Time allowed for the request to start returning data.
  ///
  /// Generous because a cold model has to be read off disk first — measured at
  /// around seven seconds for a 2GB model, against roughly one second warm.
  static const _requestTimeout = Duration(seconds: 45);

  /// Generation on CPU is slow — a few hundred tokens can take half a minute —
  /// so the ceiling here is generous. It exists only to stop a wedged request
  /// hanging forever.
  static const _generateTimeout = Duration(minutes: 3);

  Uri _uri(String path) => Uri.parse('$host$path');

  @override
  Future<AiAvailability> check() async {
    try {
      final response = await _client
          .get(_uri('/api/tags'))
          .timeout(_probeTimeout);

      if (response.statusCode != 200) {
        return AiAvailability.unavailable(
          'Ollama answered with HTTP ${response.statusCode}.',
        );
      }

      final body = jsonDecode(response.body) as Map<String, Object?>;
      final models = [
        for (final m in (body['models'] as List? ?? []))
          if (m is Map && m['name'] is String) m['name'] as String,
      ]..sort();

      if (models.isEmpty) {
        return const AiAvailability(
          reachable: true,
          models: [],
          reason:
              'Ollama is running but has no models. Pull one with '
              '"docker compose exec ollama ollama pull llama3.2:3b".',
        );
      }

      // Honour the configured model when present, otherwise fall back to
      // whatever is installed rather than failing outright.
      final active = models.contains(model) ? model : models.first;
      return AiAvailability(
        reachable: true,
        models: models,
        activeModel: active,
        reason: models.contains(model)
            ? null
            : 'Model "$model" is not installed; using "$active".',
      );
    } on TimeoutException {
      return const AiAvailability.unavailable(
        'No response from Ollama. Start it with "docker compose up -d".',
      );
    } on Object catch (e) {
      // Connection refused, DNS failure, malformed JSON — all the same to the
      // user: there is nothing to talk to.
      return AiAvailability.unavailable(_friendlyError(e));
    }
  }

  @override
  Stream<String> narrate(FinanceBrief brief) async* {
    final availability = await check();
    if (!availability.hasModel) {
      throw AiException(availability.reason ?? 'No model is available.');
    }

    final request = http.Request('POST', _uri('/api/chat'))
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode({
        'model': availability.activeModel ?? model,
        'stream': true,
        'messages': [
          {'role': 'system', 'content': PromptBuilder.system},
          {'role': 'user', 'content': PromptBuilder.userMessage(brief)},
        ],
        'options': {
          // Low temperature: this is a rewriting task over supplied figures,
          // not a creative one. Sampling widely here mostly produces
          // embellishment, which is the exact failure mode to avoid.
          'temperature': 0.2,
          'top_p': 0.9,
          // Enough for four sentences, and a hard stop on rambling.
          'num_predict': 220,
        },
      });

    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(_requestTimeout);
    } on TimeoutException {
      throw AiException(
        'The model did not start responding within '
        '${_requestTimeout.inSeconds}s. It may be loading — try again.',
      );
    } on Object catch (e) {
      throw AiException(_friendlyError(e));
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw AiException(
        'Ollama returned HTTP ${response.statusCode}. '
        '${body.isEmpty ? "" : body.trim()}',
      );
    }

    // Ollama streams newline-delimited JSON, one object per token.
    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(_generateTimeout);

    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      Map<String, Object?> chunk;
      try {
        chunk = jsonDecode(line) as Map<String, Object?>;
      } on Object {
        continue; // a partial line is not worth aborting a good response over
      }

      final message = chunk['message'];
      if (message is Map && message['content'] is String) {
        final content = message['content'] as String;
        if (content.isNotEmpty) yield content;
      }
      if (chunk['done'] == true) break;
    }
  }

  @override
  void dispose() => _client.close();

  static String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('Connection refused') ||
        text.contains('Failed host lookup') ||
        text.contains('SocketException')) {
      return 'Nothing is listening on that address. Start Ollama with '
          '"docker compose up -d".';
    }
    return 'Could not reach Ollama: $text';
  }
}
