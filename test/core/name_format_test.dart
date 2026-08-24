import 'package:chokro/core/name_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('addressName', () {
    test('uses only the last name', () {
      expect(addressName('Al Sabah Arnish'), 'Arnish');
    });

    test('normalizes a fully uppercase last name', () {
      expect(addressName('AL SABAH ARNISH'), 'Arnish');
    });

    test('handles extra whitespace and a single name', () {
      expect(addressName('   RAHMAN   '), 'Rahman');
    });

    test('has a friendly fallback for an empty profile name', () {
      expect(addressName('   '), 'there');
    });
  });
}
