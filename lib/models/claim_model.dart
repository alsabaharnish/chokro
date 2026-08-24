/// Chokro — self-reported eco-action claims (F6.1–F6.4).
///
/// Plain Dart, no Firebase imports (§5.1).
///
/// ## Why this is deliberately the weakest route
///
/// A disposal is geofenced, time-locked, hash-checked and screened. A claim has
/// none of that, because there is nothing objective to check a photograph of a
/// planted tree against — no bin, no radius, no distance. The safeguards that
/// remain are a fixed action vocabulary, a weekly quota, an administrator's own
/// eyes, and a smaller award.
///
/// That asymmetry is the design, not a gap in it. §7.3 enforces
/// `claimAward < disposalAward` as a validated invariant precisely so the
/// weaker route can never pay better than the stronger one — if it did, users
/// would optimise into it and the verification design would stop meaning
/// anything.
///
/// **Claims are never auto-approved.** The auto-approve lane exists only where
/// mechanical checks can pass, and here none can.
library;

/// Where a claim sits in its lifecycle.
///
/// Three states, not the disposal's four. There is no `autoApproved` because
/// there is no automatic lane — every approval is a person's decision, so
/// `approved` always implies a human looked.
enum ClaimStatus {
  pending,
  approved,
  rejected;

  /// Falls back to [pending] for anything unrecognised — fail toward no payout,
  /// the same rule the disposal status uses.
  static ClaimStatus fromName(String? name) {
    for (final status in ClaimStatus.values) {
      if (status.name == name) return status;
    }
    return ClaimStatus.pending;
  }

  bool get isPending => this == ClaimStatus.pending;
  bool get isApproved => this == ClaimStatus.approved;
  bool get isRejected => this == ClaimStatus.rejected;
  bool get isTerminal => this != ClaimStatus.pending;
}

/// The closed action vocabulary (§7, FR-6).
///
/// Fixed even though a bounded optional story now adds personal context: it
/// keeps claims sortable for review and gives an administrator a specific
/// question to answer about the photograph rather than an open-ended category.
enum ClaimActionType {
  treePlanting,
  composting,
  refusingSingleUsePlastic,
  reusableBagOrBottle,
  communityCleanup;

  static ClaimActionType? fromName(String? name) {
    for (final type in ClaimActionType.values) {
      if (type.name == name) return type;
    }
    return null;
  }

  String get label {
    switch (this) {
      case ClaimActionType.treePlanting:
        return 'Tree planting';
      case ClaimActionType.composting:
        return 'Composting';
      case ClaimActionType.refusingSingleUsePlastic:
        return 'Refusing single-use plastic';
      case ClaimActionType.reusableBagOrBottle:
        return 'Reusable bag or bottle';
      case ClaimActionType.communityCleanup:
        return 'Community cleanup';
    }
  }

  /// What the photograph should show. Shown on the submission screen, so the
  /// user knows what evidence is expected before they take it.
  String get evidenceHint {
    switch (this) {
      case ClaimActionType.treePlanting:
        return 'Show the planted sapling in the ground.';
      case ClaimActionType.composting:
        return 'Show the compost bin or heap with material in it.';
      case ClaimActionType.refusingSingleUsePlastic:
        return 'Show the reusable alternative you used instead.';
      case ClaimActionType.reusableBagOrBottle:
        return 'Show the bag or bottle in use.';
      case ClaimActionType.communityCleanup:
        return 'Show the collected waste or the cleaned area.';
    }
  }
}

/// How Chokro may credit this action in a public photocard.
///
/// Missing and unknown values always become [unspecified]. That is the privacy
/// boundary for claims created before this choice existed and for malformed
/// data: neither anonymous nor named publication is allowed without an explicit
/// recognised choice.
enum ClaimPublicationMode {
  /// Legacy/malformed data for which no public sharing choice was recorded.
  unspecified,
  anonymous,
  named;

  static ClaimPublicationMode fromName(String? name) => switch (name) {
    'anonymous' => ClaimPublicationMode.anonymous,
    'named' => ClaimPublicationMode.named,
    _ => ClaimPublicationMode.unspecified,
  };

  String get label => switch (this) {
    ClaimPublicationMode.unspecified => 'No public sharing permission',
    ClaimPublicationMode.anonymous => 'Anonymous public story',
    ClaimPublicationMode.named => 'Name and profile picture permitted',
  };
}

/// One self-reported action.
class ClaimModel {
  /// Firestore document ID. Null before the document is written.
  final String? id;

  final String userId;
  final ClaimActionType actionType;

  final String photoUrl;

  /// Cloudinary public id, for the server's perceptual hash.
  final String photoPublicId;

  /// Optional first-person context written by the Champion.
  final String story;

  /// Per-claim publication permission. It is immutable because clients cannot
  /// update claim documents after creation.
  final ClaimPublicationMode publicationMode;

  /// Identity snapshotted only for a named publication. Anonymous claims omit
  /// both values, preventing the export path from accidentally consulting a
  /// live user profile and revealing information that was never permitted.
  final String? championName;
  final String? championPhotoUrl;

  /// SERVER-WRITTEN ONLY. Null on the document the client creates.
  ///
  /// Compared against this user's own previous claims. A recycled photograph is
  /// the obvious way to abuse a route with no geofence, so the hash matters
  /// more here than it does for disposals — though cross-user sharing is still
  /// not detected, which is stated as a limitation (§7.2).
  final String? photoHash;

  final ClaimStatus status;

  /// Points credited, snapshotted at approval. Never re-derived from the
  /// current policy (§6.2).
  final int? pointsAwarded;

  /// Mandatory on rejection, and shown to the user.
  final String? rejectionReason;

  /// UID of the deciding administrator. Never null on a decided claim — unlike
  /// a disposal, there is no path here that decides without a person.
  final String? reviewedBy;

  final DateTime? reviewedAt;
  final DateTime? createdAt;

  const ClaimModel({
    this.id,
    required this.userId,
    required this.actionType,
    required this.photoUrl,
    this.photoPublicId = '',
    this.story = '',
    this.publicationMode = ClaimPublicationMode.unspecified,
    this.championName,
    this.championPhotoUrl,
    this.photoHash,
    this.status = ClaimStatus.pending,
    this.pointsAwarded,
    this.rejectionReason,
    this.reviewedBy,
    this.reviewedAt,
    this.createdAt,
  });

  factory ClaimModel.fromJson(Map<String, dynamic> json, {String? id}) {
    return ClaimModel(
      id: id ?? _nullableString(json['id']),
      userId: _string(json['userId']),
      actionType:
          ClaimActionType.fromName(_nullableString(json['actionType'])) ??
          ClaimActionType.reusableBagOrBottle,
      photoUrl: _string(json['photoUrl']),
      photoPublicId: _string(json['photoPublicId']),
      story: _string(json['story']),
      publicationMode: ClaimPublicationMode.fromName(
        _nullableString(json['publicationMode']),
      ),
      championName: _nullableString(json['championName']),
      championPhotoUrl: _nullableString(json['championPhotoUrl']),
      photoHash: _nullableString(json['photoHash']),
      status: ClaimStatus.fromName(_nullableString(json['status'])),
      pointsAwarded: _toNullableInt(json['pointsAwarded']),
      rejectionReason: _nullableString(json['rejectionReason']),
      reviewedBy: _nullableString(json['reviewedBy']),
      reviewedAt: _date(json['reviewedAt']),
      createdAt: _date(json['createdAt']),
    );
  }

  /// The map the *client* may write when creating a claim.
  ///
  /// Everything that decides a payout is absent by construction, and the rules
  /// enforce the same shape with `hasOnly`. This method exists so the client
  /// cannot accidentally send a field the rules would reject — it is not the
  /// security measure itself.
  Map<String, dynamic> toCreateJson() {
    final trimmedStory = story.trim();
    return <String, dynamic>{
      'userId': userId,
      'actionType': actionType.name,
      'photoUrl': photoUrl,
      'photoPublicId': photoPublicId,
      if (trimmedStory.isNotEmpty) 'story': trimmedStory,
      'publicationMode': publicationMode.name,
      if (allowsIdentityPublication) ...{
        'championName': championName!.trim(),
        'championPhotoUrl': championPhotoUrl,
      },
      'status': ClaimStatus.pending.name,
    };
  }

  ClaimModel copyWith({
    String? id,
    String? userId,
    ClaimActionType? actionType,
    String? photoUrl,
    String? photoPublicId,
    String? story,
    ClaimPublicationMode? publicationMode,
    String? championName,
    String? championPhotoUrl,
    String? photoHash,
    ClaimStatus? status,
    int? pointsAwarded,
    String? rejectionReason,
    String? reviewedBy,
    DateTime? reviewedAt,
    DateTime? createdAt,
  }) {
    return ClaimModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      actionType: actionType ?? this.actionType,
      photoUrl: photoUrl ?? this.photoUrl,
      photoPublicId: photoPublicId ?? this.photoPublicId,
      story: story ?? this.story,
      publicationMode: publicationMode ?? this.publicationMode,
      championName: championName ?? this.championName,
      championPhotoUrl: championPhotoUrl ?? this.championPhotoUrl,
      photoHash: photoHash ?? this.photoHash,
      status: status ?? this.status,
      pointsAwarded: pointsAwarded ?? this.pointsAwarded,
      rejectionReason: rejectionReason ?? this.rejectionReason,
      reviewedBy: reviewedBy ?? this.reviewedBy,
      reviewedAt: reviewedAt ?? this.reviewedAt,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  int get creditedPoints => status.isApproved ? (pointsAwarded ?? 0) : 0;

  /// Identity may appear only when the permission and both snapshotted values
  /// agree. A partially malformed named claim therefore fails closed.
  bool get allowsIdentityPublication =>
      publicationMode == ClaimPublicationMode.named &&
      championName != null &&
      championName!.trim().isNotEmpty &&
      championPhotoUrl != null &&
      championPhotoUrl!.trim().isNotEmpty;

  /// True only after an explicit anonymous choice. Missing permission is not
  /// silently upgraded into permission to publish the photo and story.
  bool get isAnonymousPublication =>
      publicationMode == ClaimPublicationMode.anonymous;

  bool get hasPublicationPermission =>
      isAnonymousPublication || allowsIdentityPublication;

  String get publicationLabel {
    if (allowsIdentityPublication) return 'Name & picture permitted';
    if (isAnonymousPublication) return 'Saved name & profile picture hidden';
    return 'No public sharing permission';
  }

  String get userFacingStatus {
    switch (status) {
      case ClaimStatus.pending:
        return 'Pending review';
      case ClaimStatus.approved:
        return 'Approved';
      case ClaimStatus.rejected:
        return 'Rejected';
    }
  }

  List<String> validate() {
    final problems = <String>[];
    if (userId.trim().isEmpty) problems.add('User is required.');
    if (photoUrl.trim().isEmpty) problems.add('A photograph is required.');
    if (story.trim().length > 800) {
      problems.add('The story must be 800 characters or fewer.');
    }
    if (publicationMode == ClaimPublicationMode.unspecified) {
      problems.add('A public sharing choice is required.');
    }
    if (publicationMode == ClaimPublicationMode.named &&
        !allowsIdentityPublication) {
      problems.add(
        'Named publication requires the Champion name and profile picture.',
      );
    }
    if (status.isRejected &&
        (rejectionReason == null || rejectionReason!.trim().isEmpty)) {
      problems.add('A rejection must record a reason.');
    }
    if (status.isApproved && (pointsAwarded == null || pointsAwarded! <= 0)) {
      problems.add('An approved claim must record the points awarded.');
    }
    if (status.isTerminal &&
        (reviewedBy == null || reviewedBy!.trim().isEmpty)) {
      // Unlike a disposal, every decided claim has a human behind it.
      problems.add('A decided claim must record the reviewing 3ZERO Admin.');
    }
    return problems;
  }

  bool get isValid => validate().isEmpty;

  @override
  String toString() =>
      'ClaimModel(id: $id, ${actionType.name}, ${status.name}, '
      'points: $pointsAwarded)';
}

/// ISO-8601 week key, e.g. `2026-W31`.
///
/// Duplicated deliberately from `points_policy.dart`'s [IsoWeek] rather than
/// imported, so this file stays self-contained — but the two must agree, and
/// both are tested against the same year-boundary cases. The server has a third
/// copy in `pointsPolicy.js`.
///
/// Getting this wrong silently corrupts quota enforcement at year boundaries:
/// ISO weeks start on Monday, and week 1 is the week containing the first
/// Thursday, so early January can belong to the previous ISO year.
class ClaimQuota {
  const ClaimQuota._();

  /// Document ID for `claimQuotas/{userId}_{isoWeek}`.
  static String docId(String userId, DateTime date) =>
      '${userId}_${weekKey(date)}';

  static String weekKey(DateTime date) {
    final thursday = _thursdayOfWeek(date);
    final firstOfYear = DateTime.utc(thursday.year, 1, 1);
    final week = (thursday.difference(firstOfYear).inDays ~/ 7) + 1;
    return '${thursday.year}-W${week.toString().padLeft(2, '0')}';
  }

  static DateTime _thursdayOfWeek(DateTime date) {
    final utc = DateTime.utc(date.year, date.month, date.day);
    return utc.add(Duration(days: 4 - utc.weekday));
  }
}

int? _toNullableInt(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return null;
}

String _string(Object? value) => value is String ? value : '';
String? _nullableString(Object? value) => value is String ? value : null;

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
