import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spend/ai/ai_providers.dart';
import 'package:spend/ai/ollama_provider.dart';

/// Downloading a model from Settings.
///
/// The pull is the one place the app writes several gigabytes on the user's
/// behalf, so what it reports while doing it — and what it does when the
/// server refuses — matters more than the happy path.
void main() {
  late HttpServer server;
  late List<String> requestedModels;
  late List<String> lines;
  late int status;

  setUp(() async {
    requestedModels = [];
    status = HttpStatus.ok;
    lines = const [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final request in server) {
        final body = await utf8.decoder.bind(request).join();
        final decoded = jsonDecode(body) as Map<String, Object?>;
        requestedModels.add(decoded['model'] as String? ?? '');
        request.response.statusCode = status;
        for (final l in lines) {
          request.response.write('$l\n');
        }
        await request.response.close();
      }
    }());
  });

  tearDown(() => server.close(force: true));

  /// A provider pointed at the stub, which is on loopback so LocalEndpoint
  /// lets it through.
  OllamaProvider stubProvider() =>
      OllamaProvider(host: 'http://127.0.0.1:${server.port}');

  test('progress is reported layer by layer, ending in success', () async {
    lines = [
      jsonEncode({'status': 'pulling manifest'}),
      jsonEncode({'status': 'downloading', 'completed': 50, 'total': 200}),
      jsonEncode({'status': 'downloading', 'completed': 200, 'total': 200}),
      jsonEncode({'status': 'success'}),
    ];

    final seen = await stubProvider().pullModel('llama3.2:3b').toList();

    expect(requestedModels, ['llama3.2:3b']);
    expect(seen.first.status, 'pulling manifest');
    // No total on the manifest step, so no bar — an indeterminate one is
    // honest where a determinate one frozen at zero looks broken.
    expect(seen.first.fraction, isNull);
    expect(seen[1].fraction, closeTo(0.25, 0.001));
    expect(seen.last.isDone, isTrue);
    expect(seen.any((p) => p.hasFailed), isFalse);
  });

  test(
    'an error line ends the stream instead of being reported as progress',
    () async {
      lines = [
        jsonEncode({'status': 'pulling manifest'}),
        jsonEncode({'error': 'model "nope" not found'}),
        jsonEncode({'status': 'success'}),
      ];

      final seen = await stubProvider().pullModel('nope').toList();

      expect(seen.last.hasFailed, isTrue);
      expect(seen.last.error, contains('not found'));
      // The success line after the error must not be delivered — a pull that
      // failed must never end up looking like one that worked.
      expect(seen.any((p) => p.isDone), isFalse);
    },
  );

  test('a non-200 reports the refusal rather than hanging', () async {
    status = HttpStatus.notFound;
    lines = ['model not found'];

    final seen = await stubProvider().pullModel('ghost').toList();

    expect(seen, hasLength(1));
    expect(seen.single.hasFailed, isTrue);
    expect(seen.single.error, contains('ghost'));
  });

  test('a split line does not abort a good download', () async {
    lines = [
      jsonEncode({'status': 'downloading', 'completed': 1, 'total': 2}),
      '{"status": "part',
      jsonEncode({'status': 'success'}),
    ];

    final seen = await stubProvider().pullModel('llama3.2:1b').toList();

    expect(seen.last.isDone, isTrue);
    expect(seen.where((p) => p.hasFailed), isEmpty);
  });

  test('a non-loopback host is refused before any request is made', () async {
    final seen = await OllamaProvider(
      host: 'http://evil.example.com:11434',
    ).pullModel('llama3.2:3b').toList();

    expect(seen.single.hasFailed, isTrue);
    expect(seen.single.error, contains('not on this machine'));
    // The promise is that nothing leaves the Mac, so the guard has to hold
    // before a socket is opened, not after.
    expect(requestedModels, isEmpty);
  });

  test('the recommended model is the one the app defaults to', () {
    final recommended = SuggestedModel.catalogue.where((m) => m.recommended);
    expect(recommended, hasLength(1));
    expect(recommended.single.name, OllamaProvider.defaultModel);
    expect(
      SuggestedModel.catalogue.every(
        (m) => m.note.isNotEmpty && m.size.isNotEmpty,
      ),
      isTrue,
      reason: 'a bare list of names does not help anyone choose',
    );
  });
}
