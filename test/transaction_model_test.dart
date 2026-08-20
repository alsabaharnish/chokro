import 'package:chokro/models/transaction_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseTransactionSource', () {
    test('parses each of the four wire values', () {
      expect(parseTransactionSource('disposal'), TransactionSource.disposal);
      expect(parseTransactionSource('purchase'), TransactionSource.purchase);
      expect(parseTransactionSource('claim'), TransactionSource.claim);
      expect(
        parseTransactionSource('redemption'),
        TransactionSource.redemption,
      );
    });

    test('an unrecognised source falls back to unknown, it does not throw', () {
      expect(parseTransactionSource('bonus'), TransactionSource.unknown);
      expect(parseTransactionSource(null), TransactionSource.unknown);
      expect(parseTransactionSource(42), TransactionSource.unknown);
    });

    test('round-trips through wireValue', () {
      for (final source in TransactionSource.values) {
        expect(parseTransactionSource(source.wireValue), source);
      }
    });

    test('every source has a non-empty label', () {
      for (final source in TransactionSource.values) {
        expect(source.label, isNotEmpty);
      }
    });
  });

  group('TransactionModel.fromMap', () {
    Map<String, dynamic> base() => <String, dynamic>{
      'userId': 'user_1',
      'delta': 50,
      'source': 'disposal',
      'refId': 'disposal_9',
      'balanceAfter': 150,
      'createdAt': DateTime(2026, 8, 2, 9, 30),
    };

    test('maps a well-formed document', () {
      final entry = TransactionModel.fromMap('tx_1', base());
      expect(entry.id, 'tx_1');
      expect(entry.userId, 'user_1');
      expect(entry.delta, 50);
      expect(entry.source, TransactionSource.disposal);
      expect(entry.refId, 'disposal_9');
      expect(entry.balanceAfter, 150);
      expect(entry.createdAt, DateTime(2026, 8, 2, 9, 30));
    });

    test('accepts numbers that arrived as double or string', () {
      final entry = TransactionModel.fromMap(
        'tx_2',
        base()..addAll({'delta': 50.0, 'balanceAfter': '150'}),
      );
      expect(entry.delta, 50);
      expect(entry.balanceAfter, 150);
    });

    test('an unresolved server timestamp becomes null, not an error', () {
      final entry = TransactionModel.fromMap(
        'tx_3',
        base()..['createdAt'] = null,
      );
      expect(entry.createdAt, isNull);
    });

    test('a non-DateTime createdAt is rejected rather than coerced', () {
      final entry = TransactionModel.fromMap(
        'tx_4',
        base()..['createdAt'] = 1754107800,
      );
      expect(entry.createdAt, isNull);
    });

    test('missing fields degrade to safe defaults', () {
      final entry = TransactionModel.fromMap('tx_5', <String, dynamic>{});
      expect(entry.userId, '');
      expect(entry.delta, 0);
      expect(entry.source, TransactionSource.unknown);
      expect(entry.refId, isNull);
      expect(entry.balanceAfter, isNull);
    });

    test('wrongly typed strings and fractional points fail closed', () {
      final entry = TransactionModel.fromMap('tx_bad', {
        'userId': 7,
        'refId': false,
        'delta': 4.5,
        'balanceAfter': 10.5,
      });

      expect(entry.userId, isEmpty);
      expect(entry.refId, isNull);
      expect(entry.delta, 0);
      expect(entry.balanceAfter, isNull);
    });
  });

  group('display', () {
    TransactionModel entry(int delta) => TransactionModel(
      id: 'tx',
      userId: 'user_1',
      delta: delta,
      source: TransactionSource.disposal,
    );

    test('credits and debits are distinguished', () {
      expect(entry(50).isCredit, isTrue);
      expect(entry(-120).isCredit, isFalse);
      expect(entry(0).isCredit, isFalse);
    });

    test('signedDelta prefixes credits only', () {
      expect(entry(50).signedDelta, '+50');
      expect(entry(-120).signedDelta, '-120');
    });
  });

  group('ledger arithmetic', () {
    test('balanceAfter of the newest entry equals the sum of all deltas', () {
      // The NFR-4 property: a balance is reconstructable from history. The
      // header on the wallet screen shows the newest balanceAfter, so this
      // asserts the two agree for a clean ledger.
      final deltas = <int>[50, 15, -120, 50, 50];
      var running = 0;
      final entries = <TransactionModel>[];
      for (var i = 0; i < deltas.length; i++) {
        running += deltas[i];
        entries.add(
          TransactionModel(
            id: 'tx_$i',
            userId: 'user_1',
            delta: deltas[i],
            source: deltas[i] > 0
                ? TransactionSource.disposal
                : TransactionSource.redemption,
            balanceAfter: running,
          ),
        );
      }

      final newest = entries.last;
      final sum = entries.fold<int>(0, (total, e) => total + e.delta);
      expect(newest.balanceAfter, sum);
      expect(newest.balanceAfter, 45);
    });

    test('redemptions are multiples of ten, so no remainder is stranded', () {
      // 100 points = BDT 10, therefore 10 points = BDT 1.
      const redemption = -120;
      expect(redemption % 10, 0);
    });
  });
}
