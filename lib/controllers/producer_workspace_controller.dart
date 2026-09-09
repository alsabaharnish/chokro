import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/org_member_model.dart';
import '../models/producer_audit_model.dart';
import '../services/organization_service.dart';

/// Shared by the producer workspace and the Admin producer screens.
///
/// One instance: it holds an `http.Client` and a `FirebaseAuth` reference and
/// nothing else, so sharing costs nothing and avoids a second connection pool.
final organizationServiceProvider = Provider<OrganizationService>(
  (ref) => OrganizationService(),
);

/// The producer workspace's first frame (EPR-3).
///
/// One call, not three streams. Which organisation this account belongs to,
/// what it may do there, and whether the account is ready to work are three
/// facts that must be true *together* — a screen assembled from three
/// independently-arriving answers can render a member of one organisation
/// beside another organisation's name for a frame, and in a compliance
/// workspace that frame is a screenshot somebody will send to a regulator.
final producerWorkspaceProvider = FutureProvider.autoDispose<ProducerWorkspace>(
  (ref) => ref.watch(organizationServiceProvider).loadWorkspace(),
);

/// This organisation's members and outstanding invitations.
///
/// Invitations are fetched only for an owner, because only an owner may read
/// them — asking as a viewer would produce a 403 the screen would then have to
/// explain away. The two are loaded together so the members list can show a
/// pending invitation beside the people who have actually joined; an invitation
/// that is invisible until redeemed is an invitation nobody remembers sending.
final orgMembersProvider = FutureProvider.autoDispose<OrgMembership>((
  ref,
) async {
  final service = ref.watch(organizationServiceProvider);
  final workspace = await ref.watch(producerWorkspaceProvider.future);

  if (!workspace.isReady) {
    return const OrgMembership(members: [], invitations: []);
  }

  final members = await service.listMembers();
  final invitations = workspace.can(OrgRoles.owner)
      ? await service.listInvitations()
      : const <OrgInvitation>[];

  return OrgMembership(members: members, invitations: invitations);
});

/// This organisation's own activity trail (EPR-44).
final orgActivityProvider = FutureProvider.autoDispose<List<ProducerAuditEntry>>(
  (ref) => ref.watch(organizationServiceProvider).listActivity(),
);

/// The members screen's two lists, resolved together.
class OrgMembership {
  const OrgMembership({required this.members, required this.invitations});

  final List<OrgMemberModel> members;
  final List<OrgInvitation> invitations;

  /// People who have actually joined, most privileged first, then by name.
  ///
  /// Removed memberships are kept out of the list rather than shown greyed:
  /// this screen answers "who has access", and a removed person does not.
  /// Their record survives in the audit trail, which is where the question
  /// "who *had* access in September" belongs.
  List<OrgMemberModel> get active {
    final rows = members.where((m) => m.isActive).toList();
    rows.sort((a, b) {
      final byRole = OrgRoles.ordered
          .indexOf(a.orgRole)
          .compareTo(OrgRoles.ordered.indexOf(b.orgRole));
      if (byRole != 0) return byRole;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return rows;
  }

  List<OrgInvitation> get pending =>
      invitations.where((i) => i.isPending).toList(growable: false);

  int get ownerCount =>
      members.where((m) => m.isActive && m.orgRole == OrgRoles.owner).length;

  /// Whether removing or demoting [uid] would leave the organisation ownerless.
  ///
  /// The server refuses it too, in the same transaction as the change. This
  /// copy exists so the screen can grey the control and say why, rather than
  /// offering an action that comes back as an error a second later.
  bool wouldOrphan(OrgMemberModel member) =>
      member.orgRole == OrgRoles.owner && member.isActive && ownerCount <= 1;
}

/// Membership actions. Every one is a server call (SEC-4).
class ProducerMemberActions {
  const ProducerMemberActions(this._ref);

  final Ref _ref;

  OrganizationService get _service => _ref.read(organizationServiceProvider);

  Future<OrgInvitation> invite({
    required String email,
    required String orgRole,
  }) async {
    final invitation = await _service.invite(email: email, orgRole: orgRole);
    _refresh();
    return invitation;
  }

  Future<void> revokeInvitation(String invitationId) async {
    await _service.revokeInvitation(invitationId);
    _refresh();
  }

  Future<void> changeRole({
    required String uid,
    required String orgRole,
  }) async {
    await _service.changeMemberRole(uid: uid, orgRole: orgRole);
    _refresh();
  }

  Future<void> remove(String uid) async {
    await _service.removeMember(uid);
    _refresh();
  }

  /// Both lists, because every one of these actions is also an audit entry and
  /// the timeline is on the same screen.
  void _refresh() {
    _ref.invalidate(orgMembersProvider);
    _ref.invalidate(orgActivityProvider);
  }
}

final producerMemberActionsProvider = Provider<ProducerMemberActions>(
  ProducerMemberActions.new,
);
