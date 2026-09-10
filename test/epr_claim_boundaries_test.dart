/// The prohibited claims, as a test (EPR-26 / §6.7, QA-4).
///
/// "§6.7 is not a documentation convention — it is testable, so test it."
///
/// Two halves. The first asserts the *derivation* layer refuses to produce a
/// figure whose inputs do not exist, which is where a prohibited claim would
/// actually originate. The second reads every producer-facing string in the
/// views and asserts none of them states one — a coarse check, but it is the
/// one that catches a well-meaning copy edit.
library;

import 'dart:io';

import 'package:chokro/core/constants.dart';
import 'package:chokro/core/epr_categories.dart';
import 'package:chokro/core/epr_claims.dart';
import 'package:chokro/core/mass_math.dart';
import 'package:chokro/models/organization_model.dart';
import 'package:chokro/models/producer_sku_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every file that renders something to a producer or about a producer.
const _producerFacingSources = <String>[
  'lib/views/producer/producer_dashboard_view.dart',
  'lib/views/producer/producer_members_view.dart',
  'lib/views/producer/producer_activity_view.dart',
  'lib/views/producer/producer_skus_view.dart',
  'lib/views/producer/collected_mass_card.dart',
  'lib/views/producer/sku_editor_dialog.dart',
  'lib/views/producer/sku_import_view.dart',
  'lib/views/producer/invitation_redeem_view.dart',
  'lib/views/admin/admin_producers_view.dart',
  'lib/views/admin/admin_mass_queue_view.dart',
];

String _sourceOf(String path) => File(path).readAsStringSync();

/// A string reduced to its words, so source line breaks do not matter.
///
/// Dart concatenates adjacent string literals, so a sentence written across
/// three source lines is one string at runtime with the line breaks gone. The
/// constant it should have come from has its own formatting. Comparing the
/// normalised words is the only way the two are comparable at all.
String _words(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

/// The string literals a file renders, with adjacent literals joined.
///
/// Dart concatenates `'a ' 'b'` at compile time, so a sentence written across
/// several source lines is one string at runtime and must be checked as one.
/// A raw substring search over source cannot see it; this can.
String _renderedStringsIn(String path) {
  final source = _sourceOf(path);

  // Drop line comments, which legitimately quote the phrases being forbidden.
  final code = source
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  // Single-quoted literals, tolerating escaped quotes.
  final literals = RegExp(r"'((?:[^'\\]|\\.)*)'").allMatches(code);

  final buffer = StringBuffer();
  for (final match in literals) {
    buffer.write(match.group(1));
    // A space, so two joined literals do not fuse two words into one token —
    // but adjacent-literal continuation is preserved because Dart's own
    // concatenation already put the space inside one of them.
    buffer.write(' ');
  }
  return buffer.toString();
}

void main() {
  group('no figure without its inputs (EPR-24, EPR-26)', () {
    OrganizationModel org(Map<String, dynamic> json) =>
        OrganizationModel.fromJson(json, id: 'org-1');

    test('no gazette target without an obligation start date', () {
      // Year 1 carries the 15% target and year 3 carries 30%. Guessing prints
      // the wrong law beside a producer's own figure.
      final noStart = org({'status': OrgStatus.active});
      expect(noStart.obligationYearAt(DateTime.utc(2027)), isNull);
      expect(noStart.collectionTargetAt(DateTime.utc(2027)), isNull);
      expect(noStart.recyclingTargetAt(DateTime.utc(2027)), isNull);
    });

    test('no gazette target from an unrecognised size class', () {
      final unknown = org({
        'status': OrgStatus.active,
        'sizeClass': 'enormous',
        'obligationStartDate': DateTime.utc(2026, 8, 13),
      });
      expect(unknown.sizeClass, isNull);
    });

    test('no reportable mass from a declared figure', () {
      // The one rule §6.2 exists to enforce: the producer's own number never
      // reaches a report.
      final declaredOnly = ProducerSkuModel.fromJson(const {
        'declaredUnitMassMg': 10000,
        'massStatus': 'submitted',
        'verifiedUnitMassMg': 9800,
      }, id: 'sku-1');

      expect(declaredOnly.declaredUnitMassMg, 10000);
      expect(declaredOnly.reportableUnitMassMg, isNull);
    });

    test('no polymer breakdown without a declared component breakdown', () {
      // Attributing a whole unit mass to the dominant polymer is a guess, and
      // §6.7 forbids a figure whose provenance cannot be traced field by field.
      final noComponents = ProducerSkuModel.fromJson(const {
        'declaredUnitMassMg': 10000,
        'polymer': 'pet',
        'components': <Object>[],
      }, id: 'sku-1');

      expect(noComponents.massByPolymerMg, isEmpty);
    });

    test('an absence of mass is never rendered as a measurement of zero', () {
      // "0.00 kg" implies a measurement precise to that place. An absence of
      // attributed mass is not a measurement.
      expect(formatKilograms(0), '0 kg');
      expect(formatGrams(0), '0 g');
      expect(formatKilograms(0), isNot(contains('.')));
    });
  });

  group('the gazette targets are the law’s numbers, not Chokro’s', () {
    test('they match the guidelines and carry the review clause', () {
      expect(GazetteTargets.earlyCollectionRate, 0.15);
      expect(GazetteTargets.earlyRecyclingRate, 0.075);
      expect(GazetteTargets.laterCollectionRate, 0.30);
      expect(GazetteTargets.laterRecyclingRate, 0.15);
      // The guidelines make the targets themselves reviewable after three
      // years, so the constant says so rather than presenting the second tier
      // as permanent.
      expect(GazetteTargets.reviewDueAfterYears, 3);
    });

    test('they are compile-time constants, not policy an operator can edit', () {
      // Every threshold Chokro *chose* lives in config/eprPolicy. These are the
      // gazette's, and an editable copy would let an operator change what the
      // regulation says.
      final source = _sourceOf('lib/core/epr_categories.dart');
      expect(source, contains('class GazetteTargets'));
      expect(source, contains('static const double earlyCollectionRate'));
    });
  });

  group('the boundary statements are a single source of truth', () {
    // Asserting the constants rather than grepping widget source, because a
    // source scan is wrong in both directions: a *disclaimer* contains the
    // phrase it disclaims ("no figure is DoE-approved" matches a search for
    // "DoE-approved"), and Dart concatenates adjacent string literals so a
    // sentence spanning two lines is invisible to a substring match.
    //
    // The Plastic Passport prints the same list (EPR-28), so a second copy of
    // the wording would be a second thing to keep in step.

    test('all three §6.7 statements are present and say what they must', () {
      expect(eprBoundaryStatements, hasLength(3));

      final joined = eprBoundaryStatements.join(' ');
      // Who is obligated.
      expect(joined, contains('obligated entity remains your company'));
      expect(joined, contains('Department of Environment'));
      // What Chokro does not do.
      expect(joined, contains('discharges your legal obligation'));
      expect(joined, contains('DoE-approved'));
      // What the numbers are and are not.
      expect(joined, contains('operational records of activity'));
      expect(joined, contains('not official measurements'));
    });

    test('each statement is a full sentence a reader can act on', () {
      // Not a fragment, and not six-point-type shorthand (EPR-28 point 5).
      for (final statement in eprBoundaryStatements) {
        expect(statement.length, greaterThan(60));
        expect(statement.endsWith('.'), isTrue);
      }
    });

    test('the absence reasons name the missing input, not just the absence', () {
      // A screen that omitted a figure would read as a zero; one that showed a
      // zero would state a measurement it does not have. Each of these refuses
      // to state a number *and says which input is missing*.
      expect(
        EprAbsenceReasons.noPercentageWithoutDeclaration,
        contains('put-on-market declaration'),
      );
      expect(
        EprAbsenceReasons.noPercentageWithoutDeclaration,
        contains('denominator'),
      );
      expect(EprAbsenceReasons.recyclingNotCovered, contains('recycler'));
      expect(
        EprAbsenceReasons.recyclingNotCovered,
        contains('not covered'),
      );
      expect(
        EprAbsenceReasons.noMassWithoutVerification,
        contains('Chokro-verified'),
      );
      expect(
        EprAbsenceReasons.targetIsNotAnAssessment,
        contains('finding, not ours'),
      );
    });
  });

  group('findProhibitedClaims', () {
    test('flags an asserted claim', () {
      expect(
        findProhibitedClaims('Your figures are DoE-approved.'),
        contains('DoE-approved'),
      );
      expect(
        findProhibitedClaims('Your recycling rate is 12%.'),
        contains('recycling rate'),
      );
      expect(
        findProhibitedClaims('You avoided 4,030 kg CO2e.'),
        contains('CO2e'),
      );
      expect(
        findProhibitedClaims('Equivalent to 200 trees equivalent.'),
        contains('trees equivalent'),
      );
    });

    test('does not flag a disclaimer that denies the same claim', () {
      // The specific failure that made the first version of this check
      // useless: the correct sentence flagged itself.
      expect(findProhibitedClaims(eprBoundaryStatements.join(' ')), isEmpty);
      expect(
        findProhibitedClaims(EprAbsenceReasons.recyclingNotCovered),
        isEmpty,
      );
      expect(
        findProhibitedClaims(EprAbsenceReasons.targetIsNotAnAssessment),
        isEmpty,
      );
    });

    test('is case-insensitive', () {
      expect(
        findProhibitedClaims('YOUR FIGURES ARE OFFICIALLY CERTIFIED'),
        contains('officially certified'),
      );
    });

    test('names every phrase it found, not just the first', () {
      final found = findProhibitedClaims(
        'You are compliant. Your recycling rate is 12%. 4 kg CO2e avoided.',
      );
      expect(found.length, greaterThanOrEqualTo(3));
    });

    test('clean text yields nothing', () {
      expect(
        findProhibitedClaims(
          'Chokro attributed 3,940 kg of rigid plastic in September 2026.',
        ),
        isEmpty,
      );
      expect(findProhibitedClaims(''), isEmpty);
    });
  });

  group('the shared statements stay the single source of truth', () {
    // Asserted as an invariant over the whole producer surface rather than
    // against one file's contents: these sentences move between screens as
    // phases land — the collected-mass figures moved from the dashboard to
    // their own card in Phase C — and a test pinned to a location would fail
    // for the wrong reason and be "fixed" by pointing it somewhere new.
    //
    // What must stay true is that nothing retypes them.

    test('no producer surface retypes a boundary sentence', () {
      // A retyped sentence stops the constant being the single source of truth,
      // and the Plastic Passport can then drift from the screen (EPR-28).
      final rendered = _producerFacingSources
          .map(_renderedStringsIn)
          .join('\n');

      for (final statement in eprBoundaryStatements) {
        // Compared on the words, not the source formatting: Dart concatenates
        // adjacent literals, so the sentence in a widget would appear with
        // different line breaks from the constant.
        expect(
          _words(rendered),
          isNot(contains(_words(statement))),
          reason: 'a producer surface retypes: "$statement"',
        );
      }
    });

    test('every boundary statement is rendered somewhere', () {
      // The other half. A constant nobody renders is a promise nobody keeps.
      final sources = _producerFacingSources.map(_sourceOf).join('\n');
      expect(sources, contains('eprBoundaryStatements'));
    });

    test('every absence reason is referenced by name, not retyped', () {
      final sources = _producerFacingSources.map(_sourceOf).join('\n');
      const referenced = <String>[
        'EprAbsenceReasons.recyclingNotCovered',
        'EprAbsenceReasons.noPercentageWithoutDeclaration',
        'EprAbsenceReasons.noMassWithoutVerification',
        'EprAbsenceReasons.targetIsNotAnAssessment',
      ];

      for (final reference in referenced) {
        expect(
          sources,
          contains(reference),
          reason: '$reference is no longer rendered anywhere',
        );
      }
    });
  });

  group('no producer-facing surface asserts a prohibited claim', () {
    test('every rendered string literal is clean', () {
      // A coarse net, but the one that catches a well-meaning copy edit. String
      // literals are extracted and adjacent ones joined, so a sentence split
      // across source lines is checked as one sentence — which a plain
      // substring search over raw source cannot do.
      for (final path in _producerFacingSources) {
        final claims = findProhibitedClaims(_renderedStringsIn(path));
        expect(
          claims,
          isEmpty,
          reason: '$path asserts: ${claims.join(", ")}',
        );
      }
    });
  });

  group('no compliance arithmetic in a view (QA-1)', () {
    test('the producer views never divide one figure by another', () {
      // "A widget that performs arithmetic on a compliance figure is a defect
      // regardless of whether the output is currently correct."
      //
      // Division is the specific operation that would produce a percentage —
      // the figure EPR-24 forbids without a declaration. Layout maths (flex
      // ratios, sizes) does not appear in these files, so a bare `/` between
      // two identifiers is a strong signal.
      for (final path in _producerFacingSources) {
        final source = _sourceOf(path);
        // Strip comments, which legitimately discuss ratios and percentages.
        final code = source
            .split('\n')
            .where((line) => !line.trimLeft().startsWith('//'))
            .join('\n');

        // Dividing by a named unit constant is a unit conversion — milligrams
        // to grams for a text field — not a ratio between two figures. A
        // percentage would divide one *measured* quantity by another, and that
        // is what this looks for.
        final withoutUnitConversions = code
            .replaceAll(RegExp(r'/\s*mgPer(Gram|Kilogram|Tonne)'), '')
            .replaceAll(RegExp(r'/\s*1000\b'), '');

        final suspicious = RegExp(
          r'\b(mass|grams|kg|kilograms|units|total|collected|declared)\w*\s*/\s*\w',
          caseSensitive: false,
        );

        expect(
          suspicious.hasMatch(withoutUnitConversions),
          isFalse,
          reason: '$path appears to compute a ratio from compliance figures',
        );
      }
    });

    test('formatting is the only place a mass becomes a string', () {
      // Every mass a producer sees goes through mass_math's formatters, which
      // round once (EPR-20). A view calling toStringAsFixed on a mass would be
      // a second rounding step nobody can find.
      for (final path in _producerFacingSources) {
        final code = _sourceOf(path)
            .split('\n')
            .where((line) => !line.trimLeft().startsWith('//'))
            .join('\n');

        expect(
          RegExp(r'(Mass|Grams|mg)\w*\.toStringAsFixed').hasMatch(code),
          isFalse,
          reason: '$path formats a mass without going through mass_math',
        );
      }
    });
  });

  group('the wire vocabulary is stable (QA-6)', () {
    test('every stored string this feature introduced keeps its value', () {
      // "Stored strings, never renamed once written." A rename here is a
      // silent data migration nobody wrote.
      expect(AppConstants.roleProducer, 'producer');
      expect(OrgRoles.ordered, ['orgOwner', 'orgReporter', 'orgViewer']);
      expect(OrgMemberStatus.all, ['invited', 'active', 'removed']);
      expect(OrgStatus.all, [
        'pendingReview',
        'active',
        'suspended',
        'closed',
      ]);
      expect(OrgSizeClass.all, ['large', 'medium', 'small']);
      expect(ComplianceRoute.all, ['self', 'pro']);
      expect(GazetteCategory.all, [
        'rigid',
        'flexible',
        'eps',
        'singleUse',
        'other',
      ]);
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
      expect(MassStatus.all, [
        'draft',
        'submitted',
        'verified',
        'rejected',
        'superseded',
      ]);
      expect(SkuStatus.all, ['draft', 'submitted', 'active', 'retired']);
    });
  });
}
