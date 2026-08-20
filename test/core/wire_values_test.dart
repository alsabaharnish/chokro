import 'package:chokro/core/wire_values.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wireString accepts only strings', () {
    expect(wireString('ok'), 'ok');
    expect(wireString(7), isNull);
    expect(wireString(null), isNull);
  });

  test('wireInt accepts whole finite JSON numbers without truncating', () {
    expect(wireInt(7), 7);
    expect(wireInt(7.0), 7);
    expect(wireInt(7.5), isNull);
    expect(wireInt(double.nan), isNull);
    expect(wireInt('7'), isNull);
  });
}
