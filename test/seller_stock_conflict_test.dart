import 'package:flutter_test/flutter_test.dart';

/// Which stock figure a listing save should publish.
///
/// `stock` is the one product field both parties write. The seller's editor
/// saves an absolute value; `server/src/checkout.js` decrements the same field
/// relatively on every purchase, with `FieldValue.increment(-qty)`. And `_seed`
/// fills the form once and never again — deliberately, so a live stream update
/// cannot overwrite what the seller is typing.
///
/// Put together, a seller who opened the editor with 10 in stock, changed only
/// the description, and saved twenty minutes later wrote 10 back over three
/// sales — resurrecting stock that did not exist, which the next buyer ordered
/// and the server then refused at checkout.
///
/// This pins the decision table the editor now follows.
enum StockResolution { takeLive, publishTyped, ask }

StockResolution resolve({
  required String opened,
  required String typed,
  required int live,
}) {
  final movedUnderneath = live.toString() != opened;
  final sellerEditedIt = typed != opened;

  if (movedUnderneath && !sellerEditedIt) return StockResolution.takeLive;
  if (movedUnderneath && sellerEditedIt) return StockResolution.ask;
  return StockResolution.publishTyped;
}

void main() {
  group('stock reconciliation on save', () {
    test('an untouched field takes the live count, not the opening one', () {
      // The silent data-loss case: the seller edited the description only.
      expect(
        resolve(opened: '10', typed: '10', live: 7),
        StockResolution.takeLive,
      );
    });

    test('nothing moved, so the typed figure is published as-is', () {
      expect(
        resolve(opened: '10', typed: '10', live: 10),
        StockResolution.publishTyped,
      );
    });

    test('the seller restocked and nothing sold — publish their number', () {
      expect(
        resolve(opened: '10', typed: '25', live: 10),
        StockResolution.publishTyped,
      );
    });

    test('both moved, so only the seller can say which number is right', () {
      // Never resolved silently: taking either side without asking is a lie
      // about a number a buyer is about to act on.
      expect(resolve(opened: '10', typed: '25', live: 7), StockResolution.ask);
    });

    test('selling out under an untouched field is still taken live', () {
      expect(
        resolve(opened: '3', typed: '3', live: 0),
        StockResolution.takeLive,
      );
    });
  });
}
