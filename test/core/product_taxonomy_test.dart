import 'package:chokro/core/product_taxonomy.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pattern `validTag` and `validSearchToken` apply in `firestore.rules`.
/// Copied verbatim, because a value this side produces that the rules refuse
/// fails the entire product write with an unattributable permission-denied.
const String rulesTagPattern = r'^[a-z0-9]+(-[a-z0-9]+)*$';

void main() {
  group('normalizeTag', () {
    test('lowercases, trims and hyphenates inner whitespace', () {
      expect(normalizeTag('  Eco Friendly  '), 'eco-friendly');
    });

    test('strips punctuation rather than keeping it in the key', () {
      expect(normalizeTag('Eco-Friendly!'), 'eco-friendly');
      expect(normalizeTag('100% cotton'), '100-cotton');
    });

    test('collapses runs of dashes and never leaves an edge dash', () {
      expect(normalizeTag('--eco -- friendly--'), 'eco-friendly');
    });

    test('returns empty for a tag with nothing indexable in it', () {
      expect(normalizeTag('!!!'), isEmpty);
      expect(normalizeTag('   '), isEmpty);
    });

    test('caps length so one tag cannot spend the document', () {
      expect(normalizeTag('a' * 200).length, 40);
    });

    test('truncation never leaves the trailing dash rules refuse', () {
      // 9 + 1 + 9 + 1 + 9 + 1 + 9 = 39 characters, so the cut at 40 lands
      // exactly on the separator before the last word. Before this was fixed
      // the result was `handmades-recycleds-shoppings-luggagess-`, which fails
      // `validTag` in firestore.rules and took the whole product write down
      // with a bare permission-denied.
      const raw = 'handmades recycleds shoppings luggagess carrier';
      final tag = normalizeTag(raw);

      expect(tag, 'handmades-recycleds-shoppings-luggagess');
      expect(tag, matches(rulesTagPattern));
      expect(tag.length, lessThanOrEqualTo(40));
    });
  });

  group('normalizeTags', () {
    test('de-duplicates values that normalise to the same key', () {
      expect(normalizeTags(['Eco Friendly', 'eco-friendly', 'ECO  FRIENDLY']), [
        'eco-friendly',
      ]);
    });

    test('drops tags that normalise to nothing', () {
      expect(normalizeTags(['handmade', '###', '']), ['handmade']);
    });

    test('sorts, so the same set typed in any order stores identically', () {
      expect(
        normalizeTags(['zero', 'alpha']),
        normalizeTags(['alpha', 'zero']),
      );
    });

    test('caps at the documented maximum', () {
      final many = List.generate(20, (i) => 'tag$i');
      expect(normalizeTags(many).length, ProductLimits.maxTags);
    });
  });

  group('searchTokensFor', () {
    test('indexes the title words, the tags and the category', () {
      final tokens = searchTokensFor(
        title: 'Bamboo Toothbrush',
        category: ProductCategory.personalCare,
        tags: ['Eco Friendly'],
      );

      expect(tokens, contains('bamboo'));
      expect(tokens, contains('toothbrush'));
      expect(tokens, contains('eco-friendly'));
      expect(tokens, contains('personalcare'));
    });

    test('indexes the parts of a hyphenated tag as well as the whole', () {
      final tokens = searchTokensFor(
        title: 'Jute bag',
        category: ProductCategory.fashion,
        tags: ['eco friendly'],
      );

      expect(tokens, containsAll(['eco', 'friendly', 'eco-friendly']));
    });

    test('drops words shorter than the minimum, which match everything', () {
      final tokens = searchTokensFor(
        title: 'A Set of 3 Jars',
        category: ProductCategory.homeAndLiving,
      );

      expect(tokens, isNot(contains('a')));
      expect(tokens, containsAll(['set', 'of', 'jars']));
    });

    test('is sorted and free of duplicates', () {
      final tokens = searchTokensFor(
        title: 'Jute Jute JUTE bag',
        category: ProductCategory.fashion,
        tags: ['jute'],
      );

      final sorted = [...tokens]..sort();
      expect(tokens, sorted);
      expect(tokens.toSet().length, tokens.length);
    });

    test('never exceeds the array bound the rules enforce', () {
      final tokens = searchTokensFor(
        title: List.generate(40, (i) => 'word$i').join(' '),
        category: ProductCategory.other,
        tags: List.generate(8, (i) => 'tag-number-$i'),
      );

      expect(tokens.length, lessThanOrEqualTo(ProductLimits.maxSearchTokens));
    });

    test('every token satisfies the pattern the rules check it against', () {
      // `validSearchToken` in firestore.rules is `validString(v, 2, 40)` plus
      // this pattern, and one bad entry refuses the whole product document.
      final tokens = searchTokensFor(
        title: 'Handmade Jute Bag',
        category: ProductCategory.fashion,
        tags: const [
          'handmades recycleds shoppings luggagess carrier',
          '100% Cotton!',
          '--eco -- friendly--',
        ],
      );

      expect(tokens, isNotEmpty);
      for (final token in tokens) {
        expect(token, matches(rulesTagPattern), reason: 'token "$token"');
        expect(token.length, inInclusiveRange(2, 40), reason: 'token "$token"');
      }
    });
  });

  group('tokenizeQuery', () {
    test('agrees with the indexing side on the same words', () {
      final indexed = searchTokensFor(
        title: 'Bamboo Toothbrush',
        category: ProductCategory.personalCare,
      );

      for (final token in tokenizeQuery('bamboo TOOTHBRUSH')) {
        expect(
          indexed,
          contains(token),
          reason: 'a query token must be findable in the index',
        );
      }
    });

    test('is empty for a blank or too-short query', () {
      expect(tokenizeQuery('   '), isEmpty);
      expect(tokenizeQuery('a'), isEmpty);
    });
  });

  group('ProductCategory', () {
    test('parses its own stored names and rejects anything else', () {
      for (final category in ProductCategory.values) {
        expect(ProductCategory.fromName(category.name), category);
      }
      expect(ProductCategory.fromName('groceries'), isNull);
      expect(ProductCategory.fromName(null), isNull);
    });
  });

  group('titleLowerFor', () {
    test('matches what the rules compute with title.lower()', () {
      expect(titleLowerFor('  Bamboo Toothbrush '), 'bamboo toothbrush');
    });
  });
}
