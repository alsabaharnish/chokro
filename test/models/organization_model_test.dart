import 'package:chokro/core/constants.dart';
import 'package:chokro/core/epr_categories.dart';
import 'package:chokro/models/organization_model.dart';
import 'package:flutter_test/flutter_test.dart';

OrganizationModel _parse(Map<String, dynamic> json) =>
    OrganizationModel.fromJson(json, id: 'org-1');

void main() {
  group('parsing', () {
    test('reads a complete document', () {
      final org = _parse({
        'legalName': 'Coca-Cola Bangladesh Beverages Ltd',
        'tradeName': 'Coca-Cola Bangladesh',
        'bin': '1234567890123',
        'tradeLicenceNo': 'TRAD/DNCC/012345',
        'doeRegistrationNo': 'DoE-EPR-2026-0042',
        'sizeClass': OrgSizeClass.large,
        'obligationStartDate': DateTime.utc(2026, 8, 13),
        'complianceRoute': ComplianceRoute.self,
        'status': OrgStatus.active,
        'categories': [GazetteCategory.flexible, GazetteCategory.rigid],
        'contactName': 'Compliance Officer',
        'contactEmail': 'compliance@example.com',
        'district': 'Dhaka',
      });

      expect(org.id, 'org-1');
      expect(org.legalName, 'Coca-Cola Bangladesh Beverages Ltd');
      expect(org.displayName, 'Coca-Cola Bangladesh');
      expect(org.sizeClass, OrgSizeClass.large);
      expect(org.isActive, isTrue);
      expect(org.isReadOnly, isFalse);
      expect(org.district, 'Dhaka');
    });

    test('categories come back in gazette order, deduplicated', () {
      // Stored order is whatever an Admin happened to tick. Two organisations
      // whose category lists render in different orders look like they disagree.
      final org = _parse({
        'categories': [
          GazetteCategory.other,
          GazetteCategory.rigid,
          GazetteCategory.rigid,
          GazetteCategory.flexible,
        ],
      });
      expect(org.categories, [
        GazetteCategory.rigid,
        GazetteCategory.flexible,
        GazetteCategory.other,
      ]);
    });

    test('an unrecognised category is dropped rather than displayed', () {
      final org = _parse({
        'categories': [GazetteCategory.rigid, 'compostable', 7, null],
      });
      expect(org.categories, [GazetteCategory.rigid]);
    });

    test('a missing or malformed status fails closed to pending review', () {
      expect(_parse({}).status, OrgStatus.pendingReview);
      expect(_parse({'status': 'active '}).status, OrgStatus.pendingReview);
      expect(_parse({'status': 99}).status, OrgStatus.pendingReview);
      // The consequence that matters: neither opens a workspace.
      expect(_parse({'status': 'anything'}).isActive, isFalse);
      expect(_parse({'status': 'anything'}).isReadOnly, isTrue);
    });

    test('an unrecognised size class is null, not a guess', () {
      // A wrong size class picks the wrong gazette target, which is the one
      // thing EPR-26 forbids printing beside a producer's own figure.
      final org = _parse({'sizeClass': 'enormous'});
      expect(org.sizeClass, isNull);
      expect(org.collectionTargetAt(DateTime.utc(2027)), isNull);
    });

    test('an absent DoE registration is a normal state', () {
      final org = _parse({'status': OrgStatus.active});
      expect(org.doeRegistrationNo, isNull);
      expect(org.isActive, isTrue);
    });

    test('a document with nothing in it does not throw', () {
      final org = _parse({});
      expect(org.legalName, '');
      expect(org.displayName, '');
      expect(org.categories, isEmpty);
      expect(org.obligationStartDate, isNull);
    });
  });

  group('status', () {
    test('a suspended organisation is read-only but not gone', () {
      final org = _parse({'status': OrgStatus.suspended});
      expect(org.isActive, isFalse);
      expect(org.isReadOnly, isTrue);
      expect(org.isAwaitingReview, isFalse);
    });

    test('a pending organisation is awaiting review and read-only', () {
      final org = _parse({'status': OrgStatus.pendingReview});
      expect(org.isAwaitingReview, isTrue);
      expect(org.isReadOnly, isTrue);
    });
  });

  group('obligation year and gazette targets', () {
    OrganizationModel withStart(DateTime start) =>
        _parse({'obligationStartDate': start, 'status': OrgStatus.active});

    test('the first year of obligation is year 1', () {
      final org = withStart(DateTime.utc(2026, 8, 13));
      expect(org.obligationYearAt(DateTime.utc(2026, 8, 13)), 1);
      expect(org.obligationYearAt(DateTime.utc(2027, 8, 12)), 1);
    });

    test('the anniversary starts year 2', () {
      final org = withStart(DateTime.utc(2026, 8, 13));
      expect(org.obligationYearAt(DateTime.utc(2027, 8, 13)), 2);
      expect(org.obligationYearAt(DateTime.utc(2028, 8, 12)), 2);
    });

    test('years 1 and 2 carry the 15% and 7.5% targets', () {
      final org = withStart(DateTime.utc(2026, 8, 13));
      expect(org.collectionTargetAt(DateTime.utc(2027, 1)), 0.15);
      expect(org.recyclingTargetAt(DateTime.utc(2027, 1)), 0.075);
      expect(org.collectionTargetAt(DateTime.utc(2028, 1)), 0.15);
    });

    test('year 3 onward carries the 30% and 15% targets', () {
      final org = withStart(DateTime.utc(2026, 8, 13));
      expect(org.obligationYearAt(DateTime.utc(2028, 8, 13)), 3);
      expect(org.collectionTargetAt(DateTime.utc(2028, 8, 13)), 0.30);
      expect(org.recyclingTargetAt(DateTime.utc(2028, 8, 13)), 0.15);
      expect(org.collectionTargetAt(DateTime.utc(2031, 1)), 0.30);
    });

    test('a leap year does not shift the anniversary', () {
      // 2028 is a leap year. Counting elapsed days rather than anniversaries
      // would move a February boundary by one day, and a boundary error in an
      // annual filing is a compliance error.
      final org = withStart(DateTime.utc(2027, 3, 1));
      expect(org.obligationYearAt(DateTime.utc(2028, 2, 29)), 1);
      expect(org.obligationYearAt(DateTime.utc(2028, 3, 1)), 2);
    });

    test('a date before the obligation starts has no year and no target', () {
      final org = withStart(DateTime.utc(2027, 1, 1));
      expect(org.obligationYearAt(DateTime.utc(2026, 12, 31)), isNull);
      expect(org.collectionTargetAt(DateTime.utc(2026, 12, 31)), isNull);
    });

    test('no obligation start date means no target is displayed', () {
      final org = _parse({'status': OrgStatus.active});
      expect(org.obligationYearAt(DateTime.utc(2027)), isNull);
      expect(org.collectionTargetAt(DateTime.utc(2027)), isNull);
      expect(org.recyclingTargetAt(DateTime.utc(2027)), isNull);
    });
  });

  group('the application payload', () {
    test('carries only the fields an applicant may propose', () {
      final org = OrganizationModel(
        id: 'org-1',
        legalName: 'Legal Ltd',
        tradeName: 'Trade',
        status: OrgStatus.active,
        sizeClass: OrgSizeClass.large,
        bin: '123',
        contactEmail: 'a@b.com',
        verifiedBy: 'admin-1',
      );

      final json = org.toApplicationJson();

      // Every server-owned key is absent. The rules reject any key beyond this
      // allowlist, so a client that grew one here would be refused — but the
      // point is that the client never tries.
      for (final serverOwned in [
        'status',
        'sizeClass',
        'bin',
        'tradeLicenceNo',
        'doeRegistrationNo',
        'obligationStartDate',
        'complianceRoute',
        'categories',
        'verifiedBy',
        'verifiedAt',
        'createdAt',
      ]) {
        expect(
          json.containsKey(serverOwned),
          isFalse,
          reason: '$serverOwned is server-owned and must not be proposed',
        );
      }

      expect(json['legalName'], 'Legal Ltd');
      expect(json['contactEmail'], 'a@b.com');
    });
  });

  group('gazette vocabulary', () {
    test('the five categories keep their stored values and order', () {
      expect(GazetteCategory.all, [
        'rigid',
        'flexible',
        'eps',
        'singleUse',
        'other',
      ]);
      expect(GazetteCategory.isValid('rigid'), isTrue);
      expect(GazetteCategory.isValid('compostable'), isFalse);
    });

    test('polymers keep their stored values and resin codes', () {
      expect(PolymerType.all, [
        'pet',
        'hdpe',
        'pvc',
        'ldpe',
        'pp',
        'ps',
        'multilayer',
        'other',
      ]);
      expect(PolymerType.resinCode(PolymerType.pet), 1);
      expect(PolymerType.resinCode(PolymerType.ps), 6);
      // No invented code for a laminate: printing a recycling triangle on
      // something no facility can process is worse than printing nothing.
      expect(PolymerType.resinCode(PolymerType.multilayer), isNull);
      expect(PolymerType.resinCode(PolymerType.other), isNull);
    });

    test('the gazette target table matches the guidelines', () {
      expect(GazetteTargets.collectionRateForYear(1), 0.15);
      expect(GazetteTargets.collectionRateForYear(2), 0.15);
      expect(GazetteTargets.collectionRateForYear(3), 0.30);
      expect(GazetteTargets.recyclingRateForYear(1), 0.075);
      expect(GazetteTargets.recyclingRateForYear(3), 0.15);
      expect(GazetteTargets.reviewDueAfterYears, 3);
    });
  });
}
