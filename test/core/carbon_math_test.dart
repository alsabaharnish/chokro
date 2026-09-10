/// Carbon, and the reasons it may be shown (EPR-38, EPR-39, QA-4).
library;

import 'dart:io';

import 'package:chokro/core/carbon_math.dart';
import 'package:chokro/core/mass_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the worked example', () {
    test('3.94 t at the Turner factor is about 4,030 kg CO2e', () {
      // Appendix A step 9: "3.94 t × −1,024 kg CO₂e/t ... ≈ 4,030 kg CO₂e
      // avoided".
      final estimate = carbonAvoided(
        massMg: 3940 * mgPerKilogram,
        factor: turnerMixedPlastics2015,
        estimatedShare: 0.062,
        uncertaintyCeiling: 0.25,
      );

      expect(estimate.exists, isTrue);
      expect(estimate.kgCo2eAvoided, closeTo(4034.56, 0.01));
      // Three significant figures and no trailing zero. This expectation used
      // to be '4030.0', which pinned a formatting bug: `label` rendered a
      // double straight into the string, so an indicative estimate claimed a
      // tenth of a kilogram of precision it does not have. It now goes through
      // `formatSignificantFigures`, the same rounding the mass figures use.
      expect(estimate.label, '4030 kg CO₂e');
    });

    test('the reported figure is positive; the factor stays signed', () {
      // A report should not print a minus sign in front of a benefit. The
      // direction lives in the wording, and the coefficient keeps its sign so
      // it cannot be dropped silently.
      final estimate = carbonAvoided(
        massMg: mgPerTonne,
        factor: turnerMixedPlastics2015,
        estimatedShare: 0,
        uncertaintyCeiling: 0.25,
      );
      expect(estimate.kgCo2eAvoided, 1024);
      expect(estimate.factor!.kgCo2ePerTonne, -1024);
    });
  });

  group('the refusals EPR-39 requires', () {
    test('no factor means no figure', () {
      // "A carbon number that cannot name its factor and its source does not
      // ship."
      final estimate = carbonAvoided(
        massMg: 3940 * mgPerKilogram,
        factor: null,
        estimatedShare: 0,
        uncertaintyCeiling: 0.25,
      );
      expect(estimate.exists, isFalse);
      expect(estimate.kgCo2eAvoided, isNull);
      expect(estimate.label, isNull);
      expect(estimate.absence, CarbonAbsence.noFactor);
    });

    test('an unsourced factor is unusable, not usable-with-a-warning', () {
      const unsourced = EmissionFactor(
        id: 'x',
        material: 'mixedPlastics',
        kgCo2ePerTonne: -1024,
        source: '',
        publicationYear: 2015,
        version: 'v1',
        systemBoundary: 'avoided virgin production',
        geography: 'UK',
      );
      expect(unsourced.isUsable, isFalse);

      final estimate = carbonAvoided(
        massMg: mgPerTonne,
        factor: unsourced,
        estimatedShare: 0,
        uncertaintyCeiling: 0.25,
      );
      expect(estimate.absence, CarbonAbsence.noFactor);
    });

    test('a factor missing a boundary or a version is unusable', () {
      // Two factors for one material on different boundaries are not
      // comparable, and summing them is meaningless.
      const noBoundary = EmissionFactor(
        id: 'x',
        material: 'mixedPlastics',
        kgCo2ePerTonne: -1024,
        source: 'A source long enough to look like a citation.',
        publicationYear: 2015,
        version: 'v1',
        systemBoundary: '',
        geography: 'UK',
      );
      expect(noBoundary.isUsable, isFalse);

      const noVersion = EmissionFactor(
        id: 'x',
        material: 'mixedPlastics',
        kgCo2ePerTonne: -1024,
        source: 'A source long enough to look like a citation.',
        publicationYear: 2015,
        version: '',
        systemBoundary: 'avoided virgin production',
        geography: 'UK',
      );
      expect(noVersion.isUsable, isFalse);
    });

    test('a zero or non-finite factor is unusable', () {
      for (final value in [0.0, double.nan, double.infinity]) {
        final factor = EmissionFactor(
          id: 'x',
          material: 'mixedPlastics',
          kgCo2ePerTonne: value,
          source: 'A source long enough to look like a citation.',
          publicationYear: 2015,
          version: 'v1',
          systemBoundary: 'avoided virgin production',
          geography: 'UK',
        );
        expect(factor.isUsable, isFalse, reason: 'factor $value');
      }
    });

    test('too much uncertainty means no figure at all', () {
      // "any carbon figure at all for a period whose estimatedShare exceeds a
      // policy ceiling". Two uncertainties compounded into one number that
      // reads as precise.
      final estimate = carbonAvoided(
        massMg: 3940 * mgPerKilogram,
        factor: turnerMixedPlastics2015,
        estimatedShare: 0.4,
        uncertaintyCeiling: 0.25,
      );
      expect(estimate.exists, isFalse);
      expect(estimate.absence, CarbonAbsence.tooUncertain);
      // The share that triggered it travels, so the screen can say why.
      expect(estimate.estimatedShare, 0.4);
      // And the factor that would have applied, so it can say which.
      expect(estimate.factor, isNotNull);
    });

    test('exactly at the ceiling is allowed; a hair over is not', () {
      expect(
        carbonAvoided(
          massMg: mgPerTonne,
          factor: turnerMixedPlastics2015,
          estimatedShare: 0.25,
          uncertaintyCeiling: 0.25,
        ).exists,
        isTrue,
      );
      expect(
        carbonAvoided(
          massMg: mgPerTonne,
          factor: turnerMixedPlastics2015,
          estimatedShare: 0.2501,
          uncertaintyCeiling: 0.25,
        ).exists,
        isFalse,
      );
    });

    test('no mass means no figure', () {
      for (final mass in [0, -100]) {
        final estimate = carbonAvoided(
          massMg: mass,
          factor: turnerMixedPlastics2015,
          estimatedShare: 0,
          uncertaintyCeiling: 0.25,
        );
        expect(estimate.exists, isFalse);
        expect(estimate.absence, CarbonAbsence.noMass);
      }
    });
  });

  group('the default factor carries its own citation and caveats', () {
    test('it is the one §9.2 sources, with the figure it states', () {
      expect(turnerMixedPlastics2015.kgCo2ePerTonne, -1024);
      expect(turnerMixedPlastics2015.material, 'mixedPlastics');
      expect(turnerMixedPlastics2015.publicationYear, 2015);
      expect(turnerMixedPlastics2015.doi, '10.1016/j.resconrec.2015.10.026');
      expect(turnerMixedPlastics2015.source, contains('Turner'));
      expect(turnerMixedPlastics2015.source, contains('Resources, Conservation'));
      expect(turnerMixedPlastics2015.isUsable, isTrue);
    });

    test('all three §9.2 caveats travel with it', () {
      final caveats = turnerMixedPlastics2015.caveats.join(' ');
      // UK-derived.
      expect(caveats, contains('UK-derived'));
      expect(caveats, contains('electricity mix'));
      // Mixed rather than polymer-specific.
      expect(caveats, contains('not polymer-specific'));
      // Conditional on downstream recycling — the §6.6 loop.
      expect(caveats, contains('Conditional on downstream recycling'));
      expect(caveats, contains('recycler'));
      expect(turnerMixedPlastics2015.caveats, hasLength(3));
    });

    test('an absent uncertainty is stated, not invented', () {
      // Inventing an uncertainty range is as much a fabrication as inventing
      // the factor.
      expect(
        turnerMixedPlastics2015.uncertainty,
        contains('no uncertainty range'),
      );
    });

    test('the citation names the boundary, the geography and the version', () {
      // Two factors for one material on different boundaries are not
      // comparable, so a report has to be able to say which it used.
      final citation = turnerMixedPlastics2015.citation;
      expect(citation, contains('avoided virgin production'));
      expect(citation, contains('United Kingdom'));
      expect(citation, contains('mixedPlastics-2015-uk-v1'));
      expect(citation, contains('doi:'));
    });
  });

  group('effective dating', () {
    test('a factor with no start date was never in force', () {
      // Fail closed, matching the SKU revisions: an undated factor must not
      // silently apply to every period ever recorded.
      expect(
        turnerMixedPlastics2015.wasActiveAt(DateTime.utc(2026, 9)),
        isFalse,
      );
    });

    test('a dated factor applies within its window only', () {
      final dated = EmissionFactor(
        id: 'x',
        material: 'mixedPlastics',
        kgCo2ePerTonne: -1024,
        source: 'A source long enough to look like a citation.',
        publicationYear: 2015,
        version: 'v1',
        systemBoundary: 'avoided virgin production',
        geography: 'UK',
        activeFrom: DateTime.utc(2026, 9, 1),
        activeTo: DateTime.utc(2027, 1, 1),
      );

      expect(dated.wasActiveAt(DateTime.utc(2026, 8, 31)), isFalse);
      expect(dated.wasActiveAt(DateTime.utc(2026, 9, 1)), isTrue);
      expect(dated.wasActiveAt(DateTime.utc(2026, 12, 31)), isTrue);
      expect(dated.wasActiveAt(DateTime.utc(2027, 1, 1)), isFalse);
    });
  });

  group('the prohibited conversions do not exist', () {
    test('there is no trees or cars conversion anywhere in the API', () {
      // EPR-39 forbids them outright. The best guarantee is that no function
      // exists to call — asserted over the source so a well-meaning addition
      // fails the build.
      final source = File('lib/core/carbon_math.dart').readAsStringSync();
      for (final forbidden in [
        'trees',
        'treeEquivalent',
        'carsOffTheRoad',
        'cars off',
        'equivalentTo',
      ]) {
        // Comments are stripped first: this file's own prose names the
        // forbidden conversions in order to explain that they are forbidden,
        // which is the same trap the claim-boundary test fell into.
        final code = source
            .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
            .split('\n')
            .where((line) => !line.trimLeft().startsWith('//'))
            .where((line) => !line.trimLeft().startsWith('///'))
            .join('\n');

        expect(
          code.toLowerCase(),
          isNot(contains(forbidden.toLowerCase())),
          reason: 'the carbon API must not offer a "$forbidden" conversion',
        );
      }
    });

    test('nothing in the API presents the estimate as tradable or verified', () {
      // The word "estimate" is load-bearing: EPR-39 forbids "any wording that
      // presents the estimate as verified, offset-grade or tradable".
      expect(CarbonEstimate.absent(
        CarbonAbsence.noFactor,
        massMg: 0,
      ).runtimeType.toString(), contains('Estimate'));

      final names = CarbonAbsence.values.map((v) => v.name.toLowerCase());
      for (final forbidden in ['offset', 'credit', 'verified', 'certified']) {
        expect(
          names.any((n) => n.contains(forbidden)),
          isFalse,
          reason: 'CarbonAbsence must not contain "$forbidden"',
        );
      }
    });
  });
}
