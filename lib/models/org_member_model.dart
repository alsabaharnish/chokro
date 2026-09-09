/// Chokro — organisation membership (EPR-3, SEC-1, §5.1).
///
/// Plain Dart, no Firebase imports (§5.1).
library;

import '../core/constants.dart';

/// One person's membership of one producer organisation.
///
/// ## The composite id is a security decision, not a convenience
///
/// The document key is `{orgId}_{uid}`, so `firestore.rules` can answer "is
/// this user a member of that organisation, and in what capacity?" with a
/// single `get()` on a path it composes itself — no query, no index, no
/// client-supplied `orgId` believed on its word (SEC-1).
///
/// Tenant isolation is the primary control in this feature: the worst incident
/// this product can have is one company reading another's compliance position.
/// A membership check that needed a query would have to trust something in the
/// request to build that query, and the rules engine caps document reads at ten
/// per request — so the cheap, unforgeable, single-read shape is the one that
/// survives contact with real screens.
///
/// Every field is server-owned. There is no client write path to membership at
/// all: an invitation is issued by the service, redeemed against a token, and
/// revoked by the service (SEC-8). A client that could write this document
/// could add itself to any organisation on the platform.
class OrgMemberModel {
  const OrgMemberModel({
    required this.orgId,
    required this.uid,
    required this.orgRole,
    required this.status,
    this.email = '',
    this.displayName = '',
    this.invitedBy = '',
    this.invitedAt,
    this.activatedAt,
    this.removedAt,
  });

  final String orgId;
  final String uid;

  /// One of [OrgRoles].
  final String orgRole;

  /// One of [OrgMemberStatus].
  final String status;

  /// The work email the invitation was bound to.
  ///
  /// Kept on the membership as well as on the account because an invitation is
  /// bound to an exact address (SEC-8), and the members screen has to be able
  /// to show a pending invitation that has no account behind it yet.
  final String email;

  final String displayName;

  final String invitedBy;
  final DateTime? invitedAt;
  final DateTime? activatedAt;
  final DateTime? removedAt;

  /// Whether this membership currently carries any capability at all.
  ///
  /// An `invited` membership carries none. The invitation has been sent and not
  /// redeemed, and a pending invitation that granted read access would make the
  /// invitation token pointless — the address alone would be enough.
  bool get isActive => status == OrgMemberStatus.active;

  bool get isPendingInvitation => status == OrgMemberStatus.invited;

  bool get isRemoved => status == OrgMemberStatus.removed;

  /// Whether this member holds at least [required] capability *right now*.
  ///
  /// Both halves matter and both are checked here: a removed owner is not an
  /// owner, and a pending invitation to be an owner is not an owner either.
  ///
  /// This is the interface's copy of the question. The enforcing copies are
  /// `requireOrgRole` on the server and the membership rules in
  /// `firestore.rules`; all three must agree, and this one exists so a screen
  /// can decline to offer an action rather than offering one the server will
  /// refuse (SEC-5).
  bool can(String required) => isActive && OrgRoles.atLeast(orgRole, required);

  bool get canManageMembers => can(OrgRoles.owner);
  bool get canSubmitDeclaration => can(OrgRoles.owner);
  bool get canEditSkus => can(OrgRoles.reporter);
  bool get canGenerateReports => can(OrgRoles.reporter);
  bool get canRead => isActive;

  /// The composite document id for a membership.
  ///
  /// One function, used by the client, the server and the rules tests, so the
  /// three cannot drift into composing the key differently — which would show
  /// up as a member who exists and cannot be found.
  static String documentId(String orgId, String uid) => '${orgId}_$uid';

  factory OrgMemberModel.fromJson(
    Map<String, dynamic> json, {
    String? id,
  }) {
    // The stored fields are authoritative; the id is the fallback for a
    // document written before both were stored. Splitting on the *first*
    // underscore is wrong for a uid that contains one, so the id is only used
    // when the fields are absent, and even then only for the org half.
    final storedOrgId = _string(json['orgId']);
    final storedUid = _string(json['uid']);

    return OrgMemberModel(
      orgId: storedOrgId.isNotEmpty
          ? storedOrgId
          : _orgIdFromDocumentId(id, storedUid),
      uid: storedUid,
      // Fail closed. An unrecognised role grants nothing, because `can()` runs
      // it through `OrgRoles.atLeast`, which returns false for anything not in
      // the ordered list — but naming the fallback explicitly says so.
      orgRole: OrgRoles.isValid(_string(json['orgRole']))
          ? _string(json['orgRole'])
          : OrgRoles.viewer,
      status: OrgMemberStatus.all.contains(_string(json['status']))
          ? _string(json['status'])
          : OrgMemberStatus.removed,
      email: _string(json['email']),
      displayName: _string(json['displayName']),
      invitedBy: _string(json['invitedBy']),
      invitedAt: _date(json['invitedAt']),
      activatedAt: _date(json['activatedAt']),
      removedAt: _date(json['removedAt']),
    );
  }
}

/// Recovers the org half of a composite id when the document predates the
/// stored `orgId` field.
///
/// Returns empty rather than guessing when the uid suffix is not present — an
/// empty `orgId` fails every membership check, which is the safe direction.
String _orgIdFromDocumentId(String? id, String uid) {
  if (id == null || uid.isEmpty) return '';
  final suffix = '_$uid';
  if (!id.endsWith(suffix)) return '';
  return id.substring(0, id.length - suffix.length);
}

String _string(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
