import 'package:chokro/core/constants.dart';
import 'package:chokro/models/org_member_model.dart';
import 'package:flutter_test/flutter_test.dart';

OrgMemberModel _parse(Map<String, dynamic> json, {String? id}) =>
    OrgMemberModel.fromJson(json, id: id);

Map<String, dynamic> _member({
  String orgRole = OrgRoles.reporter,
  String status = OrgMemberStatus.active,
}) => {
  'orgId': 'org-1',
  'uid': 'uid-1',
  'orgRole': orgRole,
  'status': status,
  'email': 'engineer@example.com',
};

void main() {
  group('the composite document id', () {
    test('is orgId_uid, and one function composes it everywhere', () {
      expect(OrgMemberModel.documentId('org-1', 'uid-1'), 'org-1_uid-1');
    });

    test('recovers orgId from the id only when the fields are absent', () {
      // Stored fields win. A uid containing an underscore would make splitting
      // the id ambiguous, so the id is a fallback for old documents, not the
      // source of truth.
      final withFields = _parse(
        {'orgId': 'real-org', 'uid': 'a_b'},
        id: 'wrong-org_a_b',
      );
      expect(withFields.orgId, 'real-org');

      final withoutFields = _parse({'uid': 'a_b'}, id: 'real-org_a_b');
      expect(withoutFields.orgId, 'real-org');
    });

    test('an id that does not end in the uid yields no orgId', () {
      // An empty orgId fails every membership check, which is the safe
      // direction for a document that cannot be placed in a tenant.
      final parsed = _parse({'uid': 'uid-1'}, id: 'nonsense');
      expect(parsed.orgId, '');
      expect(parsed.canRead, isFalse);
    });
  });

  group('capability', () {
    test('an owner may manage members and attest a declaration', () {
      final owner = _parse(_member(orgRole: OrgRoles.owner));
      expect(owner.canManageMembers, isTrue);
      expect(owner.canSubmitDeclaration, isTrue);
      expect(owner.canEditSkus, isTrue);
      expect(owner.canRead, isTrue);
    });

    test('a reporter edits SKUs but cannot attest or manage members', () {
      final reporter = _parse(_member(orgRole: OrgRoles.reporter));
      expect(reporter.canEditSkus, isTrue);
      expect(reporter.canGenerateReports, isTrue);
      // SEC-5's stated failure mode: an orgViewer — or here an orgReporter —
      // submitting a legal declaration.
      expect(reporter.canSubmitDeclaration, isFalse);
      expect(reporter.canManageMembers, isFalse);
    });

    test('a viewer reads and writes nothing', () {
      final viewer = _parse(_member(orgRole: OrgRoles.viewer));
      expect(viewer.canRead, isTrue);
      expect(viewer.canEditSkus, isFalse);
      expect(viewer.canGenerateReports, isFalse);
      expect(viewer.canSubmitDeclaration, isFalse);
      expect(viewer.canManageMembers, isFalse);
    });
  });

  group('membership status gates every capability', () {
    test('an invited member holds nothing until the invitation is redeemed', () {
      // Otherwise the invited address alone would be access, and the
      // single-use token in SEC-8 would be decorative.
      final invited = _parse(
        _member(orgRole: OrgRoles.owner, status: OrgMemberStatus.invited),
      );
      expect(invited.isPendingInvitation, isTrue);
      expect(invited.isActive, isFalse);
      expect(invited.canRead, isFalse);
      expect(invited.canManageMembers, isFalse);
      expect(invited.canEditSkus, isFalse);
    });

    test('a removed owner is not an owner', () {
      // SEC-2's failure mode: a dismissed employee exporting the company's data
      // on the way out.
      final removed = _parse(
        _member(orgRole: OrgRoles.owner, status: OrgMemberStatus.removed),
      );
      expect(removed.isRemoved, isTrue);
      expect(removed.canRead, isFalse);
      expect(removed.canManageMembers, isFalse);
      expect(removed.canSubmitDeclaration, isFalse);
    });
  });

  group('malformed documents fail closed', () {
    test('an unrecognised org role degrades to viewer', () {
      final parsed = _parse(_member(orgRole: 'orgSuperuser'));
      expect(parsed.orgRole, OrgRoles.viewer);
      expect(parsed.canEditSkus, isFalse);
      expect(parsed.canManageMembers, isFalse);
    });

    test('an unrecognised status degrades to removed', () {
      final parsed = _parse(_member(status: 'probation'));
      expect(parsed.status, OrgMemberStatus.removed);
      expect(parsed.canRead, isFalse);
    });

    test('an empty document grants nothing and does not throw', () {
      final parsed = _parse({});
      expect(parsed.canRead, isFalse);
      expect(parsed.orgId, '');
      expect(parsed.uid, '');
    });
  });
}
