import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/analytics/insight_rules.dart';
import 'ai_provider.dart';
import 'local_endpoint.dart';
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

  /// The validated address, or `null` when [host] is not loopback.
  ///
  /// Resolved once, here, so that no request can be built from an address that
  /// was never checked. A remote host would send the user's finances off the
  /// machine and expose an unauthenticated Ollama, so a bad value has to fail
  /// closed rather than be quietly contacted.
  final Uri? _base;

  OllamaProvider({
    this.host = defaultHost,
    this.model = defaultModel,
    http.Client? client,
  }) : _base = LocalEndpoint.tryParse(host),
       _client = client ?? http.Client();

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

  Uri _uri(Uri base, String path) => base.replace(path: path);

  /// The message shown when the configured address is not local.
  static const _notLocalReason =
      'The configured address is not on this machine. Only localhost, '
      '127.0.0.1 or ::1 are allowed, so nothing can leave your Mac.';

  @override
  Future<AiAvailability> check() async {
    final base = _base;
    if (base == null) {
      return const AiAvailability.unavailable(_notLocalReason);
    }
    try {
      final response = await _client
          .get(_uri(base, '/api/tags'))
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
          reason: 'Ollama is running but has no models yet.',
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
        'The address answered but did not reply in time. If Ollama is '
        'starting up, give it a moment and press Test.',
      );
    } on Object catch (e) {
      // Connection refused, DNS failure, malformed JSON — all the same to the
      // user: there is nothing to talk to.
      return AiAvailability.unavailable(_friendlyError(e));
    }
  }

  @override
  Stream<String> narrate(FinanceBrief brief) async* {
    final base = _base;
    if (base == null) throw const AiException(_notLocalReason);

    final availability = await check();
    if (!availability.hasModel) {
      throw AiException(availability.reason ?? 'No model is available.');
    }

    final request = http.Request('POST', _uri(base, '/api/chat'))
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

  /// Downloads [name], reporting progress as the server sends it.
  ///
  /// The point of this existing at all: before it, getting from "no models" to
  /// a working setup meant leaving the app and running a docker command from a
  /// README. The bytes are the same either way; what changes is whether a user
  /// who does not use Docker can get there.
  ///
  /// Goes through the same [LocalEndpoint] gate as everything else — a pull is
  /// a request to the configured host, and that host must be on this machine.
  Stream<PullProgress> pullModel(String name) async* {
    final base = _base;
    if (base == null) {
      yield const PullProgress(status: 'failed', error: _notLocalReason);
      return;
    }

    final request = http.Request('POST', _uri(base, '/api/pull'))
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode({'model': name, 'stream': true});

    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(_requestTimeout);
    } on Object catch (e) {
      yield PullProgress(status: 'failed', error: _friendlyError(e));
      return;
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      yield PullProgress(
        status: 'failed',
        error: body.contains('not found')
            ? 'Ollama does not have a model called "$name".'
            : 'Ollama returned HTTP ${response.statusCode}. ${body.trim()}',
      );
      return;
    }

    // Newline-delimited JSON, one object per progress update. No overall
    // timeout: a multi-gigabyte download on a slow connection is legitimately
    // long, and the user can cancel by walking away from the screen — unlike
    // generation, where a stall means something is wedged.
    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      Map<String, Object?> chunk;
      try {
        chunk = jsonDecode(line) as Map<String, Object?>;
      } on Object {
        continue; // a split line is not worth failing a download over
      }

      final error = chunk['error'];
      if (error is String) {
        yield PullProgress(status: 'failed', error: error);
        return;
      }

      yield PullProgress(
        status: chunk['status'] as String? ?? 'working',
        completedBytes: (chunk['completed'] as num?)?.toInt() ?? 0,
        totalBytes: (chunk['total'] as num?)?.toInt() ?? 0,
      );
    }
  }

  @override
  void dispose() => _client.close();

  static String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('Connection refused') ||
        text.contains('Failed host lookup') ||
        text.contains('SocketException')) {
      // Deliberately does not blame Docker. From here the only observable
      // fact is that nothing accepted a connection — whether Docker is
      // stopped, the container is down, or Ollama is installed natively and
      // not running are indistinguishable over a refused socket, and a
      // message that guesses wrong sends the user to fix the wrong thing.
      return 'Nothing is listening on that address. Start Ollama, then press '
          'Test.';
    }
    return 'Could not reach Ollama: $text';
  }
}
