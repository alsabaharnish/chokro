/// Ending a session on the server (SEC-9).
///
/// Found in the SEC-1–SEC-14 review, 2026-09-17: `revokeRefreshTokens`
/// appeared nowhere in the codebase except a comment. Firebase's client
/// `signOut()` clears local state and nothing else, so the refresh token — and
/// any ID token already minted from it — stayed valid for up to an hour after
/// someone signed out. SEC-9's stated failure mode is an unattended office
/// desktop, which that does not address.
///
/// Both tests here are about the same tension: the revocation must be
/// attempted, and must never be able to prevent a sign-out.
library;

import 'package:chokro/services/session_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeAuth implements FirebaseAuth {
  _FakeAuth(this._user);
  final User? _user;

  @override
  User? get currentUser => _user;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUser implements User {
  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => 'token-123';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('it calls the server with the account\'s token', () async {
    http.Request? seen;
    final client = MockClient((request) async {
      seen = request;
      return http.Response('{"ok":true,"revoked":true}', 200);
    });

    final revoked = await SessionService(
      client: client,
      auth: _FakeAuth(_FakeUser()),
    ).revokeServerSession();

    expect(revoked, isTrue);
    expect(seen!.url.path, endsWith('/auth/signout'));
    expect(seen!.headers['Authorization'], 'Bearer token-123');
  });

  test('a server failure does not prevent signing out', () async {
    // The whole reason this returns a bool instead of throwing. A sign-out
    // that fails because the server is asleep strands somebody signed in on a
    // machine they are walking away from — which is the exact situation this
    // control exists to fix.
    final client = MockClient((_) async => throw Exception('offline'));

    await expectLater(
      SessionService(client: client, auth: _FakeAuth(_FakeUser()))
          .revokeServerSession(),
      completion(isFalse),
    );
  });

  test('a non-200 reports not-revoked rather than throwing', () async {
    final client = MockClient((_) async => http.Response('nope', 503));

    expect(
      await SessionService(
        client: client,
        auth: _FakeAuth(_FakeUser()),
      ).revokeServerSession(),
      isFalse,
    );
  });

  test('no signed-in user is a no-op, not an error', () async {
    var called = false;
    final client = MockClient((_) async {
      called = true;
      return http.Response('{}', 200);
    });

    expect(
      await SessionService(
        client: client,
        auth: _FakeAuth(null),
      ).revokeServerSession(),
      isFalse,
    );
    expect(called, isFalse);
  });
}
