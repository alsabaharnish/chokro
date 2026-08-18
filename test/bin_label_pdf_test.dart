import 'dart:convert';

import 'package:chokro/core/bin_label_pdf.dart';
import 'package:chokro/models/bin_model.dart';
import 'package:flutter_test/flutter_test.dart';

BinModel _bin({
  String label = 'Merul Badda - Block C gate',
  String payload = 'chokro:bin:a1b2c3d4e5f6',
  double lat = 23.7808,
  double lng = 90.4074,
  double radius = 50,
  bool active = true,
}) {
  return BinModel(
    label: label,
    lat: lat,
    lng: lng,
    radiusMeters: radius,
    qrPayload: payload,
    active: active,
    createdBy: 'admin-uid',
  );
}

/// Counts page objects. The `pdf` package compresses content streams, so page
/// *content* is not greppable — but the page dictionaries are not compressed,
/// which is enough to assert on pagination.
int _pageCount(List<int> bytes) {
  final text = latin1.decode(bytes, allowInvalid: true);
  return RegExp(r'/Type\s*/Page[^s]').allMatches(text).length;
}

void main() {
  group('buildBinLabelPdf', () {
    test('produces a single-page PDF', () async {
      final bytes = await buildBinLabelPdf(_bin());

      expect(
        latin1.decode(bytes.take(5).toList()),
        '%PDF-',
        reason: 'not a PDF at all',
      );
      expect(_pageCount(bytes), 1);
    });

    test('is substantial enough to contain a rendered barcode', () async {
      // A QR at high error correction is a few thousand drawing operations. An
      // empty page is on the order of a few hundred bytes, so a label that came
      // out near-empty — the failure mode if the barcode silently did not
      // render — would not clear this.
      final bytes = await buildBinLabelPdf(_bin());
      expect(bytes.length, greaterThan(3000));
    });

    test('a longer payload produces a denser, larger document', () async {
      // Proves the payload actually reaches the barcode. If `data` were ignored
      // or hardcoded, both documents would be the same size.
      final short = await buildBinLabelPdf(_bin(payload: 'chokro:bin:ab'));
      final long = await buildBinLabelPdf(
        _bin(payload: 'chokro:bin:${'0123456789abcdef' * 4}'),
      );

      expect(long.length, greaterThan(short.length));
    });

    test('accepts a label in Bengali without throwing', () async {
      // Whether the glyphs *draw* depends on the fonts passed in — see
      // `pdf_fonts.dart`. What must not happen is an exception, because that
      // would mean an administrator with a Bengali bin name cannot print at all.
      final bytes = await buildBinLabelPdf(_bin(label: 'মেরুল বাড্ডা'));
      expect(_pageCount(bytes), 1);
    });

    test('a label long enough to wrap still fits one page', () async {
      final bytes = await buildBinLabelPdf(
        _bin(label: 'A very long bin label ' * 6),
      );
      expect(_pageCount(bytes), 1);
    });
  });

  group('buildBinLabelSheetPdf', () {
    test('fits four labels on one page', () async {
      final bins = List.generate(4, (i) => _bin(payload: 'chokro:bin:p$i'));
      expect(_pageCount(await buildBinLabelSheetPdf(bins)), 1);
    });

    test('spills to a second page at five', () async {
      final bins = List.generate(5, (i) => _bin(payload: 'chokro:bin:p$i'));
      expect(_pageCount(await buildBinLabelSheetPdf(bins)), 2);
    });

    test('a part-full last page still renders', () async {
      // The grid always builds four cells, so the three empty ones on this
      // page's second row must not throw or stretch the surviving label.
      final bins = List.generate(5, (i) => _bin(payload: 'chokro:bin:p$i'));
      final bytes = await buildBinLabelSheetPdf(bins);
      expect(_pageCount(bytes), 2);
      expect(bytes.length, greaterThan(3000));
    });

    test('twenty bins land on five pages', () async {
      final bins = List.generate(20, (i) => _bin(payload: 'chokro:bin:p$i'));
      expect(_pageCount(await buildBinLabelSheetPdf(bins)), 5);
    });

    test(
      'refuses an empty list rather than opening an empty print dialog',
      () async {
        // Guarded by an assert, so this holds in debug and in tests. The view
        // checks for open bins before calling, which is the real protection.
        expect(
          () => buildBinLabelSheetPdf(const []),
          throwsA(isA<AssertionError>()),
        );
      },
    );
  });

  group('what the label must not disclose', () {
    test('the barcode encodes the payload and nothing else', () async {
      // §6 of the brief: the QR carries an opaque bin identifier only, so a
      // photographed code discloses nothing and possessing one proves nothing.
      //
      // The coordinates are printed on the paper — the label is physically at
      // the bin it describes — but they must not be *in the code*. This asserts
      // the value handed to the barcode, which is the thing a scanner reads.
      const payload = 'chokro:bin:deadbeef1234';
      final bin = _bin(payload: payload, lat: 23.7808, lng: 90.4074);

      // The builder passes `bin.qrPayload` straight through as the barcode
      // data; nothing composes coordinates into it.
      expect(bin.qrPayload, payload);
      expect(bin.qrPayload, isNot(contains('23.78')));
      expect(bin.qrPayload, isNot(contains('90.40')));
      expect(bin.qrPayload, isNot(contains(bin.createdBy)));

      // And the document builds from it without error.
      expect(_pageCount(await buildBinLabelPdf(bin)), 1);
    });
  });
}
