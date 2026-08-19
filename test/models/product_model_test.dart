import 'package:chokro/core/product_taxonomy.dart';
import 'package:chokro/models/product_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ProductModel saved({
    String title = 'Bamboo Toothbrush',
    String description = 'A biodegradable brush with soft bristles.',
    int price = 250,
    int stock = 12,
    List<String> tags = const ['Eco Friendly', 'bamboo'],
    List<String> images = const [],
    bool active = true,
  }) =>
      ProductModel.forSave(
        id: 'p1',
        sellerId: 'seller_uid',
        shopName: 'Green Corner',
        title: title,
        description: description,
        category: ProductCategory.personalCare,
        price: price,
        stock: stock,
        tags: tags,
        imageUrls: images,
        active: active,
      );

  group('forSave derives the index rather than trusting a form', () {
    test('computes titleLower and searchTokens', () {
      final product = saved();

      expect(product.toCreateJson()['titleLower'], 'bamboo toothbrush');
      expect(product.searchTokens, contains('toothbrush'));
      expect(product.searchTokens, contains('eco-friendly'));
    });

    test('normalises the tags it stores', () {
      expect(saved().tags, ['bamboo', 'eco-friendly']);
    });

    test('trims the free text', () {
      final product = saved(title: '  Jute Bag  ');
      expect(product.title, 'Jute Bag');
    });

    test('caps images at the number the rules can validate', () {
      final product = saved(images: const ['a', 'b', 'c', 'd']);
      expect(product.imageUrls.length, ProductLimits.maxImages);
    });

    test('recomputes the index when copyWith changes the title', () {
      final renamed = saved().copyWith(title: 'Copper Bottle');

      expect(renamed.searchTokens, contains('copper'));
      expect(renamed.searchTokens, isNot(contains('toothbrush')));
      expect(renamed.toUpdateJson()['titleLower'], 'copper bottle');
    });
  });

  group('write payloads match the exact key sets in firestore.rules', () {
    test('create carries no timestamps — the service supplies those', () {
      final json = saved().toCreateJson();

      expect(json.containsKey('createdAt'), isFalse);
      expect(json.containsKey('updatedAt'), isFalse);
    });

    test('create carries exactly the allowed keys', () {
      expect(
        saved().toCreateJson().keys.toSet(),
        {
          'sellerId',
          'shopName',
          'title',
          'titleLower',
          'searchTokens',
          'description',
          'category',
          'tags',
          'price',
          'stock',
          'imageUrls',
          'active',
        },
      );
    });

    test('update omits sellerId, which the rules pin as unchangeable', () {
      expect(saved().toUpdateJson().containsKey('sellerId'), isFalse);
    });

    test('neither payload can carry the server-owned suspension flag', () {
      expect(saved().toCreateJson().containsKey('hiddenBySuspension'), isFalse);
      expect(saved().toUpdateJson().containsKey('hiddenBySuspension'), isFalse);
    });
  });

  group('fromMap fails toward unsaleable', () {
    test('an empty document parses to something nobody can buy', () {
      final product = ProductModel.fromMap(null, id: 'p');

      expect(product.active, isFalse);
      expect(product.isPurchasable, isFalse);
      expect(product.price, 0);
      expect(product.stock, 0);
    });

    test('an unknown category falls back to other rather than throwing', () {
      final product = ProductModel.fromMap(
        {'category': 'groceries', 'active': true},
        id: 'p',
      );

      expect(product.category, ProductCategory.other);
    });

    test('a missing active flag reads as not listed', () {
      final product = ProductModel.fromMap({'title': 'X'}, id: 'p');
      expect(product.active, isFalse);
    });

    test('tolerates a numeric price arriving as a double or a string', () {
      expect(ProductModel.fromMap({'price': 250.0}, id: 'p').price, 250);
      expect(ProductModel.fromMap({'price': '250'}, id: 'p').price, 250);
    });

    test('ignores non-string entries in the list fields', () {
      final product = ProductModel.fromMap(
        {'tags': ['ok', 7, null], 'imageUrls': ['url', 3]},
        id: 'p',
      );

      expect(product.tags, ['ok']);
      expect(product.imageUrls, ['url']);
    });

    test('round-trips a document the model itself wrote', () {
      final original = saved();
      final parsed = ProductModel.fromMap(original.toCreateJson(), id: 'p1');

      expect(parsed.title, original.title);
      expect(parsed.price, original.price);
      expect(parsed.category, original.category);
      expect(parsed.tags, original.tags);
      expect(parsed.searchTokens, original.searchTokens);
    });
  });

  group('purchasability', () {
    test('an inactive listing is never purchasable', () {
      expect(saved(active: false).isPurchasable, isFalse);
    });

    test('zero stock is out of stock, not delisted', () {
      final product = saved(stock: 0);

      expect(product.isPurchasable, isFalse);
      expect(product.isOutOfStock, isTrue);
    });

    test('a delisted product does not also report as out of stock', () {
      expect(saved(stock: 0, active: false).isOutOfStock, isFalse);
    });
  });

  group('validate mirrors the bounds the rules enforce', () {
    test('accepts a well-formed listing', () {
      expect(saved().validate(), isEmpty);
    });

    test('rejects a title that is too short', () {
      expect(saved(title: 'A').validate(), isNotEmpty);
    });

    test('rejects a description that is too short', () {
      expect(saved(description: 'short').validate(), isNotEmpty);
    });

    test('rejects a price of zero and a negative price', () {
      expect(saved(price: 0).validate(), isNotEmpty);
      expect(saved(price: -5).validate(), isNotEmpty);
    });

    test('accepts zero stock — sold out is valid, just not purchasable', () {
      expect(saved(stock: 0).validate(), isEmpty);
    });

    test('rejects negative stock', () {
      expect(saved(stock: -1).validate(), isNotEmpty);
    });
  });
}
