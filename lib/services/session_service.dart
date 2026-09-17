import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';

/// Ending a session on the server, not only on the device (SEC-9).
///
/// Firebase's client `signOut()` clears local state. The refresh token remains
/// valid, and so does any ID token already minted from it, for up to an hour.
/// SEC-9's failure mode is an unattended office desktop, which a locally-ended
/// session does not address.
///
/// The server route calls `revokeRefreshTokens`, and because `requireAuth`
/// verifies with `checkRevoked: true`, that invalidates outstanding ID tokens
/// as well — immediately, on their next request.
class SessionService {
  SessionService({http.Client? client, FirebaseAuth? auth})
    : _client = client ?? http.Client(),
      _auth = auth ?? FirebaseAuth.instance;

  final http.Client _client;
  final FirebaseAuth _auth;

  /// Ends the session server-side. **Never throws.**
  ///
  /// A user who taps sign out must end up signed out even with no network, so
  /// every failure here is swallowed after being logged. The alternative — a
  /// sign-out that fails because the server is asleep — strands somebody
  /// signed in on a machine they are walking away from, which is the exact
  /// situation this is meant to fix.
  ///
  /// Returns whether the server confirmed it, so a caller that wants to tell
  /// the user can.
  Future<bool> revokeServerSession() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return false;

      final response = await _client
          .post(
            ApiConfig.path('/auth/signout'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${await user.getIdToken()}',
            },
          )
          .timeout(ApiConfig.coldStartTimeout);

      return response.statusCode == 200;
    } catch (error) {
      debugPrint('Server sign-out failed, continuing locally: $error');
      return false;
    }
  }
}

final sessionServiceProvider = Provider<SessionService>(
  (ref) => SessionService(),
);
