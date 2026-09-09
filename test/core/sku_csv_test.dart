/// Bulk SKU import (EPR-10).
library;

import 'package:chokro/core/epr_categories.dart';
import 'package:chokro/core/sku_csv.dart';
import 'package:chokro/models/producer_sku_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _header =
    'name,brand,gtin,volumeMl,gazetteCategory,polymer,declaredUnitMassG,'
    'components,recognitionHints';

const _goodRow =
    '"Coca-Cola 250 ml PET bottle","Coca-Cola",8901234567890,250,rigid,pet,'
    '10.0,"body:pet:8.2|cap:pp:1.3|label:pet:0.5","red label|contour bottle"';

SkuCsvImport _parse(String body) => parseSkuCsv(body, orgId: 'org_cola');

void main() {
  group('the happy path', () {
    test('parses the worked example', () {
      final import = _parse('$_header\n$_goodRow');

      expect(import.canImport, isTrue);
      expect(import.validCount, 1);

      final sku = import.skus.single;
      expect(sku.name, 'Coca-Cola 250 ml PET bottle');
      expect(sku.brand, 'Coca-Cola');
      expect(sku.gtin, '8901234567890');
      expect(sku.volumeMl, 250);
      expect(sku.gazetteCategory, GazetteCategory.rigid);
      expect(sku.polymer, PolymerType.pet);
      expect(sku.declaredUnitMassMg, 10000);
      expect(sku.orgId, 'org_cola');
      expect(sku.recognitionHints, ['red label', 'contour bottle']);
    });

    test('the component breakdown survives, per part and per polymer', () {
      final sku = _parse('$_header\n$_goodRow').skus.single;

      expect(sku.components, hasLength(3));
      expect(sku.components.first.part, 'body');
      expect(sku.components.first.massMg, 8200);
      expect(sku.componentsBalance, isTrue);
      // One recognised unit contributing to two polymer lines is the whole
      // reason components exist (EPR-9).
      expect(sku.massByPolymerMg, {'pet': 8700, 'pp': 1300});
    });

    test('an imported product arrives as an unverified draft', () {
      // Sample photographs cannot travel in a CSV, so it cannot be submitted
      // for verification until somebody adds them in the app.
      final sku = _parse('$_header\n$_goodRow').skus.single;
      expect(sku.massStatus, MassStatus.draft);
      expect(sku.status, SkuStatus.draft);
      expect(sku.hasVerifiedMass, isFalse);
      expect(sku.canSubmit, isFalse);
      expect(
        sku.submissionProblems.join(' '),
        contains('sample photographs'),
      );
    });

    test('the template it ships parses as valid', () {
      // A template whose own sample row does not import is a template that
      // teaches the wrong syntax.
      final import = _parse(skuCsvTemplate());
      expect(import.canImport, isTrue);
    });

    test('quoted fields with commas and doubled quotes are read correctly', () {
      final row =
          '"Bottle, 250 ml, ""slim""","Brand",,,rigid,pet,5.0,"body:pet:5.0",';
      final sku = _parse('$_header\n$row').skus.single;
      expect(sku.name, 'Bottle, 250 ml, "slim"');
    });

    test('optional columns may be blank', () {
      final row = 'Sachet,Brand,,,flexible,multilayer,2.5,body:multilayer:2.5,';
      final import = _parse('$_header\n$row');
      expect(import.canImport, isTrue);
      expect(import.skus.single.gtin, isNull);
      expect(import.skus.single.volumeMl, isNull);
    });
  });

  group('the strict template refuses what it does not know', () {
    test('an unknown column stops the import and is named', () {
      // A silently ignored column is how a producer believes it declared
      // something that never arrived.
      final import = _parse('$_header,colour\n$_goodRow,red');
      expect(import.canImport, isFalse);
      expect(import.fileProblems.join(' '), contains('"colour"'));
    });

    test('a missing required column is named', () {
      final import = _parse(
        'name,brand,gazetteCategory,polymer,declaredUnitMassG\n'
        'Bottle,Brand,rigid,pet,10.0',
      );
      expect(import.canImport, isFalse);
      expect(import.fileProblems.join(' '), contains('"components" is missing'));
    });

    test('every server-owned column is refused, each with its own reason', () {
      // The rules can only police what the client sends, not what a file
      // suggested it should send — so the refusal is here too.
      for (final column in skuCsvForbiddenColumns.keys) {
        final import = _parse('$_header,$column\n$_goodRow,anything');
        expect(
          import.canImport,
          isFalse,
          reason: '$column must never be accepted from a file',
        );
        final message = import.fileProblems.join(' ');
        expect(message, contains('"$column" is not accepted'));
        expect(
          message,
          contains(skuCsvForbiddenColumns[column]!.split('.').first),
          reason: 'the refusal must say why, not just that',
        );
      }
    });

    test('a verified mass in a file cannot become a verified mass', () {
      final import = _parse(
        '$_header,verifiedUnitMassG\n$_goodRow,9.8',
      );
      expect(import.canImport, isFalse);
      expect(import.skus, isEmpty);
    });
  });

  group('per-row validation', () {
    test('an unknown category or polymer is refused with the allowed set', () {
      final row =
          'Bottle,Brand,,,compostable,unobtainium,10.0,body:pet:10.0,';
      final import = _parse('$_header\n$row');
      final problems = import.invalidRows.single.problems.join(' ');
      expect(problems, contains('gazetteCategory'));
      expect(problems, contains('rigid'));
      expect(problems, contains('polymer'));
      expect(problems, contains('hdpe'));
    });

    test('an unreadable or out-of-range mass is refused', () {
      for (final mass in ['', 'ten', '0', '-5', '5000.1', '0.05']) {
        final row = 'Bottle,Brand,,,rigid,pet,$mass,body:pet:10.0,';
        final import = _parse('$_header\n$row');
        expect(
          import.canImport,
          isFalse,
          reason: '"$mass" must not parse as a unit mass',
        );
      }
    });

    test('components that do not add up are refused, with exact figures', () {
      final row =
          'Bottle,Brand,,,rigid,pet,10.0,"body:pet:8.2|cap:pp:1.3",';
      final problems = _parse('$_header\n$row').invalidRows.single.problems;
      expect(problems.join(' '), contains('9.5 g'));
      expect(problems.join(' '), contains('10 g'));
      // And the shortfall, named — so the producer does not have to subtract.
      expect(problems.join(' '), contains('0.5 g'));
    });

    test('a one-milligram mismatch is reported as a real difference', () {
      // Rounding both sides to three significant figures produced
      // "add up to 10 g but declaredUnitMassG is 10 g".
      final row =
          'Bottle,Brand,,,rigid,pet,10.0,"body:pet:8.2|cap:pp:1.3|label:pet:0.501",';
      final problems =
          _parse('$_header\n$row').invalidRows.single.problems.join(' ');
      expect(problems, contains('10.001 g'));
      expect(problems, contains('0.001 g'));
    });

    test('a malformed component is named rather than dropped', () {
      final row = 'Bottle,Brand,,,rigid,pet,10.0,"body-pet-10.0",';
      expect(
        _parse('$_header\n$row').invalidRows.single.problems.join(' '),
        contains('part:polymer:grams'),
      );
    });

    test('a bad GTIN is refused rather than silently discarded', () {
      // A GTIN is the barcode path to a high-confidence attribution with no
      // model involvement, so a dropped one is a dropped accuracy improvement.
      final row = 'Bottle,Brand,ABC123,,rigid,pet,10.0,body:pet:10.0,';
      expect(
        _parse('$_header\n$row').invalidRows.single.problems.join(' '),
        contains('gtin'),
      );
    });

    test('a wrong number of values points at the row, not the file', () {
      final import = _parse('$_header\nBottle,Brand');
      expect(import.canImport, isFalse);
      expect(import.fileProblems, isEmpty);
      expect(
        import.invalidRows.single.problems.single,
        contains('2 values but the header has 9 columns'),
      );
    });

    test('every problem on a row is reported, not the first', () {
      final row = 'X,Y,,,nope,nope,zero,,';
      expect(
        _parse('$_header\n$row').invalidRows.single.problems.length,
        greaterThan(3),
      );
    });
  });

  group('a component lighter than the unit floor is legitimate', () {
    test('a 0.05 g tamper ring imports', () {
      // The bug: the unit floor of 0.1 g was applied to every part, so this row
      // was rejected — and rejected with a message naming the wrong cause
      // ("is not part:polymer:grams with a known polymer") when the syntax and
      // the polymer were both fine.
      final row =
          '"250 ml PET bottle","Cola",,250,rigid,pet,10.0,'
          '"body:pet:8.15|cap:pp:1.3|label:pet:0.5|ring:pp:0.05",';
      final import = _parse('$_header\n$row');

      expect(import.canImport, isTrue);
      expect(import.skus.single.components, hasLength(4));
      expect(import.skus.single.components.last.massMg, 50);
    });

    test('a zero or negative part mass is still refused', () {
      for (final mass in ['0', '-1', '0.0']) {
        final row =
            '"Bottle","Cola",,,rigid,pet,10.0,"body:pet:10.0|x:pp:$mass",';
        expect(
          _parse('$_header\n$row').canImport,
          isFalse,
          reason: 'a part of $mass g must not parse',
        );
      }
    });

    test('a failed component names the actual cause', () {
      final cases = <String, String>{
        'body-pet-8.2': 'expected part:polymer:grams',
        'body:unobtainium:8.2': 'is not one of',
        ':pet:8.2': 'has no name',
        'body:pet:abc': 'is not a mass in grams',
        'body:pet:0.0001': 'below the',
      };

      for (final entry in cases.entries) {
        final row = '"Bottle","Cola",,,rigid,pet,10.0,"${entry.key}",';
        final problems =
            _parse('$_header\n$row').invalidRows.single.problems.join(' ');
        expect(
          problems,
          contains(entry.value),
          reason: '"${entry.key}" should be explained as "${entry.value}"',
        );
      }
    });
  });

  group('all-or-nothing', () {
    test('one bad row stops the whole import', () {
      // A partial import leaves a producer with a catalogue it cannot reason
      // about.
      final bad = 'Bottle,Brand,,,rigid,pet,10.0,"body:pet:9.0",';
      final import = _parse('$_header\n$_goodRow\n$bad');

      expect(import.validCount, 1);
      expect(import.invalidRows, hasLength(1));
      expect(import.canImport, isFalse);
    });

    test('line numbers match what the spreadsheet shows', () {
      final bad = 'Bottle,Brand,,,rigid,pet,10.0,"body:pet:9.0",';
      final import = _parse('$_header\n$_goodRow\n$bad');
      // Header is line 1, first product line 2, so the bad row is line 3.
      expect(import.invalidRows.single.lineNumber, 3);
    });

    test('an empty file and a header-only file are both refused', () {
      expect(_parse('').canImport, isFalse);
      expect(_parse('   \n  ').fileProblems.join(' '), contains('empty'));
      expect(
        _parse(_header).fileProblems.join(' '),
        contains('header and no products'),
      );
    });

    test('the row cap is enforced and states both numbers', () {
      final rows = List.filled(maxSkuCsvRows + 1, _goodRow).join('\n');
      final import = _parse('$_header\n$rows');
      expect(import.canImport, isFalse);
      expect(import.fileProblems.join(' '), contains('${maxSkuCsvRows + 1}'));
      expect(import.fileProblems.join(' '), contains('$maxSkuCsvRows'));
    });

    test('a file at the cap imports', () {
      final rows = List.filled(maxSkuCsvRows, _goodRow).join('\n');
      expect(_parse('$_header\n$rows').canImport, isTrue);
    });
  });

  group('the error report', () {
    test('is a CSV of line and problem, quoted safely', () {
      final bad = 'Bottle,Brand,,,rigid,pet,10.0,"body:pet:9.0",';
      final report = _parse('$_header\n$bad').errorReport();

      expect(report.split('\n').first, 'line,problem');
      expect(report, contains('2,'));
      // A problem containing a quote must not break the file it is written to.
      expect(RegExp(r'^\d+,".*"$', multiLine: true).hasMatch(report), isTrue);
    });

    test('file-level problems are reported on line 0', () {
      final report = _parse('$_header,colour\n$_goodRow,red').errorReport();
      expect(report, contains('0,'));
    });
  });

  group('line endings', () {
    test('CRLF and CR files parse the same as LF', () {
      // A spreadsheet exported on Windows is the common case, not the edge one.
      for (final ending in ['\n', '\r\n', '\r']) {
        final import = _parse('$_header$ending$_goodRow');
        expect(
          import.canImport,
          isTrue,
          reason: 'line ending ${ending.codeUnits} must parse',
        );
      }
    });
  });
}
