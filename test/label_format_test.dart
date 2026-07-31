import 'package:chokro/core/label_format.dart';
import 'package:flutter_test/flutter_test.dart';

enum _ItemType { plasticBottles, glass }

void main() {
  group('enumName', () {
    test('strips the type prefix from an enum value', () {
      expect(enumName(_ItemType.plasticBottles), 'plasticBottles');
    });

    test('returns a string unchanged', () {
      expect(enumName('plasticBottles'), 'plasticBottles');
    });

    test('returns empty for null rather than throwing', () {
      expect(enumName(null), '');
    });
  });

  group('humanise', () {
    test('splits camelCase into sentence case', () {
      expect(humanise('plasticBottles'), 'Plastic bottles');
    });

    test('handles an enum value directly', () {
      expect(humanise(_ItemType.glass), 'Glass');
    });

    test('converts underscores to spaces', () {
      expect(humanise('paper_cardboard'), 'Paper cardboard');
    });

    test('handles a flag name', () {
      expect(humanise('outsideRadius'), 'Outside radius');
      expect(humanise('screeningUnavailable'), 'Screening unavailable');
    });

    test('is empty for null and blank input', () {
      expect(humanise(null), '');
      expect(humanise('   '), '');
    });
  });

  group('formatDateTime', () {
    test('formats a local timestamp', () {
      final value = DateTime(2026, 8, 2, 14, 5);
      expect(formatDateTime(value), '2 Aug 2026, 14:05');
    });

    test('pads single-digit times', () {
      expect(formatDateTime(DateTime(2026, 1, 9, 4, 7)), '9 Jan 2026, 04:07');
    });

    test('is empty for null', () {
      expect(formatDateTime(null), '');
    });
  });

  group('formatAge', () {
    final now = DateTime(2026, 8, 2, 12, 0);

    test('null reads as just now — the server timestamp has not resolved', () {
      expect(formatAge(null, now: now), 'just now');
    });

    test('under a minute reads as just now', () {
      expect(formatAge(now.subtract(const Duration(seconds: 20)), now: now),
          'just now');
    });

    test('minutes, hours and days', () {
      expect(formatAge(now.subtract(const Duration(minutes: 14)), now: now),
          '14m ago');
      expect(
          formatAge(now.subtract(const Duration(hours: 3)), now: now), '3h ago');
      expect(
          formatAge(now.subtract(const Duration(days: 5)), now: now), '5d ago');
    });

    test('beyond a week falls back to the absolute date', () {
      final old = now.subtract(const Duration(days: 20));
      expect(formatAge(old, now: now), formatDateTime(old));
    });

    test('a clock-skewed future timestamp does not read as negative', () {
      expect(formatAge(now.add(const Duration(hours: 2)), now: now), 'just now');
    });
  });

  group('signedPoints and itemCount', () {
    test('signs credits and leaves debits alone', () {
      expect(signedPoints(50), '+50');
      expect(signedPoints(-120), '-120');
      expect(signedPoints(0), '0');
    });

    test('pluralises item counts', () {
      expect(itemCount(1), '1 item');
      expect(itemCount(4), '4 items');
      expect(itemCount(null), '');
    });
  });
}
