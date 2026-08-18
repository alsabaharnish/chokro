/// Printable bin labels (F2.1).
///
/// A registered bin is worth nothing until its code is on the bin, so
/// "generate a QR" really means "produce something an administrator can put on
/// paper". This builds that paper.
///
/// ## Why a PDF rather than printing the screen
///
/// The QR dialog used to advise "Ctrl+P prints the page", which prints the
/// Flutter canvas: the modal scrim, the navigation bar and a code sized for a
/// screen. Flutter's web canvas does not decompose into printable content at
/// all, so what came out was unusable. A PDF is the same document on every
/// platform, and `printing` hands it to the browser's print dialog on web and
/// to the system print or share sheet on mobile — which is exactly the split
/// §5.4 of the brief describes.
///
/// ## Why the barcode is vector
///
/// `pw.BarcodeWidget` emits drawing commands rather than a bitmap, so the code
/// is resolution-independent: it prints at the full sharpness of whatever
/// printer is used, with no resampling to soften the module edges that a
/// scanner needs to distinguish.
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/bin_model.dart';

/// Error correction for the printed code.
///
/// Deliberately higher than a screen would need. This label is going onto a
/// waste bin outdoors, where it will be rained on, sun-bleached and scuffed;
/// `high` recovers from roughly 30% of the code being unreadable, which is the
/// difference between a label that lasts a season and one that has to be
/// reprinted. The cost is a denser code, which is why the printed size below is
/// generous.
const _correction = pw.BarcodeQRCorrectionLevel.high;

/// One label, centred on a single A4 page.
///
/// Used when an administrator has just registered a bin and wants its code
/// immediately.
///
/// [theme] carries the Unicode fonts from [labelTheme]. Passing null falls back
/// to the built-in Latin-1 fonts, which silently drop any other script — see
/// `pdf_fonts.dart` for why that matters here.
Future<Uint8List> buildBinLabelPdf(BinModel bin, {pw.ThemeData? theme}) async {
  // Metadata, not page content: the `pdf` package encodes it as UTF-16, so a
  // Bengali label is safe here even when the page falls back to Latin-1 fonts.
  final doc = pw.Document(title: 'Chokro bin: ${bin.label}', theme: theme);

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(18 * PdfPageFormat.mm),
      build: (context) =>
          pw.Center(child: _labelCard(bin, 88 * PdfPageFormat.mm)),
    ),
  );

  return doc.save();
}

/// Several labels per page, four to an A4 sheet, with cut guides.
///
/// Registering twenty bins and printing twenty single-label pages wastes
/// nineteen sheets and a lot of an administrator's time. The label is the same
/// widget at a smaller barcode size, so the two documents cannot drift apart.
///
/// [bins] is printed in the order given; the caller decides the sort.
Future<Uint8List> buildBinLabelSheetPdf(
  List<BinModel> bins, {
  pw.ThemeData? theme,
}) async {
  // A print dialog for a zero-page document is a confusing thing to be shown,
  // so callers must not reach here with nothing to print.
  assert(bins.isNotEmpty, 'buildBinLabelSheetPdf called with no bins');

  final doc = pw.Document(title: 'Chokro bin labels', theme: theme);

  // Four to a page. Any more and the barcode gets too small to scan reliably
  // from the arm's length someone actually stands at.
  const perPage = 4;

  for (var start = 0; start < bins.length; start += perPage) {
    final page = bins.skip(start).take(perPage).toList();

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(10 * PdfPageFormat.mm),
        build: (context) => pw.Column(
          children: [
            for (var row = 0; row < 2; row++)
              pw.Expanded(
                child: pw.Row(
                  children: [
                    for (var col = 0; col < 2; col++)
                      pw.Expanded(
                        child: _cell(
                          // The last page is usually short. Empty cells keep
                          // the surviving labels in their own quarter of the
                          // sheet rather than stretching them.
                          row * 2 + col < page.length
                              ? page[row * 2 + col]
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  return doc.save();
}

/// A label inside a trim guide.
///
/// The border is the line to cut along. Shared by both documents so a label
/// trimmed off a four-up sheet is the same artefact as one printed on its own.
pw.Widget _labelCard(BinModel bin, double qrSize) {
  return pw.Container(
    padding: pw.EdgeInsets.all(
      7 * PdfPageFormat.mm * (qrSize / (88 * PdfPageFormat.mm)).clamp(0.7, 1.0),
    ),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
    ),
    child: _BinLabel(bin: bin, qrSize: qrSize),
  );
}

/// One quarter of a sheet.
pw.Widget _cell(BinModel? bin) {
  if (bin == null) return pw.SizedBox();

  return pw.Container(
    margin: const pw.EdgeInsets.all(3 * PdfPageFormat.mm),
    child: pw.Center(child: _labelCard(bin, 46 * PdfPageFormat.mm)),
  );
}

/// The label itself, at whatever barcode size the page has room for.
class _BinLabel extends pw.StatelessWidget {
  _BinLabel({required this.bin, required this.qrSize});

  final BinModel bin;
  final double qrSize;

  /// Text scales with the barcode so the sheet layout and the single-page
  /// layout stay in proportion instead of needing two sets of sizes.
  double get _scale => qrSize / (88 * PdfPageFormat.mm);

  @override
  pw.Widget build(pw.Context context) {
    return pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Text(
          'CHOKRO',
          style: pw.TextStyle(
            fontSize: 11 * _scale.clamp(0.6, 1.0),
            fontWeight: pw.FontWeight.bold,
            letterSpacing: 2,
            color: PdfColors.grey700,
          ),
        ),
        pw.SizedBox(height: 4 * PdfPageFormat.mm * _scale),

        pw.Text(
          bin.label,
          textAlign: pw.TextAlign.center,
          maxLines: 2,
          style: pw.TextStyle(
            fontSize: 20 * _scale.clamp(0.55, 1.0),
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 4 * PdfPageFormat.mm * _scale),

        // White plate behind the code. A scanner needs the light quiet zone
        // around a QR to find its edges, and printing onto coloured or
        // patterned stock removes it.
        pw.Container(
          padding: pw.EdgeInsets.all(4 * PdfPageFormat.mm * _scale),
          color: PdfColors.white,
          child: pw.BarcodeWidget(
            barcode: pw.Barcode.qrCode(errorCorrectLevel: _correction),
            data: bin.qrPayload,
            width: qrSize,
            height: qrSize,
            drawText: false,
          ),
        ),
        pw.SizedBox(height: 4 * PdfPageFormat.mm * _scale),

        pw.Text(
          'Scan with the Chokro app to log a disposal',
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(fontSize: 11 * _scale.clamp(0.65, 1.0)),
        ),
        pw.SizedBox(height: 1.5 * PdfPageFormat.mm * _scale),
        pw.Text(
          'You must be at this bin. Your location is checked.',
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontSize: 8.5 * _scale.clamp(0.7, 1.0),
            color: PdfColors.grey700,
          ),
        ),

        pw.SizedBox(height: 5 * PdfPageFormat.mm * _scale),
        pw.Divider(color: PdfColors.grey300, height: 0.5),
        pw.SizedBox(height: 2 * PdfPageFormat.mm * _scale),

        // Installer's strip. Whoever carries a stack of these to the street
        // needs to know which bin each belongs to, and support needs the
        // payload when someone reports that a code will not scan.
        //
        // Printing the coordinates here discloses nothing: the label is
        // physically attached to the bin it describes. What must never be
        // encoded is the *barcode* — see [BinModel.qrPayload].
        pw.Text(
          '${bin.lat.toStringAsFixed(5)}, ${bin.lng.toStringAsFixed(5)}'
          '  ·  ${bin.radiusMeters.round()} m radius',
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontSize: 7.5 * _scale.clamp(0.9, 1.0),
            color: PdfColors.grey600,
          ),
        ),
        pw.SizedBox(height: 1 * PdfPageFormat.mm * _scale),
        pw.Text(
          bin.qrPayload,
          textAlign: pw.TextAlign.center,
          maxLines: 1,
          style: pw.TextStyle(
            font: pw.Font.courier(),
            fontSize: 7 * _scale.clamp(0.9, 1.0),
            color: PdfColors.grey600,
          ),
        ),
      ],
    );
  }
}
