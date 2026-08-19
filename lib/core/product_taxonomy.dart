/// Chokro — the marketplace's fixed vocabulary and its search index (F4.1, F4.2).
///
/// Plain Dart, no Firebase imports (§5.1), so every rule below is unit-testable
/// without an emulator. The server has no mirror of this file and does not need
/// one: nothing here decides a payout. Tokens and tags are a *findability*
/// concern, and the worst a malformed one can do is fail to match a search.
///
/// ## Why a closed category list
///
/// Free-text categories collapse into "Home", "home", "HOME " and "Home & Decor"
/// within a dozen products, and then the filter is useless. The same argument
/// already fixed `itemType` on a disposal and `actionType` on a claim, and it is
/// enforced the same way: `firestore.rules` checks membership of this list, so a
/// product with an invented category cannot be written at all.
///
/// ## Why search tokens exist
///
/// Firestore has no full-text search (§6.3). A query is `array-contains` against
/// a token array computed at save time, which means the index is only as good as
/// [searchTokensFor] — and that it can be tested directly, which a hosted search
/// service could not be.
library;

/// The catalogue's category vocabulary. Closed, and ordered as it is displayed.
enum ProductCategory {
  homeAndLiving,
  personalCare,
  foodAndDrink,
  fashion,
  stationery,
  gardening,
  electronics,
  other;

  /// Parses a stored value. Returns null for anything unrecognised so a caller
  /// can decide — the model falls back to [other], the filter drops it.
  static ProductCategory? fromName(String? name) {
    for (final category in ProductCategory.values) {
      if (category.name == name) return category;
    }
    return null;
  }

  String get label {
    switch (this) {
      case ProductCategory.homeAndLiving:
        return 'Home and living';
      case ProductCategory.personalCare:
        return 'Personal care';
      case ProductCategory.foodAndDrink:
        return 'Food and drink';
      case ProductCategory.fashion:
        return 'Fashion';
      case ProductCategory.stationery:
        return 'Stationery';
      case ProductCategory.gardening:
        return 'Gardening';
      case ProductCategory.electronics:
        return 'Electronics';
      case ProductCategory.other:
        return 'Other';
    }
  }
}

/// Bounds, duplicated in `firestore.rules` because rules cannot import.
///
/// Any change here must be made there too, and `rules_test/market.rules.test.js`
/// is what catches it if it is not.
class ProductLimits {
  const ProductLimits._();

  static const int titleMin = 2;
  static const int titleMax = 120;
  static const int descriptionMin = 10;
  static const int descriptionMax = 2000;

  /// Whole taka. The points economy is integer arithmetic throughout (§7.3), so
  /// a price with paisa in it would produce a discount that does not reconcile.
  static const int priceMin = 1;
  static const int priceMax = 1000000;

  static const int stockMin = 0;
  static const int stockMax = 100000;

  static const int maxTags = 8;
  static const int maxSearchTokens = 30;

  /// Three, and the number is load-bearing rather than aesthetic.
  ///
  /// `firestore.rules` cannot iterate a list, so each image URL is validated by
  /// an explicit indexed check — `imageUrls[0]`, `[1]`, `[2]`. An unbounded list
  /// would mean unvalidated entries, and an unvalidated entry is somewhere a
  /// seller could park an arbitrary URL that every buyer's device then fetches.
  static const int maxImages = 3;

  /// The shortest word worth indexing. "a", "of" and "in" match everything and
  /// so distinguish nothing, and they would spend the token budget.
  static const int minTokenLength = 2;
}

/// Normalises one tag to its stored form.
///
/// Lowercase, trimmed, inner whitespace joined with `-`, and everything that is
/// not a letter, digit or `-` removed. `" Eco Friendly! "` becomes
/// `eco-friendly`. Returns an empty string for a tag that normalises to nothing,
/// which [normalizeTags] then drops.
String normalizeTag(String raw) {
  final collapsed = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
  final cleaned = collapsed
      .replaceAll(RegExp(r'[^a-z0-9-]'), '')
      .replaceAll(RegExp(r'-+'), '-');
  // A leading or trailing dash is an artefact of stripping, never intent.
  final trimmed = cleaned.replaceAll(RegExp(r'^-+|-+$'), '');
  return trimmed.length > 40 ? trimmed.substring(0, 40) : trimmed;
}

/// Normalises, de-duplicates and caps a tag list.
///
/// Sorted, so two sellers who typed the same tags in different orders produce
/// byte-identical documents and a diff of a product edit shows only what changed.
List<String> normalizeTags(Iterable<String> raw) {
  final seen = <String>{};
  for (final tag in raw) {
    final normalized = normalizeTag(tag);
    if (normalized.isEmpty) continue;
    seen.add(normalized);
    if (seen.length >= ProductLimits.maxTags) break;
  }
  final tags = seen.toList()..sort();
  return tags;
}

/// The token array a product is indexed under (F4.2).
///
/// Built from the title, the normalised tags and the category, because those are
/// the three things a buyer types. The description is deliberately excluded: it
/// is long, it is mostly connective words, and including it would exhaust
/// [ProductLimits.maxSearchTokens] on prose while pushing the title out.
///
/// **Whole words only.** `array-contains` is an equality test, so searching
/// "bot" does not match "bottle". Prefix tokens would fix that at the cost of a
/// token per character per word, which does not fit in a bounded array. The
/// catalogue holds tens of products (§6.3), so the search box matches whole
/// words and the category filter does the rest — stated as a limitation rather
/// than papered over.
List<String> searchTokensFor({
  required String title,
  required ProductCategory category,
  Iterable<String> tags = const <String>[],
}) {
  final tokens = <String>{};

  void add(String candidate) {
    if (tokens.length >= ProductLimits.maxSearchTokens) return;
    if (candidate.length < ProductLimits.minTokenLength) return;
    tokens.add(candidate);
  }

  for (final word in tokenizeQuery(title)) {
    add(word);
  }
  for (final tag in normalizeTags(tags)) {
    // A tag may be hyphenated; index both the whole tag and its parts, so
    // `eco-friendly` is found by "eco" as well as by the tag itself.
    add(tag);
    for (final part in tag.split('-')) {
      add(part);
    }
  }
  add(category.name.toLowerCase());

  final list = tokens.toList()..sort();
  return list;
}

/// Splits a buyer's search box into the tokens to query with.
///
/// The same normalisation as the indexing side, which is the only way the two
/// can agree. Punctuation is dropped rather than treated as a separator only
/// where it joins letters — `2-in-1` yields `2`, `in`, `1`, and also `2-in-1`
/// would not, because the index stores hyphenated tags whole. That asymmetry is
/// why [searchTokensFor] indexes both forms.
List<String> tokenizeQuery(String raw) {
  final lowered = raw.trim().toLowerCase();
  if (lowered.isEmpty) return const <String>[];

  final words = lowered
      .split(RegExp(r'[^a-z0-9]+'))
      .where((word) => word.length >= ProductLimits.minTokenLength)
      .toSet()
      .toList();
  words.sort();
  return words;
}

/// The lowercase form stored as `titleLower`.
///
/// A separate field rather than something computed at read time because
/// `firestore.rules` checks `titleLower == title.lower()`, which is what stops a
/// seller storing a title that sorts or matches differently from the one buyers
/// see.
String titleLowerFor(String title) => title.trim().toLowerCase();
