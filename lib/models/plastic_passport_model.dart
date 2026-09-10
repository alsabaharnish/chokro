/// A Plastic Passport, as the producer's workspace sees it (EPR-28 to EPR-31).
///
/// ## What this model deliberately does not carry
///
/// Not the figures. The stored certificate holds a frozen snapshot of every
/// number on it — that is what makes it reproducible after a recompute — but
/// the list route does not send it, and this model has nowhere to put it.
///
/// The reason is not payload size. It is that a figure reaching a screen from
/// two places will eventually be rendered from the wrong one. The workspace
/// already reads its compliance position from `eprPeriods`, projected through
/// the k-anonymity floor; a second copy arriving alongside a certificate would
/// give the same screen two answers to "what is our collection percentage" with
/// nothing to say which is current.
///
/// So a passport here is an identity and a state: which period it certifies,
/// whether it still stands, and where to get the PDF. The figures live in the
/// PDF, which is the artefact that was actually issued.
library;

class PassportStatus {
  const PassportStatus._();

  /// Current, and the only state a third party should rely on.
  static const String issued = 'issued';

  /// Replaced by a later certificate for the same period (EPR-30).
  ///
  /// The old copy stays in circulation — that is the whole reason reissue
  /// supersedes rather than overwriting — so this state exists to be reported,
  /// not hidden.
  static const String superseded = 'superseded';

  /// Withdrawn by Chokro, with a recorded reason.
  static const String revoked = 'revoked';

  static const List<String> all = <String>[issued, superseded, revoked];

  static String label(String value) => switch (value) {
    issued => 'Current',
    superseded => 'Superseded',
    revoked => 'Revoked',
    _ => 'Unknown',
  };

  /// A one-line explanation for a reader who is holding the document.
  ///
  /// Written for the producer rather than for Chokro: the question a producer
  /// asks about a superseded certificate is "can I still send this to a
  /// customer", and the answer is what this says.
  static String explain(String value) => switch (value) {
    issued =>
      'This certificate is current. A third party verifying its serial will '
          'see that it stands.',
    superseded =>
      'A later certificate has been issued for this period. Anyone verifying '
          'this serial is shown the replacement, so send the current one '
          'instead.',
    revoked =>
      'Chokro has withdrawn this certificate. Anyone verifying its serial is '
          'told it is revoked. It should not be relied on or circulated.',
    _ => 'The state of this certificate could not be read.',
  };
}

class PlasticPassportModel {
  const PlasticPassportModel({
    required this.serial,
    required this.periodId,
    required this.status,
    required this.contentHash,
    this.scope = 'period',
    this.issuedAt,
    this.supersededBy,
    this.supersededReason,
    this.revocationReason,
  });

  /// `CHKR-PP-9F2K-7T4D`. Unguessable, and printed on the document (SEC-7).
  final String serial;

  final String periodId;
  final String status;

  /// SHA-256 over the canonical figure payload.
  ///
  /// Shown to the producer so it can be compared against the hash printed on
  /// the PDF — the same check a third party makes at the verification endpoint,
  /// available to the producer without going through it.
  final String contentHash;

  final String scope;
  final DateTime? issuedAt;

  /// The serial that replaced this one, when it was superseded by a reissue.
  ///
  /// Null on a certificate superseded because its evidence changed rather than
  /// because a newer one was issued — a corrected declaration or a re-verified
  /// mass supersedes without producing a replacement, and inventing one would
  /// point a reader at a document that does not exist.
  final String? supersededBy;

  final String? supersededReason;
  final String? revocationReason;

  bool get isCurrent => status == PassportStatus.issued;

  /// Whether this certificate should still be sent to anyone.
  ///
  /// The question the producer is actually asking. A revoked certificate has
  /// been withdrawn and a superseded one has been replaced; in both cases
  /// circulating it means a recipient's verification will contradict whatever
  /// the producer said about it.
  bool get isSafeToCirculate => isCurrent;

  /// The reason this certificate no longer stands, or null while it does.
  String? get withdrawalReason => switch (status) {
    PassportStatus.revoked => revocationReason,
    PassportStatus.superseded => supersededReason,
    _ => null,
  };

  /// The first eight hex characters of the content hash.
  ///
  /// Enough to compare by eye against the PDF, and short enough that somebody
  /// will actually do it. The full hash stays available for anyone checking
  /// properly.
  String get shortHash =>
      contentHash.length >= 8 ? contentHash.substring(0, 8) : contentHash;

  factory PlasticPassportModel.fromJson(Map<String, dynamic> json) {
    return PlasticPassportModel(
      serial: _string(json['serial']),
      periodId: _string(json['periodId']),
      // Unknown rather than assumed-current. A status this client does not
      // recognise must not read as "safe to send": a future state Chokro adds
      // would almost certainly be another kind of withdrawal.
      status: PassportStatus.all.contains(json['status'])
          ? json['status'] as String
          : 'unknown',
      contentHash: _string(json['contentHash']),
      scope: _string(json['scope']).isEmpty ? 'period' : _string(json['scope']),
      issuedAt: _date(json['issuedAt']),
      supersededBy: _stringOrNull(json['supersededBy']),
      supersededReason: _stringOrNull(json['supersededReason']),
      revocationReason: _stringOrNull(json['revocationReason']),
    );
  }
}

String _string(Object? value) => value is String ? value : '';

String? _stringOrNull(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// A timestamp from either an ISO string or a Firestore-shaped map.
DateTime? _date(Object? value) {
  if (value is String) return DateTime.tryParse(value);
  if (value is Map && value['_seconds'] is num) {
    return DateTime.fromMillisecondsSinceEpoch(
      (value['_seconds'] as num).toInt() * 1000,
      isUtc: true,
    );
  }
  return null;
}
