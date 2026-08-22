/// Chokro — disposal submission model (F2.3–F2.8).
///
/// Plain Dart, no Firebase imports (§5.1).
///
/// This model carries the state machine for the earn loop, which is larger than
/// the original brief anticipated. The brief assumed one approval path (an
/// administrator). The design now has two — an automatic one when the AI screen
/// and the mechanical checks all pass, and a manual one when anything is
/// unclear — and the user is told which one credited them. That distinction has
/// to survive into the ledger, so it lives in the status rather than being
/// inferred from whether `reviewedBy` happens to be set.
library;

/// Where a submission sits in its lifecycle.
///
/// Two approved states, deliberately. Collapsing them would lose the answer to
/// "was this checked by a person?", which is exactly what an examiner will ask
/// about any auto-credited award, and what an appeal needs in order to be
/// meaningful.
enum DisposalStatus {
  /// Awaiting a human decision. Either the AI was not confident, a mechanical
  /// check flagged something, or the AI was unreachable. Points are not credited
  /// and the wallet balance is untouched — the UI shows the amount as pending.
  pending,

  /// Cleared automatically: inside the radius, no active lockout, under the
  /// daily cap, photo hash not seen before, and the AI screen passed. Points
  /// credited by the server without a person looking.
  autoApproved,

  /// Cleared by an administrator after landing in the review queue. Points
  /// credited by the server on the administrator's decision.
  manualApproved,

  /// Refused. No points, a mandatory reason recorded and shown to the user, and
  /// the bin lockout released so a legitimate retry is possible (§7.4).
  rejected;

  /// Parses the string stored in Firestore, falling back to [pending].
  ///
  /// Falling back to the *unrewarded* state is deliberate: an unrecognised or
  /// corrupted status must never be read as "approved". Fail toward no payout.
  static DisposalStatus fromName(String? name) {
    for (final status in DisposalStatus.values) {
      if (status.name == name) return status;
    }
    return DisposalStatus.pending;
  }

  /// Whether points were awarded for this submission.
  bool get isApproved =>
      this == DisposalStatus.autoApproved ||
      this == DisposalStatus.manualApproved;

  bool get isPending => this == DisposalStatus.pending;
  bool get isRejected => this == DisposalStatus.rejected;

  /// Whether the outcome is settled. Pending submissions are the only ones the
  /// admin queue should show.
  bool get isTerminal => this != DisposalStatus.pending;

  /// Whether a person made this decision.
  bool get wasHumanDecided =>
      this == DisposalStatus.manualApproved || this == DisposalStatus.rejected;
}

/// What the user says they are disposing of. A closed vocabulary, for the same
/// reasons as the claim action types (§7): it makes submissions sortable, gives
/// the AI screen something specific to check the photo against, and keeps an
/// unmoderated free-text field out of the system.
enum DisposalItemType {
  plasticBottle,
  plasticOther,
  paper,
  glass,
  metal,
  eWaste,
  organic;

  static DisposalItemType? fromName(String? name) {
    for (final type in DisposalItemType.values) {
      if (type.name == name) return type;
    }
    return null;
  }

  /// Label for the picker and the review queue.
  String get label {
    switch (this) {
      case DisposalItemType.plasticBottle:
        return 'Plastic bottles';
      case DisposalItemType.plasticOther:
        return 'Other plastic';
      case DisposalItemType.paper:
        return 'Paper and cardboard';
      case DisposalItemType.glass:
        return 'Glass';
      case DisposalItemType.metal:
        return 'Metal and cans';
      case DisposalItemType.eWaste:
        return 'Electronic waste';
      case DisposalItemType.organic:
        return 'Organic waste';
    }
  }
}

/// Why a submission was routed to human review instead of being auto-approved.
///
/// Recorded on the submission and shown to the reviewing administrator, so the
/// queue explains itself rather than presenting a photo with no context. A
/// submission may carry several flags at once.
enum DisposalFlag {
  /// GPS position fell outside the bin's radius.
  outsideRadius,

  /// The photo's perceptual hash closely matches one this user submitted before.
  duplicatePhoto,

  /// The AI's read of the photo disagrees with the count the user declared.
  countMismatch,

  /// The AI's confidence fell below the auto-approve threshold.
  lowConfidence,

  /// The AI did not see the declared material in the photo.
  itemTypeMismatch,

  /// The user has already had the maximum approved disposals today (§7.3).
  dailyCapReached,

  /// The AI service could not be reached or errored. Fail toward review, never
  /// toward payout.
  screeningUnavailable,

  /// The photograph's perceptual hash could not be computed, so it was never
  /// compared against this user's earlier submissions (F2.11).
  ///
  /// Distinct from [duplicatePhoto] and from its absence. "No match found" and
  /// "could not look" are different answers, and treating them alike is what let
  /// a submission take the auto-approve lane with the duplicate defence never
  /// having run — the hash step threw, nothing was flagged, `flags.length == 0`,
  /// and it paid out. Fail toward review, exactly like
  /// [screeningUnavailable].
  hashUnavailable,

  /// The URL/public id did not identify an original uploaded into this user's
  /// disposal folder. Such a record is never auto-approved.
  photoUntrusted,

  /// Material type or count was outside the server's closed schema.
  invalidDeclaration,

  /// Coordinates were missing, out of range, or the failed-fix value 0,0.
  invalidLocation;

  static DisposalFlag? fromName(String? name) {
    for (final flag in DisposalFlag.values) {
      if (flag.name == name) return flag;
    }
    return null;
  }

  /// Sentence shown to the administrator in the review queue.
  String get explanation {
    switch (this) {
      case DisposalFlag.outsideRadius:
        return 'Captured position was outside the bin radius.';
      case DisposalFlag.duplicatePhoto:
        return 'Photo closely matches an earlier submission by this user.';
      case DisposalFlag.countMismatch:
        return 'Declared item count does not match what the screen detected.';
      case DisposalFlag.lowConfidence:
        return 'Automated screening was not confident enough to decide.';
      case DisposalFlag.itemTypeMismatch:
        return 'Declared material was not detected in the photo.';
      case DisposalFlag.dailyCapReached:
        return 'User has reached the daily approved-disposal cap.';
      case DisposalFlag.hashUnavailable:
        return 'The photo could not be fingerprinted, so it was not compared '
            'against earlier submissions.';
      case DisposalFlag.photoUntrusted:
        return 'The photo does not match a trusted upload for this account.';
      case DisposalFlag.invalidDeclaration:
        return 'The material type or item count is not valid.';
      case DisposalFlag.invalidLocation:
        return 'The submitted coordinates are missing or invalid.';
      case DisposalFlag.screeningUnavailable:
        return 'Automated screening was unavailable; not yet checked.';
    }
  }
}

/// One disposal submission.
class DisposalModel {
  /// Firestore document ID. Null before the document is written.
  final String? id;

  final String userId;
  final String binId;

  /// Cloudinary URL for the disposal photograph.
  final String photoUrl;

  /// Cloudinary public_id for the stored image.
  ///
  /// Needed server-side: the perceptual hash is computed from an 8x8 grayscale
  /// transform of this image, and the transform URL is built from the public
  /// id. Written by the client because only the client sees the upload
  /// response, and harmless in its hands — it names an image that is already
  /// public at an unguessable URL.
  final String photoPublicId;

  /// Perceptual hash of the photograph, used for duplicate detection.
  ///
  /// SERVER-WRITTEN ONLY. This is null on the document the client creates. The
  /// trusted service computes it from the stored image and writes it during
  /// screening. A client-supplied hash would be worthless — a modified app would
  /// simply send a fresh random value every time and the check would never fire.
  final String? photoHash;

  /// Coordinates reported by the device at capture time.
  final double capturedLat;
  final double capturedLng;

  /// Distance from the bin as computed on-device, in metres.
  ///
  /// Display and feedback only. The server recomputes this from
  /// [capturedLat]/[capturedLng] and never trusts the number stored here — a
  /// client can lie about both the distance and the coordinates, but storing the
  /// raw inputs at least makes the lie auditable (§7.4, F2.5).
  final double distanceMeters;

  /// How many items the user says they are disposing of.
  final int declaredItemCount;

  /// What the user says the items are.
  final DisposalItemType itemType;

  final DisposalStatus status;

  /// Why this went to review. Empty on an auto-approved submission.
  final List<DisposalFlag> flags;

  /// Whether the trusted service has finished the mechanical checks.
  ///
  /// False on the client-created document. Administrators must not approve
  /// while it is false because the queue can receive that document before the
  /// follow-up verification request finishes.
  final bool verificationCompleted;

  /// Screening confidence, 0.0–1.0. Null if screening has not run or failed.
  final double? screenConfidence;

  /// Item count the screen believes it saw. Null if it could not tell.
  final int? screenItemCount;

  /// Short free-text note from the screening service, for the admin queue only.
  /// Never shown to the user — it would teach people how to game the screen.
  final String? screenNotes;

  /// Points credited, snapshotted at decision time.
  ///
  /// Null until approved. Once set it is never recomputed from the current
  /// policy: an administrator lowering the disposal award must not rewrite what
  /// past submissions were worth (see `points_policy.dart`).
  final int? pointsAwarded;

  /// Mandatory on rejection, and surfaced to the user.
  final String? rejectionReason;

  /// UID of the deciding administrator. Null on an auto-approved submission —
  /// which is precisely how the two approval paths stay distinguishable.
  final String? reviewedBy;

  final DateTime? reviewedAt;
  final DateTime? createdAt;

  const DisposalModel({
    this.id,
    required this.userId,
    required this.binId,
    required this.photoUrl,
    this.photoPublicId = '',
    this.photoHash,
    required this.capturedLat,
    required this.capturedLng,
    required this.distanceMeters,
    required this.declaredItemCount,
    required this.itemType,
    this.status = DisposalStatus.pending,
    this.flags = const <DisposalFlag>[],
    this.verificationCompleted = false,
    this.screenConfidence,
    this.screenItemCount,
    this.screenNotes,
    this.pointsAwarded,
    this.rejectionReason,
    this.reviewedBy,
    this.reviewedAt,
    this.createdAt,
  });

  factory DisposalModel.fromJson(Map<String, dynamic> json, {String? id}) {
    final rawFlags = json['flags'];
    final flags = <DisposalFlag>[];
    if (rawFlags is List) {
      for (final entry in rawFlags) {
        final flag = DisposalFlag.fromName(_nullableString(entry));
        if (flag != null) flags.add(flag);
      }
    }

    return DisposalModel(
      id: id ?? _nullableString(json['id']),
      userId: _nullableString(json['userId']) ?? '',
      binId: _nullableString(json['binId']) ?? '',
      photoUrl: _nullableString(json['photoUrl']) ?? '',
      photoPublicId: _nullableString(json['photoPublicId']) ?? '',
      photoHash: _nullableString(json['photoHash']),
      capturedLat: _toDouble(json['capturedLat']),
      capturedLng: _toDouble(json['capturedLng']),
      distanceMeters: _toDouble(json['distanceMeters']),
      declaredItemCount: _toInt(json['declaredItemCount']),
      itemType:
          DisposalItemType.fromName(_nullableString(json['itemType'])) ??
          DisposalItemType.plasticOther,
      status: DisposalStatus.fromName(_nullableString(json['status'])),
      flags: flags,
      // Older verified documents predate the explicit marker but carry all
      // three server-only evidence keys. Keep them reviewable after upgrade.
      verificationCompleted:
          json['verificationCompleted'] == true ||
          (json.containsKey('photoHash') &&
              json.containsKey('screenConfidence') &&
              json.containsKey('screenItemCount')),
      screenConfidence: _toNullableDouble(json['screenConfidence']),
      screenItemCount: _toNullableInt(json['screenItemCount']),
      screenNotes: _nullableString(json['screenNotes']),
      pointsAwarded: _toNullableInt(json['pointsAwarded']),
      rejectionReason: _nullableString(json['rejectionReason']),
      reviewedBy: _nullableString(json['reviewedBy']),
      reviewedAt: _date(json['reviewedAt']),
      createdAt: _date(json['createdAt']),
    );
  }

  /// Field map for a Firestore write.
  ///
  /// Timestamps are omitted — the service layer writes them with
  /// `FieldValue.serverTimestamp()` (§7.4). [photoHash], [screenConfidence],
  /// [screenItemCount], [screenNotes], [pointsAwarded] and [status] transitions
  /// are written by the trusted server, not by this map from the client.
  /// Full serialisation, INCLUDING server-owned fields.
  ///
  /// Not the write path, and must never become one. `createPendingDisposal` uses
  /// [toCreateJson], which omits `pointsAwarded`, `photoHash`, `screenConfidence`
  /// and the rest by construction — the create rule uses `hasOnly`, so a document
  /// carrying any of them is refused outright.
  ///
  /// This exists for the round-trip test that proves [fromJson] and this agree.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'userId': userId,
    'binId': binId,
    'photoUrl': photoUrl,
    'photoPublicId': photoPublicId,
    if (photoHash != null) 'photoHash': photoHash,
    'capturedLat': capturedLat,
    'capturedLng': capturedLng,
    'distanceMeters': distanceMeters,
    'declaredItemCount': declaredItemCount,
    'itemType': itemType.name,
    'status': status.name,
    'flags': flags.map((flag) => flag.name).toList(),
    'verificationCompleted': verificationCompleted,
    if (screenConfidence != null) 'screenConfidence': screenConfidence,
    if (screenItemCount != null) 'screenItemCount': screenItemCount,
    if (screenNotes != null) 'screenNotes': screenNotes,
    if (pointsAwarded != null) 'pointsAwarded': pointsAwarded,
    if (rejectionReason != null) 'rejectionReason': rejectionReason,
    if (reviewedBy != null) 'reviewedBy': reviewedBy,
  };

  /// The map the *client* is allowed to write when creating a submission.
  ///
  /// Everything that decides a payout is absent by construction. The Firestore
  /// rules enforce the same shape — this method exists so the client cannot
  /// accidentally send a field the rules would reject, not as the security
  /// measure itself. The rules are the security measure.
  Map<String, dynamic> toCreateJson() => <String, dynamic>{
    'userId': userId,
    'binId': binId,
    'photoUrl': photoUrl,
    'photoPublicId': photoPublicId,
    'capturedLat': capturedLat,
    'capturedLng': capturedLng,
    'distanceMeters': distanceMeters,
    'declaredItemCount': declaredItemCount,
    'itemType': itemType.name,
    'status': DisposalStatus.pending.name,
    'flags': const <String>[],
  };

  DisposalModel copyWith({
    String? id,
    String? userId,
    String? binId,
    String? photoUrl,
    String? photoPublicId,
    String? photoHash,
    double? capturedLat,
    double? capturedLng,
    double? distanceMeters,
    int? declaredItemCount,
    DisposalItemType? itemType,
    DisposalStatus? status,
    List<DisposalFlag>? flags,
    bool? verificationCompleted,
    double? screenConfidence,
    int? screenItemCount,
    String? screenNotes,
    int? pointsAwarded,
    String? rejectionReason,
    String? reviewedBy,
    DateTime? reviewedAt,
    DateTime? createdAt,
  }) {
    return DisposalModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      binId: binId ?? this.binId,
      photoUrl: photoUrl ?? this.photoUrl,
      photoPublicId: photoPublicId ?? this.photoPublicId,
      photoHash: photoHash ?? this.photoHash,
      capturedLat: capturedLat ?? this.capturedLat,
      capturedLng: capturedLng ?? this.capturedLng,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      declaredItemCount: declaredItemCount ?? this.declaredItemCount,
      itemType: itemType ?? this.itemType,
      status: status ?? this.status,
      flags: flags ?? this.flags,
      verificationCompleted:
          verificationCompleted ?? this.verificationCompleted,
      screenConfidence: screenConfidence ?? this.screenConfidence,
      screenItemCount: screenItemCount ?? this.screenItemCount,
      screenNotes: screenNotes ?? this.screenNotes,
      pointsAwarded: pointsAwarded ?? this.pointsAwarded,
      rejectionReason: rejectionReason ?? this.rejectionReason,
      reviewedBy: reviewedBy ?? this.reviewedBy,
      reviewedAt: reviewedAt ?? this.reviewedAt,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  // ---------------------------------------------------------------------------
  // Derived state
  // ---------------------------------------------------------------------------

  bool get isPending => status.isPending;
  bool get isApproved => status.isApproved;
  bool get isRejected => status.isRejected;
  bool get wasAutoApproved => status == DisposalStatus.autoApproved;
  bool get wasManuallyApproved => status == DisposalStatus.manualApproved;

  /// Points actually in the user's wallet from this submission.
  /// Zero unless approved — a pending submission has awarded nothing.
  int get creditedPoints => isApproved ? (pointsAwarded ?? 0) : 0;

  bool get hasFlags => flags.isNotEmpty;

  /// Verification never reached a reviewable or payable outcome. A verified,
  /// flagless pending record is included to recover submissions stranded by the
  /// server's former two-write auto-approval path.
  bool get needsVerificationRetry =>
      status.isPending && (!verificationCompleted || flags.isEmpty);

  /// One-line status for the user's history screen.
  String get userFacingStatus {
    switch (status) {
      case DisposalStatus.pending:
        return 'Pending review';
      case DisposalStatus.autoApproved:
        return 'Approved';
      case DisposalStatus.manualApproved:
        return 'Manually verified';
      case DisposalStatus.rejected:
        return 'Rejected';
    }
  }

  /// Structural problems with the record, independent of any decision.
  ///
  /// Not a substitute for the rules or the server checks — this catches a
  /// malformed submission early, in the app, before an upload is wasted.
  List<String> validate() {
    final problems = <String>[];
    if (userId.trim().isEmpty) problems.add('User is required.');
    if (binId.trim().isEmpty) problems.add('Bin is required.');
    if (photoUrl.trim().isEmpty) problems.add('A photograph is required.');
    if (declaredItemCount <= 0) {
      problems.add('Item count must be at least 1.');
    }
    if (declaredItemCount > 100) {
      problems.add('Item count is implausibly high.');
    }
    if (capturedLat.isNaN || capturedLat < -90 || capturedLat > 90) {
      problems.add('Captured latitude is out of range.');
    }
    if (capturedLng.isNaN || capturedLng < -180 || capturedLng > 180) {
      problems.add('Captured longitude is out of range.');
    }
    if (capturedLat == 0 && capturedLng == 0) {
      problems.add('Location fix failed; try again with GPS enabled.');
    }
    if (status.isRejected &&
        (rejectionReason == null || rejectionReason!.trim().isEmpty)) {
      problems.add('A rejection must record a reason.');
    }
    if (status.isApproved && (pointsAwarded == null || pointsAwarded! <= 0)) {
      problems.add('An approved submission must record the points awarded.');
    }
    if (status == DisposalStatus.manualApproved &&
        (reviewedBy == null || reviewedBy!.trim().isEmpty)) {
      problems.add('A manual approval must record the reviewing 3ZERO Admin.');
    }
    return problems;
  }

  bool get isValid => validate().isEmpty;

  @override
  String toString() =>
      'DisposalModel(id: $id, status: ${status.name}, flags: '
      '${flags.map((f) => f.name).toList()}, points: $pointsAwarded)';
}

double _toDouble(Object? value, {double fallback = 0.0}) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return fallback;
}

double? _toNullableDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return null;
}

int _toInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return fallback;
}

int? _toNullableInt(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return null;
}

String? _nullableString(Object? value) => value is String ? value : null;

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
