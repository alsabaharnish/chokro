import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../models/disclosure_model.dart';
import 'organization_service.dart' show OrgActionException;

/// Regulator disclosure (SEC-13).
///
/// ## Where the password goes: nowhere near Chokro
///
/// [reauthenticate] passes it to **Firebase**, which verifies it and refreshes
/// the session's `auth_time`. This service then forces an ID-token refresh so
/// the new claim reaches the server, and the server refuses a stale one.
///
/// Chokro's own backend never receives, forwards or stores the password, and
/// there is no method here that could send one. The step-up is real — the
/// server will refuse without it — and the credential never leaves Firebase's
/// own exchange.
///
/// ## The register is readable without stepping up
///
/// Deliberately. An Admin checking whether a colleague's access was proper must
/// not face the same barrier as the access itself. Oversight has to be cheaper
/// than the thing it oversees, or it does not happen.
class DisclosureService {
  DisclosureService({http.Client? client, FirebaseAuth? auth})
    : _client = client ?? http.Client(),
      _auth = auth ?? FirebaseAuth.instance;

  final http.Client _client;
  final FirebaseAuth _auth;

  Future<Map<String, String>> _headers() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const OrgActionException(
        'Sign in to continue.',
        code: 'unauthenticated',
      );
    }
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${await user.getIdToken()}',
    };
  }

  /// Proves possession of the password again, and refreshes the token.
  ///
  /// The refresh is not optional: `reauthenticateWithCredential` updates the
  /// session, but the server reads `auth_time` from the ID TOKEN, and a cached
  /// token still carries the old one. Without `getIdToken(true)` the step-up
  /// would appear to succeed here and be refused there.
  Future<void> reauthenticate(String password) async {
    final user = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null || email.isEmpty) {
      throw const OrgActionException(
        'Sign in again to continue.',
        code: 'unauthenticated',
      );
    }

    try {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: password),
      );
      await user.getIdToken(true);
    } on FirebaseAuthException catch (error) {
      throw OrgActionException(
        switch (error.code) {
          'wrong-password' || 'invalid-credential' =>
            'That password is not correct.',
          'too-many-requests' =>
            'Too many attempts. Wait a few minutes and try again.',
          'user-mismatch' || 'user-not-found' =>
            'Sign in again to continue.',
          _ => 'That did not work. Try again.',
        },
        code: error.code,
      );
    }
  }

  /// Resolves a pseudonymous reference to its evidence. Never names a person.
  Future<DisclosureResult> resolve({
    required String orgId,
    required String disposalRef,
    required String doeReference,
    required String declaration,
    required DisclosureLocation location,
    String? periodId,
  }) async {
    final response = await _post('/epr/admin/disclosure/resolve', {
      'orgId': orgId,
      'disposalRef': disposalRef,
      'doeReference': doeReference,
      'declaration': declaration,
      'location': location.toJson(),
      if (periodId != null && periodId.isNotEmpty) 'periodId': periodId,
    });
    return DisclosureResult.fromJson(response);
  }

  /// Names the Champion behind a resolved disposal. A separate act.
  Future<Map<String, dynamic>> releaseIdentity({
    required String orgId,
    required String disposalId,
    required String doeReference,
    required String declaration,
    required DisclosureLocation location,
  }) {
    return _post('/epr/admin/disclosure/identity', {
      'orgId': orgId,
      'disposalId': disposalId,
      'doeReference': doeReference,
      'declaration': declaration,
      'location': location.toJson(),
    });
  }

  /// Every disclosure, newest first.
  Future<DisclosureRegister> register({int limit = 100, String? orgId}) async {
    final query = orgId == null || orgId.isEmpty
        ? '?limit=$limit'
        : '?limit=$limit&orgId=$orgId';
    final response = await _client
        .get(
          ApiConfig.path('/epr/admin/disclosure/register$query'),
          headers: await _headers(),
        )
        .timeout(ApiConfig.coldStartTimeout);

    if (response.statusCode != 200) throw _exceptionFor(response);
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw const OrgActionException('The register could not be read.');
    }
    return DisclosureRegister.fromJson(body);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _client
        .post(
          ApiConfig.path(path),
          headers: await _headers(),
          body: jsonEncode(body),
        )
        .timeout(ApiConfig.coldStartTimeout);

    if (response.statusCode != 200) throw _exceptionFor(response);
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const OrgActionException('The response could not be read.');
    }
    return decoded;
  }

  OrgActionException _exceptionFor(http.Response response) {
    String? code;
    String? message;
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        if (body['error'] is String) code = body['error'] as String;
        if (body['message'] is String) message = body['message'] as String;
      }
    } catch (_) {
      // A non-JSON body from a proxy or a cold start.
    }

    // `reauthentication_required` is given its own sentence rather than the
    // generic 403, because the remedy is a specific one the screen can offer.
    if (code == 'reauthentication_required') {
      return const OrgActionException(
        'Your unlock has expired. Enter your password again to continue.',
        code: 'reauthentication_required',
      );
    }

    return OrgActionException(
      message ??
          switch (response.statusCode) {
            401 => 'Sign in to continue.',
            403 => 'You do not have permission to do that.',
            >= 500 => 'The service is unavailable. Nothing was recorded.',
            _ => 'That did not run.',
          },
      code: code,
    );
  }
}
