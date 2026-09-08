import 'package:chokro/core/bin_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const payload = 'chokro:bin:a1b2c3d4e5f6';

  test('builds the public HTTPS bin route without exposing bin data', () {
    final link = BinLink.forPayload(payload);

    expect(link.scheme, 'https');
    expect(link.host, 'chokro-30887.web.app');
    expect(link.pathSegments, ['b', payload]);
    expect(link.toString(), isNot(contains('23.')));
  });

  test('accepts only a clean root HTTPS origin for public labels', () {
    expect(BinLink.isValidPublicBaseUrl('https://chokro.example'), isTrue);
    expect(BinLink.isValidPublicBaseUrl('https://chokro.example/'), isTrue);
    expect(BinLink.isValidPublicBaseUrl('http://chokro.example'), isFalse);
    expect(
      BinLink.isValidPublicBaseUrl('https://chokro.example/base'),
      isFalse,
    );
    expect(
      BinLink.isValidPublicBaseUrl('https://chokro.example:8443'),
      isFalse,
    );
    expect(
      BinLink.isValidPublicBaseUrl('https://user@chokro.example'),
      isFalse,
    );
    expect(
      BinLink.isValidPublicBaseUrl('https://chokro.example?mode=1'),
      isFalse,
    );
    expect(BinLink.isValidPublicBaseUrl('https://chokro.example?'), isFalse);
    expect(BinLink.isValidPublicBaseUrl('https://chokro.example#'), isFalse);
  });

  test('extracts the opaque token from a public bin link', () {
    final link = BinLink.forPayload(payload).toString();
    expect(BinLink.payloadFromScannedValue(link), payload);
  });

  test('keeps old token-only labels compatible with the app scanner', () {
    expect(BinLink.payloadFromScannedValue(payload), payload);
  });

  test('keeps legacy seeded bin identifiers compatible', () {
    const legacyPayload = 'chokro:bin:seed_bin_merul';
    final link = BinLink.forPayload(legacyPayload).toString();

    expect(BinLink.payloadFromScannedValue(legacyPayload), legacyPayload);
    expect(BinLink.payloadFromScannedValue(link), legacyPayload);
  });

  test('rejects lookalike hosts and malformed tokens', () {
    expect(
      BinLink.payloadFromScannedValue(
        'https://example.com/b/chokro:bin:a1b2c3d4e5f6',
      ),
      isNull,
    );
    expect(BinLink.payloadFromScannedValue('chokro:bin:bad!token'), isNull);
    expect(BinLink.payloadFromScannedValue('chokro:bin:has/slash'), isNull);
    expect(BinLink.payloadFromScannedValue('chokro:bin:has space'), isNull);
    expect(
      BinLink.payloadFromScannedValue(
        'https://user@chokro-30887.web.app/b/$payload',
      ),
      isNull,
    );
    expect(
      BinLink.payloadFromScannedValue(
        'https://chokro-30887.web.app/b/$payload?source=other',
      ),
      isNull,
    );
    expect(
      BinLink.payloadFromScannedValue(
        'https://chokro-30887.web.app/other/$payload',
      ),
      isNull,
    );
  });
}
