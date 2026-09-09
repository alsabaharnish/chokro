/// Chokro — the per-organisation activity trail (EPR-44, SEC-12, §5.1).
///
/// Plain Dart, no Firebase imports (§5.1).
library;

/// The action vocabulary of `producerAuditLog`.
///
/// Stored strings, never renamed (QA-6). Entries this build does not recognise
/// are still *shown* — with their raw action string — rather than hidden,
/// because an audit trail that silently omits what it cannot label is worse
/// than one that admits the gap. That is the opposite of the fail-closed
/// treatment given to authorisation enums, and deliberately so: here the risk
/// is concealment, not privilege.
class ProducerAuditAction {
  const ProducerAuditAction._();

  static const String orgApplied = 'org.applied';
  static const String orgApproved = 'org.approved';
  static const String orgRejected = 'org.rejected';
  static const String orgInfoRequested = 'org.infoRequested';
  static const String orgSuspended = 'org.suspended';
  static const String orgReinstated = 'org.reinstated';
  static const String orgUpdated = 'org.updated';

  static const String memberInvited = 'member.invited';
  static const String memberInvitationRevoked = 'member.invitationRevoked';
  static const String memberActivated = 'member.activated';
  static const String memberRoleChanged = 'member.roleChanged';
  static const String memberRemoved = 'member.removed';

  // Phase B — the mass chain (EPR-9 to EPR-14).
  static const String skuSaved = 'sku.saved';
  static const String skuSubmitted = 'sku.submitted';

  /// The single most consequential entry in this log: the moment a number that
  /// will appear on a regulatory filing was accepted (EPR-42).
  static const String skuMassVerified = 'sku.massVerified';
  static const String skuMassRejected = 'sku.massRejected';
  static const String skuRetired = 'sku.retired';

  /// An Admin looked at the workspace as the organisation sees it (EPR-46).
  ///
  /// Logged because a read of a company's compliance position by someone
  /// outside that company is exactly the event an audit trail exists to record.
  /// There is no impersonation anywhere in this system, so this entry always
  /// names the Admin, never the producer.
  static const String adminViewedAsOrg = 'admin.viewedAsOrg';

  static String label(String action) => switch (action) {
    orgApplied => 'Applied for onboarding',
    orgApproved => 'Onboarding approved',
    orgRejected => 'Onboarding rejected',
    orgInfoRequested => 'More information requested',
    orgSuspended => 'Organisation suspended',
    orgReinstated => 'Organisation reinstated',
    orgUpdated => 'Organisation details updated',
    memberInvited => 'Member invited',
    memberInvitationRevoked => 'Invitation revoked',
    memberActivated => 'Member joined',
    memberRoleChanged => 'Member role changed',
    memberRemoved => 'Member removed',
    skuSaved => 'Product registered or edited',
    skuSubmitted => 'Product submitted for mass verification',
    skuMassVerified => 'Unit mass verified by Chokro',
    skuMassRejected => 'Mass declaration rejected',
    skuRetired => 'Product retired',
    adminViewedAsOrg => 'Admin viewed this workspace',
    // The raw value, not 'Unknown'. See the class comment.
    _ => action,
  };
}

/// One entry in an organisation's append-only activity log.
///
/// ## Why the chain digest is on the model at all
///
/// `producerAuditLog` is append-only for every principal including Admins, and
/// each entry carries a digest over the previous entry for the same
/// organisation (SEC-12). The rules can refuse an update or a delete; they
/// cannot detect an entry *removed* by something that bypasses them, which the
/// Admin SDK does by definition. The chain is what makes a removal visible: a
/// gap breaks the links either side of it.
///
/// So the digest is carried to the client and shown in the audit pack, because
/// a tamper-evidence control nobody can check is a claim rather than a control.
/// The client never *computes* a digest — it displays the stored one, and
/// verification is the server's job.
class ProducerAuditEntry {
  const ProducerAuditEntry({
    required this.id,
    required this.orgId,
    required this.action,
    required this.actorUid,
    this.actorName = '',
    this.actorRole = '',
    this.targetType = '',
    this.targetId = '',
    this.summary = '',
    this.previousDigest,
    this.digest,
    this.sequence,
    this.timestamp,
  });

  final String id;
  final String orgId;

  /// One of [ProducerAuditAction], or a value from a later release.
  final String action;

  /// Who acted. Always a real principal — an Admin acting on an organisation is
  /// recorded as that Admin, never as the organisation (EPR-46).
  final String actorUid;
  final String actorName;

  /// The actor's platform role at the time, so a later role change does not
  /// rewrite what the log says about a past action.
  final String actorRole;

  /// What was acted on: `organization`, `member`, `sku`, `declaration`,
  /// `passport`, `report`.
  final String targetType;
  final String targetId;

  /// A sentence a person can read, written by the server at the time of the
  /// action. Not reconstructed at read time — a summary rebuilt from current
  /// state would describe the present, not the event.
  final String summary;

  /// SEC-12 hash chain, over the previous entry for this organisation.
  final String? previousDigest;
  final String? digest;

  /// Monotonic per organisation. A gap is evidence in itself.
  final int? sequence;

  final DateTime? timestamp;

  /// Whether this entry claims to be chained.
  ///
  /// The first entry for an organisation has no predecessor, so a null
  /// [previousDigest] is correct exactly once. Anything after that with no
  /// digest is an entry written outside the chained path, which the
  /// reconciliation console should surface rather than hide.
  bool get isChained => digest != null && digest!.isNotEmpty;

  bool get isChainOrigin => sequence == 1 && previousDigest == null;

  factory ProducerAuditEntry.fromJson(
    Map<String, dynamic> json, {
    required String id,
  }) {
    return ProducerAuditEntry(
      id: id,
      orgId: _string(json['orgId']),
      action: _string(json['action']),
      actorUid: _string(json['actorUid']),
      actorName: _string(json['actorName']),
      actorRole: _string(json['actorRole']),
      targetType: _string(json['targetType']),
      targetId: _string(json['targetId']),
      summary: _string(json['summary']),
      previousDigest: _nullableString(json['previousDigest']),
      digest: _nullableString(json['digest']),
      sequence: _int(json['sequence']),
      timestamp: _date(json['timestamp']),
    );
  }
}

String _string(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;

String? _nullableString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  return null;
}

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
