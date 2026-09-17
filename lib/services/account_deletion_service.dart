import '../core/attested_client.dart';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../models/account_deletion_model.dart';
import 'organization_service.dart' show OrgActionException;

/// Champion account deletion (SEC-13).
///
/// ## Why the plan is a separate call
///
/// An Admin pressing "delete" is about to do something irreversible on behalf
/// of somebody who is not in the room, and will often have to tell that person
/// afterwards what happened to their data. The plan is what they read first:
/// what goes, what stays, and which of the staying is Chokro's position rather
/// than settled law.
///
/// Folding it into the delete call would mean the retained list arrives only
/// after it is too late to think about.
///
/// ## 207 is a success code and must not be treated as one
///
/// The server answers 207 when a step failed — a Cloudinary outage leaves the
/// photograph in place while the name is already gone. `http` does not treat
/// that as an error, and neither does this method: it parses normally and lets
/// [DeletionOutcome.complete] carry the bad news, because the caller needs the
/// list of what DID run as much as the list of what did not.
class AccountDeletionService {
  AccountDeletionService({http.Client? client, FirebaseAuth? auth})
    : _client = client ?? AttestedClient(),
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

  /// What deleting this account would do. Changes nothing.
  Future<DeletionPlan> plan(String uid) async {
    final response = await _client
        .get(
          ApiConfig.path('/admin/accounts/$uid/deletion-plan'),
          headers: await _headers(),
        )
        .timeout(ApiConfig.coldStartTimeout);

    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw const OrgActionException('The deletion plan could not be read.');
    }
    return DeletionPlan.fromJson(body);
  }

  /// Erases the account. Irreversible.
  ///
  /// Throws on a refusal or an outage. Returns an outcome — possibly an
  /// incomplete one — whenever the server actually ran.
  Future<DeletionOutcome> delete(String uid, {String reason = ''}) async {
    final response = await _client
        .post(
          ApiConfig.path('/admin/accounts/$uid/delete'),
          headers: await _headers(),
          body: jsonEncode({'reason': reason}),
        )
        .timeout(ApiConfig.coldStartTimeout);

    // 200 clean, 207 partial. Anything else did not run.
    if (response.statusCode != 200 && response.statusCode != 207) {
      throw _exceptionFor(response);
    }

    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      // The deletion may well have happened. Saying so is the honest outcome —
      // claiming success from an unreadable body would be worse, and claiming
      // failure would send an Admin to re-run something that may be done.
      throw const OrgActionException(
        'The deletion ran but its result could not be read. Check the account '
        'before running it again.',
      );
    }
    return DeletionOutcome.fromJson(body);
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

    return OrgActionException(
      message ??
          switch (response.statusCode) {
            401 => 'Sign in to continue.',
            403 => 'You do not have permission to do that.',
            404 => 'There is no such account.',
            >= 500 => 'The service is unavailable. Nothing was deleted.',
            _ => 'The account could not be deleted.',
          },
      code: code,
    );
  }
}
