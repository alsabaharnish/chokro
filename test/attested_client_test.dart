/// Attestation is attached to every request, and never breaks one.
///
/// Two properties, pulling in opposite directions, and both are load-bearing:
///
///   * Every request carries the App Check token when one can be had. A single
///     unattested call site is an endpoint that 401s for every real user once
///     `APP_CHECK_ENFORCED=true`, while passing every test that injects a fake.
///   * No request FAILS for want of a token. The server holds the enforcement
///     decision and is fail-closed once set; refusing here as well would break
///     the app against deployments that do not require attestation — which is
///     every local run, every emulator, and the whole of the rollout.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chokro/core/attested_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Records what it was asked to send, and answers 200.
class _RecordingClient extends http.BaseClient {
  final List<http.BaseRequest> sent = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"ok":true}')),
      200,
      request: request,
    );
  }
}

http.Request _request() =>
    http.Request('POST', Uri.parse('https://example.test/epr/periods'))
      ..headers['Authorization'] = 'Bearer id-token'
      ..headers['Content-Type'] = 'application/json';

void main() {
  test('a token is attached to the request', () async {
    final inner = _RecordingClient();
    final client = AttestedClient(
      inner: inner,
      readToken: () async => 'attestation-token',
    );

    await client.send(_request());

    expect(inner.sent.single.headers[appCheckHeader], 'attestation-token');
  });

  test('the header name is the one the server reads', () {
    // `server/src/appCheck.js` does `req.get('X-Firebase-AppCheck')`. A rename
    // on either side is a silent total failure once enforcement is on: every
    // request arrives unattested and is refused, with nothing to point at.
    expect(appCheckHeader, 'X-Firebase-AppCheck');
  });

  test('attestation does not disturb the headers already there', () async {
    // The services build their own Authorization header. Attestation is
    // orthogonal to it and must not replace or reorder anything.
    final inner = _RecordingClient();
    final client = AttestedClient(inner: inner, readToken: () async => 't');

    await client.send(_request());

    final headers = inner.sent.single.headers;
    expect(headers['Authorization'], 'Bearer id-token');
    expect(headers['Content-Type'], contains('application/json'));
    expect(headers[appCheckHeader], 't');
  });

  test('a request still goes out when the token cannot be had', () async {
    // The rollout case, and every local run before the console steps are done.
    final inner = _RecordingClient();
    final client = AttestedClient(
      inner: inner,
      readToken: () async => throw StateError('App Check not activated'),
    );

    final response = await client.send(_request());

    expect(response.statusCode, 200);
    expect(inner.sent.single.headers.containsKey(appCheckHeader), isFalse);
  });

  test('a null token adds no header rather than an empty one', () async {
    // An empty `X-Firebase-AppCheck` is not the same as none: it is a token
    // the server will try to verify and reject, turning "could not attest"
    // into "attested falsely".
    final inner = _RecordingClient();
    final client = AttestedClient(inner: inner, readToken: () async => null);

    await client.send(_request());

    expect(inner.sent.single.headers.containsKey(appCheckHeader), isFalse);
  });

  test('an empty token adds no header either', () async {
    final inner = _RecordingClient();
    final client = AttestedClient(inner: inner, readToken: () async => '');

    await client.send(_request());

    expect(inner.sent.single.headers.containsKey(appCheckHeader), isFalse);
  });

  test('a failing token reader is reported once, not per request', () async {
    // A device that cannot attest cannot attest for every call. A line per
    // request would bury everything else in the log.
    final inner = _RecordingClient();
    final client = AttestedClient(
      inner: inner,
      readToken: () async => throw StateError('nope'),
    );

    final printed = <String>[];
    await runZoned(
      () async {
        for (var i = 0; i < 5; i++) {
          await client.send(_request());
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => printed.add(line),
      ),
    );

    expect(inner.sent, hasLength(5));
    // Counted by the phrase, not by line: `debugPrint` splits on newlines, so
    // one warning legitimately emits more than one line.
    expect(
      printed.where((l) => l.contains('No App Check token')),
      hasLength(1),
    );
  });

  test('every request is attested, not just the first', () async {
    // The token is fetched per send rather than cached here: Firebase caches
    // internally and rotates on expiry, and holding our own copy would keep
    // sending a stale token after it rotated.
    var calls = 0;
    final inner = _RecordingClient();
    final client = AttestedClient(
      inner: inner,
      readToken: () async => 'token-${++calls}',
    );

    for (var i = 0; i < 3; i++) {
      await client.send(_request());
    }

    expect(
      inner.sent.map((r) => r.headers[appCheckHeader]),
      ['token-1', 'token-2', 'token-3'],
    );
  });

  group('nothing reaches the network unattested', () {
    // The failure this prevents is invisible until the day enforcement is
    // switched on, and then it is total for whatever the missed service does.
    // A test that injects a fake client — which every service test does —
    // cannot see it, because the default is exactly what the fake replaces.
    final dartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    test('lib/ is not empty, so a passing run means something', () {
      expect(dartFiles.length, greaterThan(50));
    });

    test('no service builds a bare http.Client', () {
      // `AttestedClient` wraps one, and is the only thing that may.
      final offenders = dartFiles
          .where((f) => !f.path.endsWith('core/attested_client.dart'))
          .where((f) => f.readAsStringSync().contains('http.Client()'))
          .map((f) => f.path)
          .toList();

      expect(
        offenders,
        isEmpty,
        reason:
            'These reach the trusted service without attestation, and will be '
            'refused once APP_CHECK_ENFORCED=true. Use AttestedClient():\n'
            '  ${offenders.join('\n  ')}',
      );
    });

    test('nothing calls http.get/post directly, bypassing any client', () {
      // A top-level `http.post(...)` takes no client at all, so there is
      // nothing to swap and no way to attest it.
      final direct = RegExp(r'\bhttp\.(get|post|put|patch|delete|head|read)\(');
      final offenders = dartFiles
          .where((f) => direct.hasMatch(f.readAsStringSync()))
          .map((f) => f.path)
          .toList();

      expect(
        offenders,
        isEmpty,
        reason:
            'These bypass the client entirely and cannot be attested:\n'
            '  ${offenders.join('\n  ')}',
      );
    });
  });
}
