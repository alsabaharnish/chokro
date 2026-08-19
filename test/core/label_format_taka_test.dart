import 'package:chokro/core/label_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatTaka', () {
    test('prefixes the taka sign and never shows a decimal part', () {
      expect(formatTaka(250), '৳250');
    });

    test('groups thousands', () {
      expect(formatTaka(1250), '৳1,250');
      expect(formatTaka(1000000), '৳1,000,000');
    });

    test('handles the boundaries around a group', () {
      expect(formatTaka(999), '৳999');
      expect(formatTaka(1000), '৳1,000');
    });

    test('shows zero as zero, not as empty', () {
      expect(formatTaka(0), '৳0');
    });

    test('puts the sign before the currency mark on a negative', () {
      expect(formatTaka(-1250), '-৳1,250');
    });
  });

  group('orderCount', () {
    test('is singular for one', () {
      expect(orderCount(1), '1 order');
      expect(orderCount(3), '3 orders');
    });
  });
}
