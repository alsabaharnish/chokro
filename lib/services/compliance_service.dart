import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/network_errors.dart';
import '../models/plastic_passport_model.dart';
import '../models/put_on_market_model.dart';
import 'organization_service.dart' show OrgActionException;

/// The declaration and certificate path (EPR-28 to EPR-31, EPR-40 to EPR-43).
///
/// ## Why the PDF comes down the wire rather than being built here
///
/// This app already renders PDFs — `bin_label_pdf.dart` builds sheets of bin
/// labels, and `pdf_fonts.dart` fetches a Bengali face at runtime to do it. So
/// rendering the Plastic Passport here would have been the shorter path.
///
/// EPR-31 forbids it, in one sentence: "a certificate a user's device produced
/// is a certificate a user's device can alter". The serial, the content hash
/// and the frozen figure snapshot are all minted server-side; this class
/// downloads bytes it did not compose and cannot alter without the hash
/// disagreeing.
///
/// ## Why a declaration write is not a Firestore write
///
/// `putOnMarketDeclarations` is read-only to every client, including an owner's.
/// Submitting has to append an immutable version row and an audit entry in the
/// same transaction, and correcting has to supersede every certificate issued
/// for the period. None of those three is expressible in a security rule, so a
/// client write path would check the shape of the figures while everything that
/// makes the filing trustworthy happened somewhere else, or not at all.
class ComplianceService {
  ComplianceService({http.Client? client, FirebaseAuth? auth})
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
    final token = await user.getIdToken();
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  // -------------------------------------------------------------------------
  // Declarations
  // -------------------------------------------------------------------------

  /// One period's declaration, its history, and the attestation wording.
  ///
  /// The attestation text comes from the server rather than from
  /// [putOnMarketAttestation] here, so the words a signatory reads on the form
  /// are the same words that get copied onto the record. Two copies of a legal
  /// statement drifting apart would mean the producer attested to one thing and
  /// the record says another; the local constant is the fallback for an offline
  /// first frame and is asserted equal in the tests.
  Future<DeclarationDetail> loadDeclaration(String periodId) async {
    try {
      final response = await _client
          .get(ApiConfig.path('/epr/declarations/$periodId'), headers: await _headers())
          .timeout(ApiConfig.coldStartTimeout);

      if (response.statusCode != 200) {
        return DeclarationDetail.failed(_messageFor(response));
      }

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        return DeclarationDetail.failed('The declaration could not be read.');
      }

      final declarationJson = body['declaration'];
      final versions = body['versions'];

      return DeclarationDetail(
        periodId: periodId,
        // Null, not an empty declaration. A period with no filing has not
        // declared nil (EPR-42), and the screen renders the difference.
        declaration: declarationJson is Map<String, dynamic>
            ? PutOnMarketDeclaration.fromJson(declarationJson)
            : null,
        versions: versions is List
            ? versions
                  .whereType<Map<String, dynamic>>()
                  .map(PutOnMarketDeclaration.fromJson)
                  .toList(growable: false)
            : const <PutOnMarketDeclaration>[],
        attestationText: body['attestationText'] is String
            ? body['attestationText'] as String
            : putOnMarketAttestation,
      );
    } catch (error, stackTrace) {
      _log('declaration load failed', error, stackTrace);
      return DeclarationDetail.failed(friendlyErrorMessage(error));
    }
  }

  Future<List<PutOnMarketDeclaration>> listDeclarations() async {
    final response = await _client
        .get(ApiConfig.path('/epr/declarations'), headers: await _headers())
        .timeout(ApiConfig.coldStartTimeout);
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final rows = body is Map<String, dynamic> ? body['declarations'] : null;
    if (rows is! List) return const <PutOnMarketDeclaration>[];

    return rows
        .whereType<Map<String, dynamic>>()
        .map(PutOnMarketDeclaration.fromJson)
        .toList(growable: false);
  }

  /// Saves a draft. Not a denominator until it is submitted.
  Future<void> saveDraft({
    required String periodId,
    required List<PutOnMarketLine> lines,
    String? attestedByName,
    String? note,
  }) async {
    final response = await _client
        .put(
          ApiConfig.path('/epr/declarations/$periodId'),
          headers: await _headers(),
          body: jsonEncode({
            // Grams, because that is the unit the form collects and the server
            // is the only thing that converts. Sending milligrams from here
            // would put the conversion on two sides of the wire.
            'lines': [
              for (final line in lines)
                {
                  'category': line.category,
                  'units': line.units,
                  'massG': line.massMg / 1000,
                },
            ],
            'attestedByName': ?attestedByName,
            'note': ?note,
          }),
        )
        .timeout(ApiConfig.coldStartTimeout);

    if (response.statusCode != 200) throw _exceptionFor(response);
  }

  /// Files the declaration under attestation (EPR-41).
  ///
  /// Owner-only on the server, and the name is required: the attestation says a
  /// false figure may cost the company its registration, and a statement nobody
  /// signed is not an attestation.
  Future<DeclarationSubmission> submit({
    required String periodId,
    required String attestedByName,
  }) async {
    final response = await _client
        .post(
          ApiConfig.path('/epr/declarations/$periodId/submit'),
          headers: await _headers(),
          body: jsonEncode({'attestedByName': attestedByName}),
        )
        .timeout(ApiConfig.coldStartTimeout);

    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    return DeclarationSubmission(
      version: body is Map<String, dynamic> && body['version'] is int
          ? body['version'] as int
          : 1,
      totalMassMg: body is Map<String, dynamic> && body['totalMassMg'] is int
          ? body['totalMassMg'] as int
          : 0,
    );
  }

  /// Reopens a filed declaration for correction (EPR-43, EPR-30).
  ///
  /// Returns how many certificates this invalidated, because the producer is
  /// about to be asked why a passport it already sent to a customer now reads
  /// as superseded — and finding that out afterwards is worse.
  Future<int> openCorrection({
    required String periodId,
    required String reason,
  }) async {
    final response = await _client
        .post(
          ApiConfig.path('/epr/declarations/$periodId/correct'),
          headers: await _headers(),
          body: jsonEncode({'reason': reason}),
        )
        .timeout(ApiConfig.coldStartTimeout);

    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    return body is Map<String, dynamic> && body['passportsSuperseded'] is int
        ? body['passportsSuperseded'] as int
        : 0;
  }

  // -------------------------------------------------------------------------
  // Policy
  // -------------------------------------------------------------------------

  /// The EPR policy thresholds the client needs in order to agree with the
  /// server about what it will and will not state.
  ///
  /// Read rather than hardcoded, because the server's copy is admin-writable
  /// and the two must agree. The specific case that matters is EPR-39's carbon
  /// ceiling: if an Admin lowers it, the certificate stops printing a carbon
  /// figure for periods above the new ceiling, and a client still using the old
  /// constant would keep showing one. A producer comparing its dashboard to its
  /// own certificate would find a figure on one and not the other, with nothing
  /// to say which was right.
  ///
  /// Returns null on any failure. The caller falls back to the compiled-in
  /// default, and `carbon_math.dart` explains why that fallback is not
  /// automatically safe.
  Future<EprPolicyThresholds?> loadPolicy() async {
    try {
      final response = await _client
          .get(ApiConfig.path('/epr/config/policy'), headers: await _headers())
          .timeout(ApiConfig.coldStartTimeout);

      if (response.statusCode != 200) return null;

      final body = jsonDecode(response.body);
      final policy = body is Map<String, dynamic> ? body['policy'] : null;
      if (policy is! Map<String, dynamic>) return null;

      return EprPolicyThresholds(
        carbonUncertaintyCeiling: _fraction(policy['carbonUncertaintyCeiling']),
        kAnonymityFloor: policy['kAnonymityFloor'] is int
            ? policy['kAnonymityFloor'] as int
            : null,
      );
    } catch (error, stackTrace) {
      _log('policy load failed', error, stackTrace);
      return null;
    }
  }

  /// A fraction, or null. A value outside (0, 1] is not a fraction, and
  /// accepting one would put a nonsensical ceiling in front of every carbon
  /// figure.
  static double? _fraction(Object? value) {
    if (value is num && value.isFinite && value > 0 && value <= 1) {
      return value.toDouble();
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Passports
  // -------------------------------------------------------------------------

  Future<List<PlasticPassportModel>> listPassports() async {
    final response = await _client
        .get(ApiConfig.path('/epr/passports'), headers: await _headers())
        .timeout(ApiConfig.coldStartTimeout);
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final rows = body is Map<String, dynamic> ? body['passports'] : null;
    if (rows is! List) return const <PlasticPassportModel>[];

    return rows
        .whereType<Map<String, dynamic>>()
        .map(PlasticPassportModel.fromJson)
        .toList(growable: false);
  }

  /// Downloads a certificate in the given language (NFR-E-4).
  ///
  /// Returns bytes, not a file. Where they go afterwards is a platform question
  /// — a share sheet on mobile, a browser download on web — and this class does
  /// not need to know.
  Future<Uint8List> downloadPassport({
    required String serial,
    required String locale,
  }) async {
    final response = await _client
        .get(
          ApiConfig.path('/epr/passports/$serial.pdf?locale=$locale'),
          headers: await _headers(),
        )
        .timeout(ApiConfig.coldStartTimeout);

    if (response.statusCode != 200) throw _exceptionFor(response);

    // A JSON error body with a 200 would be a server fault, but an empty body
    // is the failure that matters: it would be saved as a zero-byte PDF the
    // producer discovers is broken when they open it in front of a regulator.
    if (response.bodyBytes.isEmpty) {
      throw const OrgActionException(
        'The certificate came back empty. Chokro has been notified.',
        code: 'empty_pdf',
      );
    }

    return response.bodyBytes;
  }

  // -------------------------------------------------------------------------
  // Failure handling
  // -------------------------------------------------------------------------

  OrgActionException _exceptionFor(http.Response response) {
    String? code;
    List<String>? problems;
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        if (body['error'] is String) code = body['error'] as String;
        if (body['problems'] is List) {
          problems = (body['problems'] as List).whereType<String>().toList();
        }
      }
    } catch (_) {
      // Non-JSON body. The status line is all there is.
    }

    // Every problem at once. A form that reports the first fault and hides the
    // rest makes a five-line declaration a five-round-trip exercise.
    if (problems != null && problems.isNotEmpty) {
      return DeclarationRejected(problems);
    }

    return OrgActionException(_messageFor(response), code: code);
  }

  String _messageFor(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        final message = body['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    } catch (_) {
      // A non-JSON body from a proxy or a cold start.
    }
    return switch (response.statusCode) {
      401 => 'Sign in to continue.',
      403 => 'You do not have permission to do that.',
      404 => 'That record no longer exists.',
      409 => 'That has already been done.',
      429 => 'Too many attempts. Wait a minute and try again.',
      503 => 'The service is waking up. Try again in a moment.',
      _ => 'That action could not be completed.',
    };
  }

  void _log(String what, Object error, StackTrace stackTrace) {
    if (kDebugMode) {
      debugPrint('[compliance] $what: $error');
      debugPrintStack(stackTrace: stackTrace, maxFrames: 6);
    }
  }
}

/// A declaration refused with a list of specific problems.
///
/// Its own type rather than a message string, because the form highlights the
/// offending line and a joined sentence cannot say which line that was.
class DeclarationRejected extends OrgActionException {
  const DeclarationRejected(this.problems)
    : super(
        'Some figures could not be accepted.',
        code: 'invalid_declaration',
      );

  final List<String> problems;

  @override
  String toString() => problems.join('\n');
}

/// One period's declaration, its history, and the words to sign.
class DeclarationDetail {
  const DeclarationDetail({
    required this.periodId,
    required this.declaration,
    required this.versions,
    required this.attestationText,
    this.error,
  });

  const DeclarationDetail.failed(String message)
    : periodId = '',
      declaration = null,
      versions = const <PutOnMarketDeclaration>[],
      attestationText = putOnMarketAttestation,
      error = message;

  final String periodId;

  /// Null when nothing has been filed. Not an empty declaration (EPR-42).
  final PutOnMarketDeclaration? declaration;

  final List<PutOnMarketDeclaration> versions;
  final String attestationText;
  final String? error;

  bool get hasError => error != null;

  /// Whether a submitted filing exists that can act as a denominator.
  bool get isFiled => declaration?.isUsable ?? false;
}

class DeclarationSubmission {
  const DeclarationSubmission({required this.version, required this.totalMassMg});

  final int version;
  final int totalMassMg;
}

/// The policy thresholds the client reads back from the server.
///
/// Only the two the client actually acts on. Fetching the whole policy
/// document and reaching into it at each call site is how a client ends up
/// depending on a field the server has renamed.
class EprPolicyThresholds {
  const EprPolicyThresholds({
    this.carbonUncertaintyCeiling,
    this.kAnonymityFloor,
  });

  /// EPR-39's ceiling. Null when the server did not send a usable value.
  final double? carbonUncertaintyCeiling;

  /// SEC-3's floor.
  final int? kAnonymityFloor;
}
