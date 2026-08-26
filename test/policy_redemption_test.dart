import 'package:chokro/core/points_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// The redemption block is offered to the admin as two independent numbers, but
/// only their integer quotient is ever used: `pointsPerTaka` truncates and then
/// floors at 1. An indivisible or inverted pair was therefore accepted and
/// applied at a rate that is neither what the admin typed nor derivable from
/// it — the client and the Node port agreeing with each other about the wrong
/// answer.
void main() {
  PointsPolicy policy({required int points, required int taka}) => PointsPolicy
      .defaults
      .copyWith(redemptionPointsPerBlock: points, redemptionTakaPerBlock: taka);

  group('redemption block validation', () {
    test('an evenly dividing block is allowed', () {
      final ok = policy(points: 100, taka: 10);

      expect(ok.validate(), isEmpty);
      expect(ok.pointsPerTaka, 10);
    });

    test('a one-to-one block is allowed', () {
      expect(policy(points: 10, taka: 10).validate(), isEmpty);
    });

    test('an indivisible block is refused, and the message names the rate '
        'that would have been applied', () {
      final bad = policy(points: 150, taka: 20);

      // 150 ~/ 20 == 7, so the admin's "150 points to BDT 20" would have been
      // silently applied as 7 points per taka.
      expect(bad.pointsPerTaka, 7);
      expect(
        bad.validate(),
        contains(
          'Redemption block: 150 points does not divide evenly into 20 BDT, '
          'so the rate actually applied would be 7 points per taka.',
        ),
      );
    });

    test('an inverted block is refused before the floor can hide it', () {
      // 10 ~/ 100 == 0, floored to 1 — one point per taka, a hundred times the
      // intended value given away with no warning anywhere.
      final inverted = policy(points: 10, taka: 100);

      expect(inverted.pointsPerTaka, 1);
      expect(
        inverted.validate().any((p) => p.startsWith('Redemption block:')),
        isTrue,
      );
    });

    test('a zero figure is still reported as non-positive, not as a ratio', () {
      final zero = policy(points: 0, taka: 10);

      expect(
        zero.validate(),
        contains('Redemption points per block must be greater than zero.'),
      );
      expect(
        zero.validate().where((p) => p.contains('does not divide')),
        isEmpty,
        reason: 'a zero is a missing value, not a bad ratio',
      );
    });
  });
}
