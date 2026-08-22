/// Chokro — a marketplace listing (F4.1).
///
/// Plain Dart, no Firebase imports (§5.1). The service layer converts
/// `Timestamp` to `DateTime` on the way in, so this file stays emulator-free.
///
/// ## Where this sits on the trust boundary
///
/// A product is one of the few documents a client writes and means it. That is
/// deliberate and it is not a hole: a price is the seller's own number, and
/// `firestore.rules` *can* express who may set it — the owning seller, holding
/// the seller role, on their own document, within bounded types. Compare a
/// wallet balance, where the rule that matters is "only after a photograph was
/// screened", which rules cannot check and which is therefore enforced on the
/// server. The test is always whether the constraint is expressible where it is
/// enforced.
///
/// What a seller writing their own listing still cannot do: reach another
/// seller's product, set `hiddenBySuspension`, or make a listing worth points.
/// Nothing in this document is read by the award path. The one number here that
/// touches the ledger is `price`, and it is read *by the server* at checkout
/// from the stored document — never from the buyer's request.
library;

import '../core/product_taxonomy.dart';

/// One listing.
class ProductModel {
  const ProductModel({
    this.id,
    required this.sellerId,
    required this.shopName,
    required this.title,
    required this.description,
    required this.category,
    required this.price,
    required this.stock,
    this.tags = const <String>[],
    this.imageUrls = const <String>[],
    this.active = true,
    this.hiddenBySuspension = false,
    this.searchTokens = const <String>[],
    this.createdAt,
    this.updatedAt,
  });

  /// Firestore document id. Null before the document is written.
  final String? id;

  final String sellerId;

  /// The seller's own shop name, denormalised so the catalogue can name a vendor.
  ///
  /// **Self-declared, and displayed as such.** `users` is readable only by its
  /// owner and by an administrator (§6.3), so a buyer cannot resolve a seller's
  /// real name — and widening that read to serve a label would expose every
  /// account's email to every signed-in user, which is a far worse trade. Rules
  /// bound the length and nothing else, so this is a shop sign, not an identity
  /// claim, and the interface says "Shop" rather than implying verification. An
  /// order carries `sellerName` resolved by the server instead, because there the
  /// counterparty's identity actually matters.
  final String shopName;

  final String title;
  final String description;
  final ProductCategory category;

  /// Whole taka. See [ProductLimits.priceMin].
  final int price;

  final int stock;

  /// Normalised, de-duplicated, sorted. At most [ProductLimits.maxTags].
  final List<String> tags;

  /// At most [ProductLimits.maxImages], each in this seller's own upload folder
  /// — enforced by an indexed provenance check in `firestore.rules`.
  final List<String> imageUrls;

  /// F4.1's "delete" sets this false. Products are never hard-deleted (§6.2):
  /// past orders snapshot a title and a price, but they also carry a
  /// `productId`, and a dangling reference breaks a buyer's receipt.
  final bool active;

  /// SERVER-WRITTEN ONLY. True when this listing was hidden by its seller's
  /// suspension rather than by the seller's own choice (§7.4).
  ///
  /// The distinction is what makes reinstatement correct: without it, restoring
  /// a suspended seller would republish listings they had deliberately taken
  /// down. Rules keep it out of every client-affected key set.
  final bool hiddenBySuspension;

  /// The `array-contains` index for keyword search (F4.2). Recomputed on every
  /// save by [ProductModel.forSave] — never accepted from a form.
  final List<String> searchTokens;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Whether a buyer can currently order this.
  bool get isPurchasable => active && stock > 0;

  bool get isOutOfStock => active && stock <= 0;

  String? get primaryImageUrl => imageUrls.isEmpty ? null : imageUrls.first;

  /// Builds a listing with its derived fields computed rather than supplied.
  ///
  /// `titleLower` and `searchTokens` are derived from the title, the tags and
  /// the category, and there is no path that lets a form set them directly. That
  /// is what keeps the index honest about the product it indexes — and
  /// `firestore.rules` checks `titleLower == title.lower()` independently, so a
  /// caller that bypassed this constructor would be refused at the boundary.
  factory ProductModel.forSave({
    String? id,
    required String sellerId,
    required String shopName,
    required String title,
    required String description,
    required ProductCategory category,
    required int price,
    required int stock,
    Iterable<String> tags = const <String>[],
    List<String> imageUrls = const <String>[],
    bool active = true,
    bool hiddenBySuspension = false,
    DateTime? createdAt,
  }) {
    final cleanTitle = title.trim();
    final cleanTags = normalizeTags(tags);
    return ProductModel(
      id: id,
      sellerId: sellerId,
      shopName: shopName.trim(),
      title: cleanTitle,
      description: description.trim(),
      category: category,
      price: price,
      stock: stock,
      tags: cleanTags,
      imageUrls: imageUrls.take(ProductLimits.maxImages).toList(),
      active: active,
      hiddenBySuspension: hiddenBySuspension,
      searchTokens: searchTokensFor(
        title: cleanTitle,
        category: category,
        tags: cleanTags,
      ),
      createdAt: createdAt,
    );
  }

  /// Reads a stored listing, tolerating every field being absent or the wrong
  /// type.
  ///
  /// Forgiving for the same reason [UserModel.fromMap] is: this factory sits
  /// under the catalogue stream, and one bad document must degrade to one bad
  /// card rather than an error state over the whole shop. Every fallback is the
  /// unsaleable one — no title, price zero, no stock, inactive — so a product
  /// that cannot be parsed cannot be bought either.
  factory ProductModel.fromMap(Map<String, dynamic>? raw, {String? id}) {
    final data = raw ?? const <String, dynamic>{};

    return ProductModel(
      id: id,
      sellerId: _string(data['sellerId']),
      shopName: _string(data['shopName']),
      title: _string(data['title']),
      description: _string(data['description']),
      category:
          ProductCategory.fromName(_nullableString(data['category'])) ??
          ProductCategory.other,
      price: _int(data['price']),
      stock: _int(data['stock']),
      tags: _stringList(data['tags']),
      imageUrls: _stringList(data['imageUrls']),
      // Absent means not listed. Failing closed here means a document written
      // by something that did not know about this field is invisible rather
      // than for sale.
      active: data['active'] == true,
      hiddenBySuspension: data['hiddenBySuspension'] == true,
      searchTokens: _stringList(data['searchTokens']),
      createdAt: _date(data['createdAt']),
      updatedAt: _date(data['updatedAt']),
    );
  }

  /// The exact key set `firestore.rules` allows a seller to create.
  ///
  /// `createdAt` and `updatedAt` are omitted here and supplied by the service as
  /// `FieldValue.serverTimestamp()`, exactly as [UserModel.toFirestore] omits
  /// its own — the rules require both keys to equal `request.time`, so a device
  /// clock is refused outright (§6.2).
  Map<String, dynamic> toCreateJson() => <String, dynamic>{
    'sellerId': sellerId,
    'shopName': shopName,
    'title': title,
    'titleLower': titleLowerFor(title),
    'searchTokens': searchTokens,
    'description': description,
    'category': category.name,
    'tags': tags,
    'price': price,
    'stock': stock,
    'imageUrls': imageUrls,
    'active': active,
  };

  /// The keys a seller may change on an existing listing.
  ///
  /// `sellerId` is absent and must stay absent: rules pin the affected key set,
  /// so including it — even set to the same value — is not a no-op, it is a
  /// permission denial. `hiddenBySuspension` is absent for the same reason and a
  /// stronger one: it is the server's field.
  Map<String, dynamic> toUpdateJson() => <String, dynamic>{
    'shopName': shopName,
    'title': title,
    'titleLower': titleLowerFor(title),
    'searchTokens': searchTokens,
    'description': description,
    'category': category.name,
    'tags': tags,
    'price': price,
    'stock': stock,
    'imageUrls': imageUrls,
    'active': active,
  };

  ProductModel copyWith({
    String? shopName,
    String? title,
    String? description,
    ProductCategory? category,
    int? price,
    int? stock,
    List<String>? tags,
    List<String>? imageUrls,
    bool? active,
  }) => ProductModel.forSave(
    id: id,
    sellerId: sellerId,
    shopName: shopName ?? this.shopName,
    title: title ?? this.title,
    description: description ?? this.description,
    category: category ?? this.category,
    price: price ?? this.price,
    stock: stock ?? this.stock,
    tags: tags ?? this.tags,
    imageUrls: imageUrls ?? this.imageUrls,
    active: active ?? this.active,
    hiddenBySuspension: hiddenBySuspension,
    createdAt: createdAt,
  );

  /// Problems that would make this listing invalid, in the words a seller needs.
  ///
  /// The same bounds `firestore.rules` enforces. Checked here so the form can
  /// say what is wrong before a round trip that would come back as an
  /// undiagnosable `permission-denied` — rules give no reason, by design.
  List<String> validate() {
    final problems = <String>[];

    if (title.trim().length < ProductLimits.titleMin) {
      problems.add(
        'Give the product a title of at least '
        '${ProductLimits.titleMin} characters.',
      );
    }
    if (title.trim().length > ProductLimits.titleMax) {
      problems.add(
        'Titles are limited to ${ProductLimits.titleMax} characters.',
      );
    }
    if (shopName.trim().length < 2) {
      problems.add('Enter the shop name Champions will see.');
    }
    if (description.trim().length < ProductLimits.descriptionMin) {
      problems.add(
        'Describe the product in at least '
        '${ProductLimits.descriptionMin} characters.',
      );
    }
    if (description.trim().length > ProductLimits.descriptionMax) {
      problems.add(
        'Descriptions are limited to ${ProductLimits.descriptionMax} characters.',
      );
    }
    if (price < ProductLimits.priceMin || price > ProductLimits.priceMax) {
      problems.add(
        'Price must be between ${ProductLimits.priceMin} and '
        '${ProductLimits.priceMax} taka, in whole taka.',
      );
    }
    if (stock < ProductLimits.stockMin || stock > ProductLimits.stockMax) {
      problems.add(
        'Stock must be between ${ProductLimits.stockMin} and '
        '${ProductLimits.stockMax}.',
      );
    }
    if (tags.length > ProductLimits.maxTags) {
      problems.add('At most ${ProductLimits.maxTags} tags.');
    }
    if (imageUrls.length > ProductLimits.maxImages) {
      problems.add('At most ${ProductLimits.maxImages} photos.');
    }
    if (searchTokens.length > ProductLimits.maxSearchTokens) {
      problems.add('That title and those tags produce too many search terms.');
    }

    return problems;
  }

  bool get isValid => validate().isEmpty;

  @override
  String toString() => 'ProductModel($id, $title, $price, stock $stock)';
}

String _string(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;

int _int(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

String? _nullableString(Object? value) => value is String ? value : null;

List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  return value.whereType<String>().toList();
}

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
