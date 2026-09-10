import 'package:chokro/core/compliance_math.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/models/organization_model.dart';
import 'package:chokro/models/plastic_passport_model.dart';
import 'package:chokro/models/put_on_market_model.dart';
import 'package:chokro/core/carbon_math.dart';
import 'package:chokro/controllers/compliance_controller.dart';
import 'package:chokro/services/compliance_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The collection percentage exists exactly when a declaration was filed
/// (EPR-24 to EPR-26, EPR-42).
///
/// Phase D's exit criterion names this in one clause: "the collection
/// percentage appears only because a declaration was filed". Every test here is
/// a way of getting that wrong.
void main() {
  group('the obligation year for a reporting period', () {
    OrganizationModel orgStarting(DateTime start) => OrganizationModel(
      id: 'org_cola',
      legalName: 'Coca-Cola Bangladesh Beverages Ltd.',
      tradeName: 'Coca-Cola Bangladesh',
      status: OrgStatus.active,
      obligationStartDate: start,
    );

    test('counts the very first obligated month, across the Dhaka offset', () {
      // The regression. An obligation start of 1 July 2026 is stored as UTC
      // midnight; the July 2026 reporting period begins at Dhaka midnight,
      // which is 2026-06-30T18:00:00Z. Compared as instants, the producer's
      // first obligated period appears to precede its own obligation by six
      // hours — and a null obligation year means no target is shown at all.
      final org = orgStarting(DateTime.utc(2026, 7, 1));

      expect(org.obligationYearForPeriod('2026-07'), 1);
      expect(org.obligationYearForPeriod('2026-06'), isNull);
    });

    test('agrees with the server, case for case', () {
      // §5.3: a deliberate duplicate is only safe if something proves the two
      // stay in step. These are the same cases `server/test/passports.test.js`
      // asserts for `obligationYearAt`; the certificate and the dashboard must
      // print the same law beside the same period.
      final org = orgStarting(DateTime.utc(2026, 7, 1));

      expect(org.obligationYearForPeriod('2026-07'), 1);
      expect(org.obligationYearForPeriod('2027-06'), 1);
      expect(org.obligationYearForPeriod('2027-07'), 2);
      expect(org.obligationYearForPeriod('2029-07'), 4);
      expect(org.obligationYearForPeriod('2026-06'), isNull);
    });

    test('ignores the day of the month', () {
      // A reporting period cannot be half in one obligation year and half in
      // the next.
      expect(
        orgStarting(DateTime.utc(2026, 7, 1)).obligationYearForPeriod('2027-07'),
        2,
      );
      expect(
        orgStarting(DateTime.utc(2026, 7, 31)).obligationYearForPeriod('2027-07'),
        2,
      );
    });

    test('resolves the target the gazette sets for each year', () {
      final org = orgStarting(DateTime.utc(2026, 7, 1));

      expect(org.collectionTargetForPeriod('2026-07'), 0.15);
      expect(org.collectionTargetForPeriod('2028-06'), 0.15);
      expect(org.collectionTargetForPeriod('2028-07'), 0.30);
    });

    test('is null with no recorded start date, and shows no target', () {
      // EPR-26. A producer whose obligation start has not been recorded has no
      // threshold to be compared against, and guessing "probably year 1" would
      // put a compliance verdict on screen Chokro has no basis for.
      final org = OrganizationModel(
        id: 'org_new',
        legalName: 'New Ltd',
        tradeName: 'New',
        status: OrgStatus.active,
      );

      expect(org.obligationYearForPeriod('2026-09'), isNull);
      expect(org.collectionTargetForPeriod('2026-09'), isNull);
    });

    test('is null for something that is not a period', () {
      final org = orgStarting(DateTime.utc(2026, 7, 1));
      for (final bad in ['2026-9', '2026', 'September', '', '2026-13']) {
        expect(org.obligationYearForPeriod(bad), isNull, reason: bad);
      }
    });
  });

  group('the collection position', () {
    CompliancePosition build({
      Map<String, int> collected = const {'rigid': 5000000000},
      Map<String, int>? declared,
      double? target,
      int? obligationYear,
    }) => CompliancePosition.from(
      periodId: '2026-09',
      collectedMassMgByCategory: collected,
      declaredMassMgByCategory: declared,
      applicableCollectionTarget: target,
      obligationYear: obligationYear,
    );

    test('has no rate at all without a declaration (EPR-24)', () {
      final position = build(declared: null);

      // Null, and not zero. Zero is a figure; this is the absence of one, and
      // a producer must be able to tell "we collected nothing" from "we have
      // not told Chokro our volume".
      expect(position.overall.rate, isNull);
      expect(position.overall.percentLabel, isNull);
      expect(position.overall.absence, RateAbsence.noDeclaration);
      expect(position.hasDeclaration, isFalse);
    });

    test('has a rate the moment one is filed', () {
      final position = build(declared: {'rigid': 18000000000});

      expect(position.overall.rate, closeTo(5000000000 / 18000000000, 1e-12));
      expect(position.overall.percentLabel, '27.8%');
    });

    test('distinguishes an undeclared category from a nil one (EPR-42)', () {
      final undeclared = build(
        collected: {'rigid': 100, 'flexible': 50},
        declared: {'rigid': 1000},
      );
      final nil = build(
        collected: {'rigid': 100, 'flexible': 50},
        declared: {'rigid': 1000, 'flexible': 0},
      );

      expect(
        undeclared.byCategory['flexible']!.absence,
        RateAbsence.categoryNotDeclared,
      );
      expect(nil.byCategory['flexible']!.absence, RateAbsence.declaredNil);
      // Neither has a rate — but for different reasons, and the screen says
      // which.
      expect(undeclared.byCategory['flexible']!.rate, isNull);
      expect(nil.byCategory['flexible']!.rate, isNull);
    });

    test('surfaces mass collected in a category that was not declared', () {
      final position = build(
        collected: {'rigid': 100, 'flexible': 50, 'eps': 25},
        declared: {'rigid': 1000},
      );

      // The numerator counts mass the denominator is missing, which flatters
      // the rate. Chokro says so rather than leaving the reader to notice.
      expect(position.collectedButNotDeclared, containsAll(['flexible', 'eps']));
    });

    test('shows no target when the obligation year is unknown (EPR-26)', () {
      final position = build(declared: {'rigid': 18000000000});

      expect(position.applicableCollectionTarget, isNull);
      expect(position.overallComparison, TargetComparison.notComparable);
      expect(position.overallSurplusMassMg, isNull);
    });

    test('compares against the target when there is one', () {
      final below = build(
        collected: {'rigid': 1000},
        declared: {'rigid': 10000},
        target: 0.15,
        obligationYear: 1,
      );
      final above = build(
        collected: {'rigid': 5000},
        declared: {'rigid': 10000},
        target: 0.15,
        obligationYear: 1,
      );

      expect(below.overallComparison, TargetComparison.belowTarget);
      expect(above.overallComparison, TargetComparison.atOrAboveTarget);
    });

    test('a nil declaration is not a denominator', () {
      final position = build(
        collected: {'rigid': 5000},
        declared: {'rigid': 0},
      );

      // A percentage against nil would not mean anything, and infinity is not
      // a compliance figure.
      expect(position.overall.rate, isNull);
      expect(position.overall.absence, RateAbsence.declaredNil);
    });

    test('orders categories by the gazette, not by insertion', () {
      final position = build(
        collected: {'other': 1, 'rigid': 1, 'eps': 1},
        declared: {'other': 10, 'rigid': 10, 'eps': 10},
      );

      expect(position.byCategory.keys.toList(), ['rigid', 'eps', 'other']);
    });
  });

  group('a draft declaration', () {
    test('is not usable as a denominator', () {
      final draft = PutOnMarketDeclaration.fromJson({
        'orgId': 'org_cola',
        'periodId': '2026-09',
        'status': DeclarationStatus.draft,
        'version': 0,
        'lines': [
          {'category': 'rigid', 'units': 100, 'massMg': 18000000000},
        ],
      });

      // A draft carries no attestation, so certifying against it would let a
      // producer set its own denominator without signing for it.
      expect(draft.isUsable, isFalse);
      expect(draft.totalMassMg, isNull);
      expect(draft.massMgFor('rigid'), isNull);
    });

    test('becomes usable once submitted', () {
      final filed = PutOnMarketDeclaration.fromJson({
        'orgId': 'org_cola',
        'periodId': '2026-09',
        'status': DeclarationStatus.submitted,
        'version': 1,
        'attestedByName': 'Nasrin Akhter',
        'lines': [
          {'category': 'rigid', 'units': 100, 'massMg': 18000000000},
        ],
      });

      expect(filed.isUsable, isTrue);
      expect(filed.totalMassMg, 18000000000);
      expect(filed.massMgFor('rigid'), 18000000000);
      // Null, not zero, for a category the filing does not mention (EPR-42).
      expect(filed.massMgFor('flexible'), isNull);
    });
  });

  auditRegressions();

  group('a passport as the workspace sees it', () {
    PlasticPassportModel parse(Map<String, dynamic> overrides) =>
        PlasticPassportModel.fromJson({
          'serial': 'CHKR-PP-9F2K-7T4D',
          'periodId': '2026-09',
          'status': 'issued',
          'contentHash': 'a' * 64,
          ...overrides,
        });

    test('an unrecognised status does not read as safe to send', () {
      // A state this client does not know about would almost certainly be
      // another kind of withdrawal, so it must not default to current.
      final unknown = parse({'status': 'quarantined'});

      expect(unknown.status, 'unknown');
      expect(unknown.isCurrent, isFalse);
      expect(unknown.isSafeToCirculate, isFalse);
    });

    test('a superseded certificate reports why and what replaced it', () {
      final superseded = parse({
        'status': 'superseded',
        'supersededBy': 'CHKR-PP-M4XT-2W7B',
        'supersededReason': 'The declaration was corrected.',
      });

      expect(superseded.isSafeToCirculate, isFalse);
      expect(superseded.supersededBy, 'CHKR-PP-M4XT-2W7B');
      expect(superseded.withdrawalReason, 'The declaration was corrected.');
    });

    test('a revoked certificate reports its revocation reason', () {
      final revoked = parse({
        'status': 'revoked',
        'revocationReason': 'An accuracy audit invalidated the batch.',
      });

      expect(revoked.withdrawalReason, contains('accuracy audit'));
      expect(
        PassportStatus.explain('revoked'),
        contains('should not be relied on'),
      );
    });

    test('carries no figures', () {
      // A figure reaching a screen from two places will eventually be rendered
      // from the wrong one. The workspace reads its position from `eprPeriods`;
      // the certificate's own figures live in the PDF that was issued.
      final passport = parse({
        'figures': {'collectionRate': 0.95, 'collectedMassMg': 999},
      });

      expect(passport.serial, 'CHKR-PP-9F2K-7T4D');
      expect(passport.toString(), isNot(contains('0.95')));
    });

    test('shortens the hash without losing the full one', () {
      final passport = parse({'contentHash': '4025fd34${'0' * 56}'});

      expect(passport.shortHash, '4025fd34');
      expect(passport.contentHash.length, 64);
    });
  });
}

/// The regressions the second audit pass found (all confirmed, all fixed).
///
/// Each of these produced a FALSE STATEMENT on a producer-facing screen rather
/// than an error, which is why none of them was caught by the suite that
/// already covered the same code.
void auditRegressions() {
  group('a failed declaration read is not an absent declaration', () {
    test('the failure carries its own type', () {
      // `ComplianceService.loadDeclaration` returns a failure as DATA so the
      // declaration screen can explain it. Without a guard, that arrives at
      // `CompliancePosition.from` as `declaration: null` and renders as
      // "No percentage without a declaration" — telling a producer that has
      // filed that its filing is missing, because a request timed out.
      const failure = ComplianceUnavailable('The service is waking up.');
      expect(failure.message, contains('waking up'));
      expect(failure, isA<Exception>());
    });

    test('a failed detail is distinguishable from an empty one', () {
      final failed = DeclarationDetail.failed('The service is waking up.');
      const empty = DeclarationDetail(
        periodId: '2026-09',
        declaration: null,
        versions: [],
        attestationText: 'x',
      );

      expect(failed.hasError, isTrue);
      expect(empty.hasError, isFalse);
      // Both have no declaration — which is exactly why `hasError` has to be
      // consulted and not just `declaration == null`.
      expect(failed.declaration, isNull);
      expect(empty.declaration, isNull);
    });
  });

  group('the carbon figure', () {
    test('does not round a small estimate away to zero', () {
      // `kg.round()` printed "0 kg CO2e avoided" for any period under about
      // half a kilogram, which on an SDG card reads as a measured zero rather
      // than as a small number.
      final small = carbonAvoided(
        massMg: 400000, // 0.4 kg collected -> ~0.41 kg CO2e
        factor: turnerMixedPlastics2015,
        estimatedShare: 0,
        uncertaintyCeiling: carbonUncertaintyCeiling,
      );

      expect(small.kgCo2eAvoided, greaterThan(0));
      expect(small.label, isNot(startsWith('0 ')));
      expect(small.label, contains('kg CO'));
    });

    test('states three significant figures and no trailing zeros', () {
      final estimate = carbonAvoided(
        massMg: 1000000000,
        factor: turnerMixedPlastics2015,
        estimatedShare: 0,
        uncertaintyCeiling: carbonUncertaintyCeiling,
      );

      // 1024 kg to 3 s.f. is 1020, not 1020.0 — a tenth of a kilogram of
      // claimed precision on an indicative estimate.
      expect(estimate.label, '1020 kg CO₂e');
    });

    test('has no label at all when there is no figure', () {
      final refused = carbonAvoided(
        massMg: 1000000000,
        factor: turnerMixedPlastics2015,
        estimatedShare: 0.9,
        uncertaintyCeiling: 0.25,
      );

      expect(refused.kgCo2eAvoided, isNull);
      expect(refused.label, isNull);
      expect(refused.absence, CarbonAbsence.tooUncertain);
    });
  });

  group('the client’s carbon ceiling', () {
    test('matches the server default, as the fallback', () {
      // Not the authority. `ComplianceService.loadPolicy` reads the server's
      // value; this applies only when that read fails, and it is the same
      // number so the two agree unless an Admin has changed it.
      expect(carbonUncertaintyCeiling, 0.25);
    });

    test('a lowered server ceiling refuses a figure the constant would allow', () {
      // The divergence that mattered: an Admin lowering the ceiling makes the
      // certificate omit a carbon figure, and a client using the constant
      // would keep showing one.
      const massMg = 1000000000;
      const share = 0.15;

      final withConstant = carbonAvoided(
        massMg: massMg,
        factor: turnerMixedPlastics2015,
        estimatedShare: share,
        uncertaintyCeiling: carbonUncertaintyCeiling,
      );
      final withLoweredPolicy = carbonAvoided(
        massMg: massMg,
        factor: turnerMixedPlastics2015,
        estimatedShare: share,
        uncertaintyCeiling: 0.10,
      );

      expect(withConstant.kgCo2eAvoided, isNotNull);
      expect(withLoweredPolicy.kgCo2eAvoided, isNull);
      expect(withLoweredPolicy.absence, CarbonAbsence.tooUncertain);
    });
  });

  group('a nil declaration is reported as nil, not as absent', () {
    test('the absence reason distinguishes them', () {
      // The SDG headline printed "no declaration has been filed" for a
      // producer that filed a nil declaration — the same false statement
      // EPR-42 is about, on the page most likely to be screenshotted.
      final noneFiled = CompliancePosition.from(
        periodId: '2026-09',
        collectedMassMgByCategory: {'rigid': 5000},
        declaredMassMgByCategory: null,
      );
      final filedNil = CompliancePosition.from(
        periodId: '2026-09',
        collectedMassMgByCategory: {'rigid': 5000},
        declaredMassMgByCategory: {'rigid': 0},
      );

      expect(noneFiled.overall.absence, RateAbsence.noDeclaration);
      expect(filedNil.overall.absence, RateAbsence.declaredNil);
      expect(noneFiled.overall.absence, isNot(filedNil.overall.absence));
    });
  });
}
