/// Chokro — bulk SKU import (EPR-10).
///
/// A beverage company has dozens of SKUs and will not type them one at a time.
///
/// ## Three properties this parser has, and why each one matters
///
/// **Strict template.** Unknown columns are refused, not ignored. A silently
/// ignored column is how a producer believes it declared a component breakdown
/// that never arrived, and discovers it when a report is short.
///
/// **All-or-nothing preview.** Nothing is written until every row parses.
/// A partial import leaves a producer with a catalogue it cannot reason about —
/// half the SKUs registered, half rejected, and no way to tell which without
/// reading a list of errors against a spreadsheet.
///
/// **No server-owned field accepted, ever.** A CSV that names `massStatus`,
/// `verifiedUnitMassG`, `revision`, `activeFrom` or `status` is refused with
/// that column named. This is the same allowlist discipline
/// `firestore.rules` applies to a create — restated here because a CSV is a
/// bulk write path and the rules can only police what the client sends, not
/// what a file suggested it should send.
///
/// Plain Dart, no Firebase and no Flutter imports. Pure and injectable (QA-1).
library;

import '../models/producer_sku_model.dart';
import 'epr_categories.dart';
import 'mass_math.dart';

/// The columns the template accepts.
///
/// Order is the template's order, which is the order the error report and the
/// downloadable blank use, so a producer's file and Chokro's message line up
/// column by column.
const List<String> skuCsvColumns = <String>[
  'name',
  'brand',
  'gtin',
  'volumeMl',
  'gazetteCategory',
  'polymer',
  'declaredUnitMassG',
  'components',
  'recognitionHints',
];

const List<String> skuCsvRequiredColumns = <String>[
  'name',
  'brand',
  'gazetteCategory',
  'polymer',
  'declaredUnitMassG',
  'components',
];

/// Columns a CSV may never set, each with the reason it is refused.
///
/// Named individually rather than caught by "not in the allowlist", so the
/// error tells a producer *why* the column is rejected instead of implying they
/// misspelled something.
const Map<String, String> skuCsvForbiddenColumns = <String, String>{
  'massStatus':
      'Chokro sets the verification status. A product cannot arrive verified.',
  'verifiedUnitMassG':
      'The verified mass is Chokro’s figure, established by weighing. Declare '
          'your own mass in declaredUnitMassG.',
  'verifiedUnitMassMg':
      'The verified mass is Chokro’s figure, established by weighing.',
  'verifiedBy': 'Chokro records who verified a mass.',
  'verifiedAt': 'Chokro records when a mass was verified.',
  'revision': 'Revisions are opened by Chokro when a mass changes.',
  'activeFrom': 'Effective dates are set by Chokro.',
  'activeTo': 'Effective dates are set by Chokro.',
  'status': 'A product’s lifecycle status is set in the app, not in the file.',
  'orgId': 'The organisation comes from your sign-in, not from the file.',
  'createdAt': 'The server clock records when a product was registered.',
};

/// The template a producer downloads, header plus one worked example.
///
/// The example is Appendix A's bottle, because a template whose sample row is
/// `name,brand,...` teaches nothing about the component syntax — which is the
/// only part of this format anyone gets wrong.
String skuCsvTemplate() => [
  skuCsvColumns.join(','),
  '"Coca-Cola 250 ml PET bottle","Coca-Cola",8901234567890,250,rigid,pet,10.0,'
      '"body:pet:8.15|cap:pp:1.3|label:pet:0.5|ring:pp:0.05",'
      '"red label|contour bottle"',
].join('\n');

/// One parsed row, or the reasons it could not be.
class SkuCsvRow {
  const SkuCsvRow({
    required this.lineNumber,
    this.sku,
    this.problems = const <String>[],
  });

  /// The line in the file, counting the header as line 1, so a message points
  /// at what the producer sees in their spreadsheet.
  final int lineNumber;

  final ProducerSkuModel? sku;
  final List<String> problems;

  bool get isValid => sku != null && problems.isEmpty;
}

/// The whole import, valid or not.
class SkuCsvImport {
  const SkuCsvImport({
    required this.rows,
    this.fileProblems = const <String>[],
  });

  final List<SkuCsvRow> rows;

  /// Problems with the file itself — a bad header, no rows, too many rows.
  /// These stop the import before any row is examined.
  final List<String> fileProblems;

  List<SkuCsvRow> get invalidRows =>
      rows.where((r) => !r.isValid).toList(growable: false);

  List<ProducerSkuModel> get skus =>
      rows.map((r) => r.sku).whereType<ProducerSkuModel>().toList(growable: false);

  /// All-or-nothing (EPR-10). One bad row stops the import.
  bool get canImport =>
      fileProblems.isEmpty && rows.isNotEmpty && invalidRows.isEmpty;

  int get validCount => rows.where((r) => r.isValid).length;

  /// The downloadable error report: the line number and every problem on it.
  String errorReport() {
    final lines = <String>['line,problem'];
    for (final problem in fileProblems) {
      lines.add('0,"${_escape(problem)}"');
    }
    for (final row in invalidRows) {
      for (final problem in row.problems) {
        lines.add('${row.lineNumber},"${_escape(problem)}"');
      }
    }
    return lines.join('\n');
  }
}

/// How many rows one import may carry.
///
/// A cap, in the manner of every other read and write bound in this codebase
/// (QA-10). Well above a beverage company's whole catalogue and far below
/// anything that would make a browser tab unresponsive or a batch write fail
/// halfway.
const int maxSkuCsvRows = 500;

/// Parses a CSV into draft SKUs.
///
/// Never throws. A malformed file produces problems, because the caller is a
/// screen showing a producer what is wrong with their spreadsheet, and an
/// exception there is a screen that says nothing.
SkuCsvImport parseSkuCsv(String content, {required String orgId}) {
  final fileProblems = <String>[];

  final lines = content
      .split(RegExp(r'\r\n|\r|\n'))
      .where((line) => line.trim().isNotEmpty)
      .toList();

  if (lines.isEmpty) {
    return const SkuCsvImport(
      rows: <SkuCsvRow>[],
      fileProblems: <String>['The file is empty.'],
    );
  }

  final header = _splitCsvLine(lines.first).map((h) => h.trim()).toList();

  for (final column in header) {
    final forbidden = skuCsvForbiddenColumns[column];
    if (forbidden != null) {
      fileProblems.add('Column "$column" is not accepted. $forbidden');
    } else if (!skuCsvColumns.contains(column)) {
      fileProblems.add(
        'Column "$column" is not part of the template. Accepted columns: '
        '${skuCsvColumns.join(', ')}.',
      );
    }
  }

  for (final required in skuCsvRequiredColumns) {
    if (!header.contains(required)) {
      fileProblems.add('Column "$required" is missing.');
    }
  }

  final bodyLines = lines.skip(1).toList();
  if (bodyLines.isEmpty) {
    fileProblems.add('The file has a header and no products.');
  }
  if (bodyLines.length > maxSkuCsvRows) {
    fileProblems.add(
      'The file has ${bodyLines.length} products. '
      '$maxSkuCsvRows is the most one import can carry.',
    );
  }

  if (fileProblems.isNotEmpty) {
    return SkuCsvImport(rows: const <SkuCsvRow>[], fileProblems: fileProblems);
  }

  final rows = <SkuCsvRow>[];
  for (var i = 0; i < bodyLines.length; i += 1) {
    rows.add(
      _parseRow(
        bodyLines[i],
        header: header,
        // Header is line 1, so the first product is line 2 — the number the
        // producer's spreadsheet shows.
        lineNumber: i + 2,
        orgId: orgId,
      ),
    );
  }

  return SkuCsvImport(rows: rows);
}

SkuCsvRow _parseRow(
  String line, {
  required List<String> header,
  required int lineNumber,
  required String orgId,
}) {
  final problems = <String>[];
  final cells = _splitCsvLine(line);

  if (cells.length != header.length) {
    return SkuCsvRow(
      lineNumber: lineNumber,
      problems: [
        'This row has ${cells.length} values but the header has '
            '${header.length} columns.',
      ],
    );
  }

  final values = <String, String>{
    for (var i = 0; i < header.length; i += 1) header[i]: cells[i].trim(),
  };

  final name = values['name'] ?? '';
  final brand = values['brand'] ?? '';
  final category = values['gazetteCategory'] ?? '';
  final polymer = values['polymer'] ?? '';

  if (name.length < 3) problems.add('name: give the product a name.');
  if (name.length > 140) problems.add('name: too long (140 characters max).');
  if (brand.length < 2) problems.add('brand: name the brand.');

  if (!GazetteCategory.isValid(category)) {
    problems.add(
      'gazetteCategory: "$category" is not one of '
      '${GazetteCategory.all.join(', ')}.',
    );
  }
  if (!PolymerType.isValid(polymer)) {
    problems.add(
      'polymer: "$polymer" is not one of ${PolymerType.all.join(', ')}.',
    );
  }

  final declaredMg = milligramsFromGrams(values['declaredUnitMassG']);
  if (declaredMg == null) {
    problems.add(
      'declaredUnitMassG: "${values['declaredUnitMassG']}" is not a mass '
      'between ${formatGrams(minUnitMassMg)} and ${formatGrams(maxUnitMassMg)}.',
    );
  }

  final components = <SkuComponent>[];
  final componentText = values['components'] ?? '';
  if (componentText.isEmpty) {
    problems.add(
      'components: required. Use part:polymer:grams, separated by "|" — '
      'for example body:pet:8.2|cap:pp:1.3.',
    );
  } else {
    for (final piece in componentText.split('|')) {
      final parsed = _parseComponent(piece.trim());
      if (parsed.component == null) {
        problems.add('components: "$piece" — ${parsed.problem}.');
      } else {
        components.add(parsed.component!);
      }
    }
  }

  if (declaredMg != null &&
      components.isNotEmpty &&
      !componentsSumToDeclared(
        componentMassesMg: components.map((c) => c.massMg),
        declaredUnitMassMg: declaredMg,
      )) {
    final sum = sumMilligrams(components.map((c) => c.massMg));
    final difference = sum.totalMg - declaredMg;
    problems.add(
      'components add up to ${formatGramsExact(sum.totalMg)} but '
      'declaredUnitMassG is ${formatGramsExact(declaredMg)} — '
      '${formatGramsExact(difference.abs())} '
      '${difference > 0 ? 'too much' : 'short'}.',
    );
  }

  final gtin = values['gtin'];
  if (gtin != null && gtin.isNotEmpty && !RegExp(r'^\d{8,14}$').hasMatch(gtin)) {
    // Refused rather than dropped: a GTIN is the barcode path to a
    // high-confidence attribution with no model involvement (EPR-18), so a
    // silently discarded one is a silently discarded accuracy improvement.
    problems.add('gtin: "$gtin" is not 8 to 14 digits.');
  }

  final volumeText = values['volumeMl'];
  int? volumeMl;
  if (volumeText != null && volumeText.isNotEmpty) {
    volumeMl = int.tryParse(volumeText);
    if (volumeMl == null || volumeMl <= 0 || volumeMl > 100000) {
      problems.add('volumeMl: "$volumeText" is not a volume in millilitres.');
    }
  }

  final hints = (values['recognitionHints'] ?? '')
      .split('|')
      .map((h) => h.trim())
      .where((h) => h.isNotEmpty)
      .take(12)
      .toList();

  if (problems.isNotEmpty) {
    return SkuCsvRow(lineNumber: lineNumber, problems: problems);
  }

  return SkuCsvRow(
    lineNumber: lineNumber,
    sku: ProducerSkuModel(
      // The server assigns the real id; a draft parsed from a file has none.
      id: '',
      orgId: orgId,
      name: name,
      brand: brand,
      gtin: gtin == null || gtin.isEmpty ? null : gtin,
      volumeMl: volumeMl,
      gazetteCategory: category,
      polymer: polymer,
      declaredUnitMassMg: declaredMg!,
      components: components,
      recognitionHints: hints,
      // Sample photographs cannot travel in a CSV, so an imported SKU arrives
      // as a draft and cannot be submitted for verification until somebody adds
      // them in the app (EPR-9). Stated in the import summary, not discovered
      // later.
      status: SkuStatus.draft,
      massStatus: MassStatus.draft,
    ),
  );
}

/// `part:polymer:grams`, e.g. `body:pet:8.2`.
///
/// Returns the reason it could not be read rather than a bare null, so the
/// error report names the actual cause. It used to say "is not
/// part:polymer:grams with a known polymer" for a component whose syntax and
/// polymer were both fine and whose mass was simply below the floor — which
/// sent producers looking for a typo that was not there.
_ComponentParse _parseComponent(String text) {
  final parts = text.split(':');
  if (parts.length != 3) {
    return const _ComponentParse.failed(
      'expected part:polymer:grams, separated by colons',
    );
  }

  final part = parts[0].trim();
  final polymer = parts[1].trim();
  final gramsText = parts[2].trim();

  if (part.isEmpty) return const _ComponentParse.failed('the part has no name');
  if (part.length > 60) {
    return const _ComponentParse.failed('the part name is too long');
  }
  if (!PolymerType.isValid(polymer)) {
    return _ComponentParse.failed(
      '"$polymer" is not one of ${PolymerType.all.join(', ')}',
    );
  }

  // The component floor (1 mg), not the unit floor (0.1 g): a tamper ring or a
  // foil seal legitimately weighs 0.05 g.
  final grams = double.tryParse(gramsText);
  if (grams == null) {
    return _ComponentParse.failed('"$gramsText" is not a mass in grams');
  }
  final massMg = (grams * mgPerGram).round();
  if (massMg < minComponentMassMg) {
    return _ComponentParse.failed(
      '"$gramsText" g is below the ${formatGramsExact(minComponentMassMg)} '
      'minimum for a part',
    );
  }
  if (massMg > maxUnitMassMg) {
    return _ComponentParse.failed('"$gramsText" g is too heavy for one part');
  }

  return _ComponentParse.parsed(
    SkuComponent(part: part, polymer: polymer, massMg: massMg),
  );
}

/// A parsed component, or why it could not be.
class _ComponentParse {
  const _ComponentParse.parsed(this.component) : problem = null;
  const _ComponentParse.failed(this.problem) : component = null;

  final SkuComponent? component;
  final String? problem;
}

/// A CSV line splitter that understands quoting.
///
/// Written rather than installed for the same reason `rateLimit.js` is: the
/// grammar this template needs is quoted fields with embedded commas and
/// doubled quotes, which is thirty lines that can be read in full. A dependency
/// would bring a configuration surface and a lockfile entry for the same
/// behaviour, and the limitation would be less visible rather than more.
///
/// It does **not** handle a newline inside a quoted field, because the caller
/// splits on newlines first. A product name containing a line break is refused
/// as a column-count mismatch, which is a comprehensible error rather than a
/// silently mangled row.
List<String> _splitCsvLine(String line) {
  final cells = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < line.length; i += 1) {
    final char = line[i];

    if (inQuotes) {
      if (char == '"') {
        // A doubled quote inside a quoted field is one literal quote.
        if (i + 1 < line.length && line[i + 1] == '"') {
          buffer.write('"');
          i += 1;
        } else {
          inQuotes = false;
        }
      } else {
        buffer.write(char);
      }
      continue;
    }

    if (char == '"') {
      inQuotes = true;
    } else if (char == ',') {
      cells.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(char);
    }
  }

  cells.add(buffer.toString());
  return cells;
}

String _escape(String value) => value.replaceAll('"', '""');
