import 'package:flutter_test/flutter_test.dart';
import 'package:spend/ai/local_endpoint.dart';

/// The privacy promise in one file: if this suite passes, no request the app
/// builds can leave the machine.
void main() {
  group('accepts local addresses', () {
    test('the forms a person actually types', () {
      for (final input in [
        'http://127.0.0.1:11434',
        'http://localhost:11434',
        'http://[::1]:11434',
        '127.0.0.1:11434', // no scheme
        'localhost:11434',
        'http://127.0.0.1', // no port
        'http://LOCALHOST:11434', // case
        '  http://127.0.0.1:11434  ', // pasted whitespace
      ]) {
        expect(
          LocalEndpoint.tryParse(input),
          isNotNull,
          reason: 'should accept "$input"',
        );
      }
    });

    test('the whole 127.0.0.0/8 block, not just .1', () {
      expect(LocalEndpoint.tryParse('http://127.0.0.2:11434'), isNotNull);
      expect(LocalEndpoint.tryParse('http://127.1.2.3:11434'), isNotNull);
    });

    test('normalises to scheme, host and port only', () {
      final uri = LocalEndpoint.tryParse(
        'http://127.0.0.1:11434/api/tags?x=1',
      )!;
      expect(uri.toString(), 'http://127.0.0.1:11434');
      expect(uri.path, isEmpty);
      expect(uri.query, isEmpty);
    });

    test('defaults the port when none is given', () {
      expect(LocalEndpoint.tryParse('localhost')!.port, 11434);
    });

    test('the shipped default is itself local', () {
      expect(LocalEndpoint.tryParse('http://127.0.0.1:11434'), isNotNull);
    });
  });

  group('refuses anything else', () {
    test('remote hosts', () {
      for (final input in [
        'http://example.com:11434',
        'https://api.openai.com',
        'http://192.168.1.10:11434',
        'http://10.0.0.5:11434',
        'http://0.0.0.0:11434', // binds everywhere, is not loopback
        '192.168.1.10:11434',
        'evil.com',
      ]) {
        expect(
          LocalEndpoint.tryParse(input),
          isNull,
          reason: 'should refuse "$input"',
        );
      }
    });

    test('a remote host dressed up to look local', () {
      // The classic: a subdomain, a userinfo prefix, and a lookalike name.
      for (final input in [
        'http://localhost.evil.com:11434',
        'http://127.0.0.1@evil.com:11434',
        'http://user:pw@127.0.0.1:11434',
        'http://127.0.0.1.evil.com',
      ]) {
        expect(
          LocalEndpoint.tryParse(input),
          isNull,
          reason: 'should refuse "$input"',
        );
      }
    });

    test('non-HTTP schemes', () {
      expect(LocalEndpoint.tryParse('file:///etc/passwd'), isNull);
      expect(LocalEndpoint.tryParse('ftp://127.0.0.1'), isNull);
    });

    test('empty and malformed input', () {
      expect(LocalEndpoint.tryParse(''), isNull);
      expect(LocalEndpoint.tryParse('   '), isNull);
      expect(LocalEndpoint.tryParse('http://'), isNull);
      expect(LocalEndpoint.tryParse('999.999.999.999'), isNull);
    });
  });

  group('describeProblem', () {
    test('says nothing when the address is fine', () {
      expect(LocalEndpoint.describeProblem('http://127.0.0.1:11434'), isNull);
    });

    test('explains the rule when it is not', () {
      expect(
        LocalEndpoint.describeProblem('http://evil.com'),
        contains('127.0.0.1'),
      );
      expect(LocalEndpoint.describeProblem(''), contains('Enter'));
    });
  });
}
