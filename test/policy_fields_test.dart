import 'package:chokro/core/points_policy.dart';
import 'package:chokro/core/policy_fields.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('policyFields', () {
    test('covers every key in the serialised policy', () {
      final serialisedKeys = PointsPolicy.defaults.toJson().keys.toSet();
      final fieldKeys = policyFields.map((f) => f.key).toSet();
      expect(
        fieldKeys,
        serialisedKeys,
        reason:
            'a parameter without a descriptor is not editable, and a '
            'descriptor without a parameter writes nothing',
      );
    });

    test('keys are unique', () {
      final keys = policyFields.map((f) => f.key).toList();
      expect(keys.toSet().length, keys.length);
    });

    test('read returns the value the policy actually holds', () {
      const policy = PointsPolicy.defaults;
      final json = policy.toJson();
      for (final field in policyFields) {
        expect(
          field.read(policy),
          json[field.key],
          reason: 'field ${field.key} reads the wrong value',
        );
      }
    });

    test('write changes only its own parameter', () {
      const base = PointsPolicy.defaults;
      for (final field in policyFields) {
        final changed = field.write(base, field.read(base) + 7);
        expect(field.read(changed), field.read(base) + 7);

        for (final other in policyFields) {
          if (other.key == field.key) continue;
          expect(
            other.read(changed),
            other.read(base),
            reason: 'writing ${field.key} disturbed ${other.key}',
          );
        }
      }
    });

    test('every field carries a label and help text', () {
      for (final field in policyFields) {
        expect(field.label, isNotEmpty);
        expect(field.help, isNotEmpty);
      }
    });
  });

  group('diffPolicies', () {
    test('identical policies produce no changes', () {
      expect(
        diffPolicies(PointsPolicy.defaults, PointsPolicy.defaults),
        isEmpty,
      );
    });

    test('reports a single changed parameter', () {
      const before = PointsPolicy.defaults;
      final after = before.copyWith(disposalAward: 40);

      final changes = diffPolicies(before, after);
      expect(changes.length, 1);
      expect(changes.single.field.key, 'disposalAward');
      expect(changes.single.from, 50);
      expect(changes.single.to, 40);
      expect(changes.single.summary, 'Disposal award: 50 → 40');
    });

    test('reports several changes in form order', () {
      const before = PointsPolicy.defaults;
      final after = before.copyWith(
        lockoutHours: 12,
        disposalAward: 60,
        claimAward: 20,
      );

      final changes = diffPolicies(before, after);
      expect(changes.map((c) => c.field.key).toList(), [
        'disposalAward',
        'claimAward',
        'lockoutHours',
      ]);
    });

    test('is directional', () {
      const a = PointsPolicy.defaults;
      final b = a.copyWith(dailyDisposalCap: 5);

      expect(diffPolicies(a, b).single.to, 5);
      expect(diffPolicies(b, a).single.to, 3);
    });
  });

  group('the invariant the editor must not let through', () {
    test('a claim award at or above the disposal award is refused', () {
      const base = PointsPolicy.defaults;

      expect(base.copyWith(claimAward: 50).validate(), isNotEmpty);
      expect(base.copyWith(claimAward: 80).validate(), isNotEmpty);
      expect(base.copyWith(claimAward: 49).validate(), isEmpty);
    });

    test(
      'lowering the disposal award below the claim award is refused too',
      () {
        // The same invariant approached from the other side — an administrator
        // is at least as likely to reduce the disposal award as to raise the
        // claim award.
        const base = PointsPolicy.defaults;
        expect(base.copyWith(disposalAward: 10).validate(), isNotEmpty);
      },
    );

    test('a policy built through the field writers still validates', () {
      var draft = PointsPolicy.defaults;
      for (final field in policyFields) {
        draft = field.write(draft, field.read(draft));
      }
      expect(draft, PointsPolicy.defaults);
      expect(draft.validate(), isEmpty);
    });
  });
}
