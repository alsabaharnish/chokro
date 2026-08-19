import 'package:chokro/models/cart_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const empty = CartModel(userId: 'buyer');

  group('adding and merging', () {
    test('adds a new line', () {
      final cart = empty.withItem('p1');

      expect(cart.items.length, 1);
      expect(cart.qtyOf('p1'), 1);
    });

    test('merges into an existing line rather than duplicating it', () {
      final cart = empty.withItem('p1').withItem('p1', qty: 2);

      expect(cart.items.length, 1);
      expect(cart.qtyOf('p1'), 3);
    });

    test('clamps a line at the maximum instead of climbing forever', () {
      final cart = empty.withItem('p1', qty: CartItem.maxQty + 50);
      expect(cart.qtyOf('p1'), CartItem.maxQty);
    });

    test('refuses a new line past the cart ceiling', () {
      var cart = empty;
      for (var i = 0; i < CartItem.maxItems + 5; i++) {
        cart = cart.withItem('p$i');
      }

      expect(cart.items.length, CartItem.maxItems);
    });

    test('adding zero or less removes the line', () {
      final cart = empty.withItem('p1').withItem('p1', qty: 0);
      expect(cart.qtyOf('p1'), 0);
    });
  });

  group('quantity and removal', () {
    test('sets an exact quantity', () {
      final cart = empty.withItem('p1', qty: 5).withQuantity('p1', 2);
      expect(cart.qtyOf('p1'), 2);
    });

    test('setting a quantity of zero removes the line', () {
      final cart = empty.withItem('p1').withQuantity('p1', 0);

      expect(cart.isEmpty, isTrue);
    });

    test('setting a quantity on an absent product adds it', () {
      expect(empty.withQuantity('p1', 3).qtyOf('p1'), 3);
    });

    test('removal leaves the other lines alone', () {
      final cart = empty.withItem('p1').withItem('p2').withoutItem('p1');

      expect(cart.qtyOf('p1'), 0);
      expect(cart.qtyOf('p2'), 1);
    });

    test('clearing empties the cart but keeps the owner', () {
      final cart = empty.withItem('p1').cleared();

      expect(cart.isEmpty, isTrue);
      expect(cart.userId, 'buyer');
    });

    test('is immutable — an operation never edits the receiver', () {
      final original = empty.withItem('p1');
      original.withItem('p2');

      expect(original.items.length, 1);
    });
  });

  test('unitCount totals quantities, not lines', () {
    final cart = empty.withItem('p1', qty: 3).withItem('p2', qty: 4);
    expect(cart.unitCount, 7);
  });

  group('parsing tolerates whatever is in the document', () {
    test('drops entries that are not usable lines', () {
      final cart = CartModel.fromMap({
        'items': [
          {'productId': 'p1', 'qty': 2},
          {'productId': '', 'qty': 2},
          {'productId': 'p2'},
          {'qty': 5},
          'nonsense',
          {'productId': 'p3', 'qty': 0},
          {'productId': 'p4', 'qty': 999},
        ],
      }, userId: 'buyer');

      expect(cart.items.length, 1);
      expect(cart.qtyOf('p1'), 2);
    });

    test('a missing document is an empty cart, not an error', () {
      final cart = CartModel.fromMap(null, userId: 'buyer');

      expect(cart.isEmpty, isTrue);
      expect(cart.userId, 'buyer');
    });

    test('stops at the cart ceiling however long the array is', () {
      final cart = CartModel.fromMap({
        'items': [
          for (var i = 0; i < 100; i++) {'productId': 'p$i', 'qty': 1},
        ],
      }, userId: 'buyer');

      expect(cart.items.length, CartItem.maxItems);
    });
  });

  group('the write payload never carries a price', () {
    test('an item is a product and a quantity, and nothing else', () {
      final json = empty.withItem('p1', qty: 2).toJson();
      final items = json['items'] as List;

      expect((items.first as Map).keys.toSet(), {'productId', 'qty'});
    });

    test('the document itself carries no total', () {
      final json = empty.withItem('p1').toJson();

      expect(json.keys.toSet(), {'userId', 'items'});
    });
  });
}
