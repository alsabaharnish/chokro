import 'package:chokro/models/admin_oversight_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Admin oversight models (EPR-43 to EPR-48).
///
/// ===========================================================================
/// THESE TESTS ARE ALL ABOUT ABSENCE
/// ===========================================================================
///
/// The server refuses to invent a figure it has no basis for: a precision over
/// too small a sample, a variance for a period nobody checked, a percentage
/// with no declaration behind it. Each of those arrives as null with a stated
/// reason.
///
/// A client that parsed null into zero would undo all of it in one line — and
/// the damage is asymmetric. A blank on a reconciliation screen reads as
/// "checked and fine". A zero on an accuracy panel reads as "recognition is
/// never right". Both are worse than the truth, which is "we do not know".
void main() {
  group('a reconciliation row', () {
    test('distinguishes never-checked from checked-and-agreed', () {
      // Zero means "checked and agreed". Null means "nobody has looked".
      // Conflating them is how an entirely unverified year looks clean, which
      // is the single most misleading thing this screen could do.
      final unchecked = ReconciliationRow.fromJson({
        'orgId': 'org_a',
        'periodId': '2026-09',
        'incrementedMassMg': 5000000,
      });
      final agreed = ReconciliationRow.fromJson({
        'orgId': 'org_a',
        'periodId': '2026-09',
        'incrementedMassMg': 5000000,
        'recomputedMassMg': 5000000,
        'variance': 0,
        'matched': true,
        'recomputedAt': '2026-10-03T05:12:00Z',
      });

      expect(unchecked.variance, isNull);
      expect(unchecked.matched, isNull);
      expect(unchecked.isChecked, isFalse);

      expect(agreed.variance, 0);
      expect(agreed.matched, isTrue);
      expect(agreed.isChecked, isTrue);
    });

    test('a mismatch is neither checked-clean nor unchecked', () {
      final row = ReconciliationRow.fromJson({
        'orgId': 'org_a',
        'periodId': '2026-09',
        'incrementedMassMg': 5000000,
        'recomputedMassMg': 7000000,
        'variance': 2000000,
        'matched': false,
        'recomputedAt': '2026-10-03T05:12:00Z',
      });

      expect(row.isChecked, isTrue);
      expect(row.isMismatched, isTrue);
      expect(row.variance, 2000000);
    });
  });

  group('the reconciliation overview', () {
    test('reports the never-checked count as a total, not a list length', () {
      // "How much of this has anyone verified?" is the question an auditor
      // asks, and it cannot be read off a bounded list.
      final overview = ReconciliationOverview.fromJson({
        'periodsExamined': 200,
        'reconciled': 40,
        'mismatched': <Map<String, dynamic>>[],
        'uncheckedCount': 160,
        'unchecked': [
          for (var i = 0; i < 50; i++)
            {'orgId': 'org_$i', 'periodId': '2026-09', 'incrementedMassMg': 100},
        ],
        'uncheckedMassMg': 900000000,
      });

      expect(overview.uncheckedCount, 160);
      expect(overview.unchecked.length, 50);
      expect(overview.uncheckedListIsTruncated, isTrue);
      expect(overview.uncheckedShare, closeTo(0.8, 1e-9));
    });

    test('has no coverage share when there is nothing to divide by', () {
      // A platform with no periods has not achieved 100% coverage.
      final empty = ReconciliationOverview.fromJson({
        'periodsExamined': 0,
        'reconciled': 0,
        'uncheckedCount': 0,
        'uncheckedMassMg': 0,
      });

      expect(empty.uncheckedShare, isNull);
    });
  });

  group('the accuracy snapshot', () {
    test('carries no precision below the sample floor, and says why', () {
      final snapshot = AccuracySnapshot.fromJson({
        'reviewed': 3,
        'judged': 3,
        'correct': 3,
        'incorrect': 0,
        'unclear': 0,
        'minSample': 30,
        'precision': null,
        'precisionAbsenceReason':
            'Only 3 sampled matches have been reviewed with a clear verdict.',
        'windowPeriods': ['2026-09'],
        'trend': <Map<String, dynamic>>[],
      });

      // Not 1.0, which is what "3 of 3 correct" would compute to and what a
      // methodology section would then publish.
      expect(snapshot.precision, isNull);
      expect(snapshot.hasPrecision, isFalse);
      expect(snapshot.precisionAbsenceReason, contains('3 sampled'));
    });

    test('never carries a recall figure at all', () {
      // EPR-17 names precision AND recall, and only one is observable from a
      // sample drawn from what the model claimed.
      final snapshot = AccuracySnapshot.fromJson({
        'reviewed': 100,
        'judged': 90,
        'correct': 85,
        'incorrect': 5,
        'unclear': 10,
        'minSample': 30,
        'precision': 85 / 90,
        'recallAbsenceReason':
            'Recall is not measurable from this sample.',
        'windowPeriods': ['2026-09'],
        'trend': <Map<String, dynamic>>[],
      });

      expect(snapshot.hasPrecision, isTrue);
      expect(snapshot.recallAbsenceReason, isNotEmpty);
      // The model has no field for it, so no screen can render one.
      expect(
        snapshot.toString(),
        isNot(contains('recall:')),
      );
    });

    test('reports the unclear share rather than folding it away', () {
      // A high figure here says the PHOTOGRAPHS are the problem rather than the
      // model, which is a different fix.
      final snapshot = AccuracySnapshot.fromJson({
        'reviewed': 60,
        'judged': 40,
        'correct': 40,
        'incorrect': 0,
        'unclear': 20,
        'minSample': 30,
        'precision': 1.0,
        'unclearShare': 20 / 60,
        'windowPeriods': ['2026-09'],
        'trend': <Map<String, dynamic>>[],
      });

      expect(snapshot.precision, 1.0);
      expect(snapshot.judged, 40);
      expect(snapshot.reviewed, 60);
      expect(snapshot.unclearShare, closeTo(1 / 3, 1e-9));
    });

    test('a trend point with no reviews has no precision', () {
      final point = AccuracyTrendPoint.fromJson({
        'periodId': '2026-08',
        'reviewed': 0,
        'judged': 0,
        'precision': null,
      });

      // Not zero — which on a trend line would draw a crash to the floor in a
      // month nobody happened to review anything.
      expect(point.precision, isNull);
      expect(point.judged, 0);
    });
  });

  group('an anomaly finding', () {
    AnomalyFinding parse(Map<String, dynamic> over) =>
        AnomalyFinding.fromJson({
          'id': 'f1',
          'orgId': 'org_cola',
          'periodId': '2026-09',
          'type': 'skuMassSpike',
          'subjectType': 'sku',
          'subjectId': 'sku_a',
          'severity': 'high',
          'status': 'open',
          'summary': 'Attributed mass is 5x its trailing average.',
          'figures': {'observedMultiple': 5.0, 'threshold': 4},
          ...over,
        });

    test('sorts an unrecognised severity to the TOP, not the bottom', () {
      // A future detector Chokro adds should surface loudly rather than settle
      // quietly at the end of a list nobody scrolls.
      expect(AnomalySeverity.rank('quarantine'), lessThan(AnomalySeverity.rank('high')));
      expect(AnomalySeverity.rank('high'), lessThan(AnomalySeverity.rank('medium')));
      expect(AnomalySeverity.rank('medium'), lessThan(AnomalySeverity.rank('low')));
    });

    test('keeps an unrecognised severity verbatim rather than coercing it', () {
      // Coercing to `low` would hide it at the bottom, undoing the ranking
      // above.
      expect(parse({'severity': 'catastrophic'}).severity, 'catastrophic');
    });

    test('marks the one finding that names a person', () {
      // SEC-3. `accountConcentration` carries a Champion's uid, and an Admin
      // sharing a screenshot of the queue should know which row that is.
      expect(parse({'subjectType': 'account'}).namesAPerson, isTrue);
      expect(parse({'subjectType': 'sku'}).namesAPerson, isFalse);
      expect(parse({'subjectType': 'bin'}).namesAPerson, isFalse);
    });

    test('keeps the figures, including the threshold in force at the time', () {
      // A finding read six months later must be judged against the policy of
      // its own moment rather than today's.
      final finding = parse({});
      expect(finding.figures['threshold'], 4);
      expect(finding.figures['observedMultiple'], 5.0);
    });

    test('an unrecognised status does not read as open', () {
      expect(parse({'status': 'escalated'}).isOpen, isFalse);
    });
  });

  group('a certificate in the register', () {
    IssuedCertificate parse(Map<String, dynamic> over) =>
        IssuedCertificate.fromJson({
          'serial': 'CHKR-PP-9F2K-7T4D',
          'orgId': 'org_cola',
          'tradeName': 'Coca-Cola Bangladesh',
          'periodId': '2026-09',
          'status': 'issued',
          'contentHash': 'a' * 64,
          'collectedMassMg': 5000000000,
          ...over,
        });

    test('has no percentage when no declaration was filed', () {
      // Null, never zero. Zero would say the producer collected none of what
      // they placed on the market (EPR-24).
      expect(parse({'collectionRate': null}).collectionRate, isNull);
      expect(parse({'collectionRate': 0.28}).collectionRate, closeTo(0.28, 1e-9));
    });

    test('reports why a withdrawn certificate no longer stands', () {
      expect(
        parse({
          'status': 'revoked',
          'revocationReason': 'An accuracy audit invalidated the batch.',
        }).withdrawalReason,
        contains('accuracy audit'),
      );
      expect(
        parse({
          'status': 'superseded',
          'supersededReason': 'The declaration was corrected.',
        }).withdrawalReason,
        contains('corrected'),
      );
      expect(parse({}).withdrawalReason, isNull);
    });

    test('is standing only when issued', () {
      expect(parse({}).isStanding, isTrue);
      for (final status in ['superseded', 'revoked', 'quarantined']) {
        expect(parse({'status': status}).isStanding, isFalse, reason: status);
      }
    });
  });

  group('the issuance register', () {
    test('says when it has truncated', () {
      // A register that silently truncated would be the worst possible answer
      // to "which certificates are affected by this fault".
      final register = IssuanceRegister.fromJson({
        'passports': <Map<String, dynamic>>[],
        'counts': {'issued': 4, 'superseded': 1, 'revoked': 0},
        'truncated': true,
      });

      expect(register.truncated, isTrue);
      expect(register.issued, 4);
      expect(register.superseded, 1);
      expect(register.revoked, 0);
    });
  });

  group('the activity timeline', () {
    ActivityTimeline parse(Map<String, dynamic> over) =>
        ActivityTimeline.fromJson({
          'orgId': 'org_cola',
          'entries': [
            {
              'sequence': 2,
              'action': 'passport.issued',
              'actorUid': 'uid_admin',
              'actorName': 'Chokro Compliance',
              'actorRole': 'admin',
              'summary': 'Issued CHKR-PP-9F2K-7T4D.',
            },
            {
              'sequence': 1,
              'action': 'declaration.submitted',
              'actorUid': 'uid_owner',
              'actorName': 'Nasrin Akhter',
              'actorRole': 'orgOwner',
              'summary': 'Filed 27,400 kg.',
            },
          ],
          ...over,
        });

    test('tells Chokro apart from the producer on every row', () {
      // The distinction EPR-46 exists to preserve: an audit trail that cannot
      // tell the two apart is not an audit trail.
      final entries = parse({}).entries;
      expect(entries.firstWhere((e) => e.sequence == 2).byChokro, isTrue);
      expect(entries.firstWhere((e) => e.sequence == 1).byChokro, isFalse);
    });

    test('reports an unchecked chain as null, not as false', () {
      // "Not checked" and "checked and failed" are different statements, and a
      // screen that conflated them would either alarm nobody or alarm
      // everybody.
      expect(parse({}).verified, isNull);
      expect(parse({'verified': true}).verified, isTrue);
      expect(parse({'verified': false}).verified, isFalse);
    });

    test('says whether an intact chain is keyed', () {
      // An unkeyed chain is tamper-evident against anyone WITHOUT write access
      // and is not evidence against an insider holding the database
      // credential. Printing "intact" without saying which overstates it.
      final unkeyed = parse({
        'verified': true,
        'keyed': false,
        'verificationCaveat': 'Set AUDIT_CHAIN_KEY before relying on it.',
      });

      expect(unkeyed.verified, isTrue);
      expect(unkeyed.keyed, isFalse);
      expect(unkeyed.verificationCaveat, contains('AUDIT_CHAIN_KEY'));
    });
  });

  group('the read-only producer view', () {
    OrganizationView parse(Map<String, dynamic> over) =>
        OrganizationView.fromJson({
          'readOnly': true,
          'impersonation': false,
          'periodId': '2026-09',
          'organization': {
            'orgId': 'org_cola',
            'legalName': 'Coca-Cola Bangladesh Beverages Ltd.',
            'tradeName': 'Coca-Cola Bangladesh',
            'status': 'active',
          },
          'capabilities': {'canWrite': false, 'note': 'Read-only.'},
          'members': [<String, dynamic>{}, <String, dynamic>{}],
          ...over,
        });

    test('is safe only when every guarantee holds', () {
      // EPR-46: no Admin action is ever taken under a producer's identity. The
      // screen checks this before rendering, so a future server change that
      // sent a writable payload down this route is refused rather than
      // quietly offering a write affordance.
      expect(parse({}).isSafeReadOnlyView, isTrue);

      expect(parse({'readOnly': false}).isSafeReadOnlyView, isFalse);
      expect(parse({'impersonation': true}).isSafeReadOnlyView, isFalse);
      expect(
        parse({
          'capabilities': {'canWrite': true, 'note': ''},
        }).isSafeReadOnlyView,
        isFalse,
      );
    });

    test('treats a missing guarantee as absent rather than as granted', () {
      // A payload with no `readOnly` field at all must not be assumed
      // read-only — the assertion has to be present to count.
      final bare = OrganizationView.fromJson({
        'organization': {'orgId': 'org_x'},
        'capabilities': <String, dynamic>{},
      });

      expect(bare.readOnly, isFalse);
      expect(bare.isSafeReadOnlyView, isFalse);
    });
  });

  group('a declaration under review', () {
    test('reports no variance on a first filing, rather than zero', () {
      // "Nothing to compare against" is a different statement from "no
      // change", and a dash in a variance column reads as the latter.
      final first = DeclarationReviewRow.fromJson({
        'orgId': 'org_cola',
        'periodId': '2026-09',
        'version': 1,
        'totalMassMg': 18000000000,
        'attestedByName': 'Nasrin Akhter',
        'flagged': false,
        'variance': null,
        'correctionVariance': null,
      });

      expect(first.variance, isNull);
      expect(first.correctionVariance, isNull);
      expect(first.flagged, isFalse);
    });

    test('takes the flag from the server rather than re-deriving it', () {
      // Two consoles disagreeing about what counts as flagged would be worse
      // than neither flagging anything.
      final flagged = DeclarationReviewRow.fromJson({
        'orgId': 'org_cola',
        'periodId': '2026-09',
        'version': 2,
        'totalMassMg': 7000000000,
        'attestedByName': 'Nasrin Akhter',
        'flagged': true,
        'flagReasons': ['Withdrawn and refiled -74% from version 1.'],
        'varianceThreshold': 0.60,
        'correctionVariance': -0.74,
      });

      expect(flagged.flagged, isTrue);
      expect(flagged.flagReasons.single, contains('-74%'));
      expect(flagged.varianceThreshold, closeTo(0.60, 1e-9));
    });

    test('a producer’s note suppresses the flag, not the figure', () {
      // EPR-43's own "without a note". The variance is still reported so a
      // reviewer can see the move and disagree.
      final explained = DeclarationReviewRow.fromJson({
        'orgId': 'org_cola',
        'periodId': '2026-09',
        'version': 1,
        'totalMassMg': 8000000000,
        'attestedByName': 'Nasrin Akhter',
        'flagged': false,
        'hasNote': true,
        'note': 'Two production lines moved to the Gazipur plant.',
        'flagReasons': ['Moved -71% against 2026-08.'],
        'variance': -0.71,
      });

      expect(explained.flagged, isFalse);
      expect(explained.hasNote, isTrue);
      expect(explained.variance, closeTo(-0.71, 1e-9));
      expect(explained.flagReasons, isNotEmpty);
    });
  });
}
