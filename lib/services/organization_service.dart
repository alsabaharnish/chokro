import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/constants.dart';
import '../core/network_errors.dart';
import '../models/org_member_model.dart';
import '../models/organization_model.dart';
import '../models/producer_audit_model.dart';

/// The producer portal's read and write path (EPR-3, EPR-4, SEC-1).
///
/// ## Why this is HTTP and not Firestore
///
/// Every other list in this app is a Firestore stream. This one is not, and the
/// difference is deliberate. `organizations`, `organizationMembers` and
/// `producerAuditLog` are readable directly — the rules allow it, and a later
/// phase may well stream a dashboard from them. But every *write* in this
/// feature is a server write, and several of the reads carry a decision with
/// them: which organisation this account belongs to, whether its email is
/// verified, whether an invitation has lapsed.
///
/// Resolving those in one authenticated call means the workspace has a single
/// consistent answer to "what may I do here", rather than three streams that
/// can each be at a different moment. It also means membership is resolved by
/// the same code that enforces it (`requireOrgRole`), so the screen and the
/// server can never disagree about it.
///
/// ## Failure behaviour
///
/// Reads return a typed failure rather than throwing, so a screen can say what
/// went wrong. Writes throw [OrgActionException], because a failed write is
/// something the person just tried to do and must be told about in those terms
/// — silently returning a null from "remove this member" is how someone
/// concludes an ex-employee no longer has access when they still do.
class OrganizationService {
  OrganizationService({http.Client? client, FirebaseAuth? auth})
    : _client = client ?? http.Client(),
      _auth = auth ?? FirebaseAuth.instance;

  final http.Client _client;
  final FirebaseAuth _auth;

  Future<Map<String, String>> _headers() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw OrgActionException('Sign in to continue.', code: 'unauthenticated');
    }
    final token = await user.getIdToken();
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  Future<http.Response> _get(String path) async {
    return _client
        .get(ApiConfig.path(path), headers: await _headers())
        .timeout(ApiConfig.coldStartTimeout);
  }

  Future<http.Response> _post(String path, [Map<String, dynamic>? body]) async {
    return _client
        .post(
          ApiConfig.path(path),
          headers: await _headers(),
          body: jsonEncode(body ?? const <String, dynamic>{}),
        )
        .timeout(ApiConfig.coldStartTimeout);
  }

  // -------------------------------------------------------------------------
  // Producer workspace
  // -------------------------------------------------------------------------

  /// Everything the workspace needs for its first frame.
  ///
  /// One call rather than three, so the screen never renders a member of one
  /// organisation beside another organisation's name.
  Future<ProducerWorkspace> loadWorkspace() async {
    try {
      final response = await _get('/epr/me');
      if (response.statusCode != 200) {
        return ProducerWorkspace.failed(_messageFor(response));
      }

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        return ProducerWorkspace.failed('The workspace could not be read.');
      }

      final orgJson = body['organization'];
      final memberJson = body['membership'];

      return ProducerWorkspace(
        emailVerified: body['emailVerified'] == true,
        organization: orgJson is Map<String, dynamic>
            ? OrganizationModel.fromJson(
                _dates(orgJson),
                id: _string(orgJson['orgId']),
              )
            : null,
        membership: memberJson is Map<String, dynamic>
            ? OrgMemberModel.fromJson(_dates(memberJson))
            : null,
      );
    } catch (error, stackTrace) {
      _log('workspace load failed', error, stackTrace);
      return ProducerWorkspace.failed(friendlyErrorMessage(error));
    }
  }

  Future<List<OrgMemberModel>> listMembers() async {
    final response = await _get('/epr/members');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final rows = body is Map<String, dynamic> ? body['members'] : null;
    if (rows is! List) return const <OrgMemberModel>[];

    return rows
        .whereType<Map<String, dynamic>>()
        .map((row) => OrgMemberModel.fromJson(_dates(row), id: _string(row['id'])))
        .toList(growable: false);
  }

  Future<List<OrgInvitation>> listInvitations() async {
    final response = await _get('/epr/invitations');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final rows = body is Map<String, dynamic> ? body['invitations'] : null;
    if (rows is! List) return const <OrgInvitation>[];

    return rows
        .whereType<Map<String, dynamic>>()
        .map(OrgInvitation.fromJson)
        .toList(growable: false);
  }

  /// Issues an invitation and returns its one-time link.
  ///
  /// The token comes back exactly once and is not stored anywhere that can
  /// return it again — not by Chokro, not by this client. The screen that
  /// receives it must present it as a thing to copy now, not as a record to
  /// come back to (SEC-8).
  Future<OrgInvitation> invite({
    required String email,
    required String orgRole,
  }) async {
    final response = await _post('/epr/invitations', {
      'email': email,
      'orgRole': orgRole,
    });
    if (response.statusCode != 201) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final invitation = body is Map<String, dynamic> ? body['invitation'] : null;
    if (invitation is! Map<String, dynamic>) {
      throw OrgActionException('The invitation could not be read.');
    }
    return OrgInvitation.fromJson(invitation);
  }

  Future<void> revokeInvitation(String invitationId) async {
    final response = await _post('/epr/invitations/$invitationId/revoke');
    if (response.statusCode != 200) throw _exceptionFor(response);
  }

  Future<void> changeMemberRole({
    required String uid,
    required String orgRole,
  }) async {
    final response = await _post('/epr/members/$uid/role', {'orgRole': orgRole});
    if (response.statusCode != 200) throw _exceptionFor(response);
  }

  Future<void> removeMember(String uid) async {
    final response = await _post('/epr/members/$uid/remove');
    if (response.statusCode != 200) throw _exceptionFor(response);
  }

  Future<List<ProducerAuditEntry>> listActivity({String? orgId}) async {
    // An Admin reads another organisation's timeline through the admin route;
    // a producer reads its own through the membership-scoped one. Two paths,
    // because the audit log has to be able to tell those two readers apart
    // (EPR-46).
    final response = await _get(
      orgId == null ? '/epr/audit' : '/epr/admin/organizations/$orgId/audit',
    );
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final rows = body is Map<String, dynamic> ? body['entries'] : null;
    if (rows is! List) return const <ProducerAuditEntry>[];

    return rows
        .whereType<Map<String, dynamic>>()
        .map(
          (row) =>
              ProducerAuditEntry.fromJson(_dates(row), id: _string(row['id'])),
        )
        .toList(growable: false);
  }

  // -------------------------------------------------------------------------
  // Chokro administration
  // -------------------------------------------------------------------------

  Future<List<OrganizationModel>> listOrganizations({String? status}) async {
    final response = await _get(
      status == null
          ? '/epr/admin/organizations'
          : '/epr/admin/organizations?status=$status',
    );
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final rows = body is Map<String, dynamic> ? body['organizations'] : null;
    if (rows is! List) return const <OrganizationModel>[];

    return rows
        .whereType<Map<String, dynamic>>()
        .map(
          (row) => OrganizationModel.fromJson(
            _dates(row),
            id: _string(row['orgId']),
          ),
        )
        .toList(growable: false);
  }

  Future<OrganizationDetail> loadOrganization(String orgId) async {
    final response = await _get('/epr/admin/organizations/$orgId');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw OrgActionException('That organisation could not be read.');
    }
    return OrganizationDetail.fromJson(body);
  }

  Future<void> createOrganization(Map<String, dynamic> application) async {
    final response = await _post('/epr/admin/organizations', application);
    if (response.statusCode != 201) throw _exceptionFor(response);
  }

  Future<void> reviewOrganization({
    required String orgId,
    required String decision,
    String? reason,
    String? sizeClass,
    List<String>? categories,
    String? complianceRoute,
    DateTime? obligationStartDate,
    String? bin,
    String? tradeLicenceNo,
    String? doeRegistrationNo,
  }) async {
    final response = await _post(
      '/epr/admin/organizations/$orgId/review',
      <String, dynamic>{
        'decision': decision,
        'reason': ?reason,
        'sizeClass': ?sizeClass,
        'categories': ?categories,
        'complianceRoute': ?complianceRoute,
        if (obligationStartDate != null)
          'obligationStartDate': obligationStartDate.toUtc().toIso8601String(),
        'bin': ?bin,
        'tradeLicenceNo': ?tradeLicenceNo,
        'doeRegistrationNo': ?doeRegistrationNo,
      },
    );
    if (response.statusCode != 200) throw _exceptionFor(response);
  }

  Future<void> setOrganizationStatus({
    required String orgId,
    required String status,
    String? reason,
  }) async {
    final response = await _post('/epr/admin/organizations/$orgId/status', {
      'status': status,
      'reason': ?reason,
    });
    if (response.statusCode != 200) throw _exceptionFor(response);
  }

  Future<OrgInvitation> inviteAsAdmin({
    required String orgId,
    required String email,
    required String orgRole,
  }) async {
    final response = await _post(
      '/epr/admin/organizations/$orgId/invitations',
      {'email': email, 'orgRole': orgRole},
    );
    if (response.statusCode != 201) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final invitation = body is Map<String, dynamic> ? body['invitation'] : null;
    if (invitation is! Map<String, dynamic>) {
      throw OrgActionException('The invitation could not be read.');
    }
    return OrgInvitation.fromJson(invitation);
  }

  /// Records that an Admin opened an organisation's read-only view (EPR-46).
  ///
  /// Throws when the entry could not be written, and the caller must not open
  /// the view in that case: a read of a customer's compliance position that
  /// nothing recorded is precisely what the audit trail exists to prevent.
  Future<void> recordOrganizationView(String orgId) async {
    final response = await _post('/epr/admin/organizations/$orgId/view');
    if (response.statusCode != 200) throw _exceptionFor(response);
  }

  Future<AuditChainReport> verifyAuditChain(String orgId) async {
    final response = await _get('/epr/admin/organizations/$orgId/audit/verify');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw OrgActionException('The verification result could not be read.');
    }
    return AuditChainReport.fromJson(body);
  }

  // -------------------------------------------------------------------------

  OrgActionException _exceptionFor(http.Response response) =>
      OrgActionException(_messageFor(response), code: _codeFor(response));

  String _messageFor(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        final message = body['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    } catch (_) {
      // A non-JSON body from a proxy or a cold start. Fall through to the
      // generic sentence rather than showing the person raw HTML.
    }
    return switch (response.statusCode) {
      401 => 'Sign in to continue.',
      403 => 'You do not have permission to do that.',
      404 => 'That record no longer exists.',
      429 => 'Too many attempts. Wait a minute and try again.',
      503 => 'The service is waking up. Try again in a moment.',
      _ => 'That action could not be completed.',
    };
  }

  String? _codeFor(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        final code = body['error'];
        if (code is String && code.isNotEmpty) return code;
      }
    } catch (_) {
      // Same reasoning as above.
    }
    return null;
  }

  void _log(String message, [Object? error, StackTrace? stackTrace]) {
    if (kDebugMode) {
      debugPrint('[OrganizationService] $message: $error');
      if (stackTrace != null) debugPrint('$stackTrace');
    }
  }
}

/// Converts the ISO strings the service sends into the [DateTime]s the models
/// parse, leaving everything else untouched.
///
/// The models take plain Dart types and never see a Firestore `Timestamp`
/// (§5.1); over HTTP they never see one either, so the boundary conversion
/// happens here in exactly one place.
Map<String, dynamic> _dates(Map<String, dynamic> json) {
  const dateKeys = {
    'obligationStartDate',
    'verifiedAt',
    'createdAt',
    'invitedAt',
    'activatedAt',
    'removedAt',
    'timestamp',
    'expiresAt',
  };

  return <String, dynamic>{
    for (final entry in json.entries)
      entry.key: dateKeys.contains(entry.key)
          ? _timestamp(entry.value)
          : entry.value,
  };
}

/// Firestore Admin SDK JSON renders a timestamp as `{_seconds, _nanoseconds}`;
/// an explicitly serialised one arrives as an ISO string. Both occur in this
/// API's responses, so both are handled — and anything else is left alone for
/// the model's own tolerant parser to reject.
Object? _timestamp(Object? value) {
  if (value is Map && value['_seconds'] is num) {
    return DateTime.fromMillisecondsSinceEpoch(
      (value['_seconds'] as num).round() * 1000,
      isUtc: true,
    );
  }
  return value;
}

String _string(Object? value) => value is String ? value : '';

/// A failed producer-portal action, with the server's own sentence.
class OrgActionException implements Exception {
  const OrgActionException(this.message, {this.code});

  final String message;
  final String? code;

  /// The session must prove its password again before this action (SEC-9).
  ///
  /// Its own flag rather than a string comparison at the call site, because
  /// three screens need to react to it and a typo in one of them would show a
  /// generic refusal for a condition the person can actually fix.
  bool get needsReauthentication => code == 'reauthentication_required';

  bool get needsEmailVerification => code == 'email_unverified';

  @override
  String toString() => message;
}

/// The first frame of a producer workspace.
class ProducerWorkspace {
  const ProducerWorkspace({
    required this.emailVerified,
    this.organization,
    this.membership,
    this.error,
  });

  const ProducerWorkspace.failed(String message)
    : emailVerified = false,
      organization = null,
      membership = null,
      error = message;

  final bool emailVerified;
  final OrganizationModel? organization;
  final OrgMemberModel? membership;
  final String? error;

  bool get hasError => error != null;

  /// Whether this account can actually do anything in the portal.
  ///
  /// All three conditions, not just membership: an unverified address, a
  /// removed membership and a suspended organisation each mean the workspace
  /// opens read-only or not at all, and a screen that checked only one would
  /// offer actions the server then refuses.
  bool get isReady =>
      emailVerified &&
      membership != null &&
      membership!.isActive &&
      organization != null;

  /// What this member may do, or null when they may do nothing.
  String? get orgRole => membership?.isActive == true ? membership!.orgRole : null;

  bool can(String required) => membership?.can(required) ?? false;

  /// True when the workspace opens but nothing may be written to it.
  bool get isReadOnly =>
      organization?.isReadOnly == true ||
      membership?.orgRole == OrgRoles.viewer;
}

/// An invitation as the members screen sees it. Never carries a token except in
/// the single response that created it.
class OrgInvitation {
  const OrgInvitation({
    required this.invitationId,
    required this.email,
    required this.orgRole,
    required this.status,
    this.expiresAt,
    this.token,
  });

  factory OrgInvitation.fromJson(Map<String, dynamic> json) => OrgInvitation(
    invitationId: _string(json['invitationId']),
    email: _string(json['email']),
    orgRole: _string(json['orgRole']),
    status: _string(json['status']),
    expiresAt: DateTime.tryParse(_string(json['expiresAt'])),
    token: json['token'] is String ? json['token'] as String : null,
  );

  final String invitationId;
  final String email;
  final String orgRole;

  /// `pending`, `accepted`, `revoked`, or `expired` — the last of which the
  /// service resolves at read time rather than storing, because nothing runs on
  /// a timer to write it (NFR-E-2).
  final String status;

  final DateTime? expiresAt;

  /// Present only in the response that issued this invitation, and never again.
  final String? token;

  bool get isPending => status == 'pending';

  /// The link to send. Null once the token is gone, which is immediately after
  /// the issuing response.
  String? linkFor(String baseUrl) =>
      token == null ? null : '$baseUrl/join?token=$token';
}

/// An organisation with the two things a review decision needs beside it.
class OrganizationDetail {
  const OrganizationDetail({
    required this.organization,
    required this.brandCollisions,
    required this.members,
  });

  factory OrganizationDetail.fromJson(Map<String, dynamic> json) {
    final orgJson = json['organization'];
    final collisions = json['brandCollisions'];
    final members = json['members'];

    return OrganizationDetail(
      organization: orgJson is Map<String, dynamic>
          ? OrganizationModel.fromJson(
              _dates(orgJson),
              id: _string(orgJson['orgId']),
            )
          : null,
      brandCollisions: collisions is List
          ? collisions
                .whereType<Map<String, dynamic>>()
                .map(BrandCollision.fromJson)
                .toList(growable: false)
          : const <BrandCollision>[],
      members: members is List
          ? members
                .whereType<Map<String, dynamic>>()
                .map(
                  (row) =>
                      OrgMemberModel.fromJson(_dates(row), id: _string(row['id'])),
                )
                .toList(growable: false)
          : const <OrgMemberModel>[],
    );
  }

  final OrganizationModel? organization;

  /// EPR-14. A blocking flag on the review screen, not an automatic refusal —
  /// two genuinely different companies can share a word.
  final List<BrandCollision> brandCollisions;

  final List<OrgMemberModel> members;

  bool get hasBrandCollision => brandCollisions.isNotEmpty;
}

class BrandCollision {
  const BrandCollision({
    required this.orgId,
    required this.legalName,
    required this.tradeName,
    required this.status,
    required this.matchedOn,
  });

  factory BrandCollision.fromJson(Map<String, dynamic> json) => BrandCollision(
    orgId: _string(json['orgId']),
    legalName: _string(json['legalName']),
    tradeName: _string(json['tradeName']),
    status: _string(json['status']),
    matchedOn: _string(json['matchedOn']),
  );

  final String orgId;
  final String legalName;
  final String tradeName;
  final String status;

  /// `tradeNameKey` or `legalNameKey` — which name collided.
  final String matchedOn;
}

/// The result of walking one organisation's audit chain (SEC-12).
class AuditChainReport {
  const AuditChainReport({
    required this.orgId,
    required this.intact,
    required this.complete,
    required this.entriesChecked,
    required this.findings,
  });

  factory AuditChainReport.fromJson(Map<String, dynamic> json) =>
      AuditChainReport(
        orgId: _string(json['orgId']),
        intact: json['intact'] == true,
        complete: json['complete'] == true,
        entriesChecked: json['entriesChecked'] is num
            ? (json['entriesChecked'] as num).toInt()
            : 0,
        findings: json['findings'] is List
            ? (json['findings'] as List)
                  .whereType<Map<String, dynamic>>()
                  .map((f) => _string(f['problem']))
                  .where((p) => p.isNotEmpty)
                  .toList(growable: false)
            : const <String>[],
      );

  final String orgId;

  /// Only ever true over a log the check actually saw all of. See [complete].
  final bool intact;

  /// False when the log is longer than the verification limit. "The first 500
  /// entries are intact" is a different claim from "the log is intact", and the
  /// screen must not present one as the other.
  final bool complete;

  final int entriesChecked;
  final List<String> findings;
}
