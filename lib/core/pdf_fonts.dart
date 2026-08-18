/// Fonts for the printed bin label (F2.1).
///
/// ## Why this is not just Helvetica
///
/// The `pdf` package's built-in fonts are the PDF standard 14 — Helvetica,
/// Courier, Times — which are Latin-1 only. Anything outside that set is not
/// drawn at all: no fallback glyph, no box, nothing. The text silently
/// disappears from the page.
///
/// Two things on this label are affected. The brief's own example bin label is
/// "Merul Badda — Block C gate", and that em dash is already outside Latin-1.
/// More seriously, this is an app for Dhaka: a label written in Bengali —
/// "মেরুল বাড্ডা" — would print as an empty space, and the administrator would
/// not find out until they were standing at the bin holding a blank label.
///
/// So the label is drawn in Noto Sans with Noto Sans Bengali behind it, which
/// covers both scripts the app is actually used in.
///
/// ## Why it degrades instead of failing
///
/// `PdfGoogleFonts` fetches over the network. An administrator registering a bin
/// necessarily has a connection, because registration itself goes through the
/// server — but reprinting an old label offline should not be impossible. On a
/// fetch failure this returns null and the caller prints with the built-in
/// fonts: an ASCII label still comes out correctly, which is strictly better
/// than refusing to print.
///
/// A failure is not cached, so the next attempt tries again rather than leaving
/// the app in Latin-1 mode until it restarts.
library;

import 'package:flutter/foundation.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

Future<pw.ThemeData?>? _cached;

/// Fonts covering Latin and Bengali, or null to fall back to the built-ins.
///
/// Memoised: printing a twenty-label sheet must not fetch four font files
/// twenty times.
Future<pw.ThemeData?> labelTheme() => _cached ??= _load();

Future<pw.ThemeData?> _load() async {
  try {
    // Fetched together rather than in sequence — four round trips in series is
    // a visible pause before the print dialog appears.
    final fonts = await Future.wait([
      PdfGoogleFonts.notoSansRegular(),
      PdfGoogleFonts.notoSansBold(),
      PdfGoogleFonts.notoSansBengaliRegular(),
      PdfGoogleFonts.notoSansBengaliBold(),
    ]);

    return pw.ThemeData.withFont(
      base: fonts[0],
      bold: fonts[1],
      // Consulted glyph by glyph, so a label mixing Bengali and Latin — a
      // street name in Bengali with a block number in digits — renders whole.
      fontFallback: [fonts[2], fonts[3]],
    );
  } catch (error) {
    if (kDebugMode) {
      debugPrint('[pdf_fonts] falling back to built-in fonts: $error');
    }
    // Not cached, so going back online restores Unicode without a restart.
    _cached = null;
    return null;
  }
}

/// Drops the memoised fonts. For tests.
@visibleForTesting
void resetLabelThemeCache() => _cached = null;
