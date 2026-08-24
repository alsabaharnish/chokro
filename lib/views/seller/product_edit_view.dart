import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/catalog_controller.dart';
import '../../controllers/seller_products_controller.dart';
import '../../core/network_errors.dart';
import '../../core/product_taxonomy.dart';
import '../../core/theme.dart';
import '../../models/product_model.dart';
import '../../services/photo_upload_service.dart';
import '../market/product_card.dart';
import '../shared/content_state.dart';
import '../shared/unsaved_changes.dart';

/// Create or edit a listing (F4.1).
///
/// ## Why the form validates before it writes
///
/// `firestore.rules` refuses a malformed product with `permission-denied` and no
/// reason — that is what rules do, and it is right that they do not explain
/// themselves to a caller. So every bound the rules enforce is mirrored in
/// [ProductModel.validate], and this form runs it before the write. A seller
/// whose description is four characters short is told that, rather than being
/// told they lack permission to sell.
///
/// ## Why images upload immediately and the listing does not
///
/// A photograph has to reach the image host before its URL exists, and the URL
/// is what the rules check against this seller's own folder. So the upload is
/// its own step with its own progress. The listing is written only when the
/// seller saves — which does mean an abandoned form can leave an unreferenced
/// image behind. That is the same trade the disposal flow makes in reverse, and
/// it is the right way round here: a seller composing a listing expects to see
/// the photograph they just picked.
class ProductEditView extends ConsumerStatefulWidget {
  const ProductEditView({super.key, this.productId});

  /// Null when creating.
  final String? productId;

  @override
  ConsumerState<ProductEditView> createState() => _ProductEditViewState();
}

class _ProductEditViewState extends ConsumerState<ProductEditView> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _shopName = TextEditingController();
  final _description = TextEditingController();
  final _price = TextEditingController();
  final _stock = TextEditingController();
  final _tags = TextEditingController();

  ProductCategory _category = ProductCategory.homeAndLiving;
  List<String> _imageUrls = const <String>[];

  bool _seeded = false;
  bool _saving = false;
  bool _uploading = false;

  bool get _isNew => widget.productId == null;

  @override
  void dispose() {
    _title.dispose();
    _shopName.dispose();
    _description.dispose();
    _price.dispose();
    _stock.dispose();
    _tags.dispose();
    super.dispose();
  }

  /// Fills the form from the stored listing, exactly once.
  ///
  /// The product is a live stream, so a second seed would overwrite whatever the
  /// seller had typed the moment any field changed — including the `updatedAt`
  /// their own save had just written.
  void _seed(ProductModel product) {
    if (_seeded) return;
    _seeded = true;
    _title.text = product.title;
    _shopName.text = product.shopName;
    _description.text = product.description;
    _price.text = product.price.toString();
    _stock.text = product.stock.toString();
    _tags.text = product.tags.join(', ');
    _category = product.category;
    _imageUrls = product.imageUrls;
    _pristine = _snapshot();
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.productId;

    if (id == null) {
      // A new listing defaults its shop name to the seller's own name, which is
      // the answer most of them would type anyway.
      if (!_seeded) {
        _seeded = true;
        _shopName.text = ref.read(currentUserProvider).value?.name ?? '';
        _pristine = _snapshot();
      }
      return _scaffold(child: _form());
    }

    final productAsync = ref.watch(productProvider(id));

    return productAsync.when(
      loading: () =>
          _scaffold(child: const ContentLoading(label: 'Loading the listing…')),
      error: (error, _) => _scaffold(
        child: ContentEmpty(
          icon: Icons.cloud_off_outlined,
          title: 'The listing did not load',
          message: 'Check your connection and open it again.',
          actionLabel: 'Back to listings',
          onAction: () => context.pop(),
        ),
      ),
      data: (product) {
        if (product == null) {
          return _scaffold(
            child: ContentEmpty(
              icon: Icons.search_off,
              title: 'No such listing',
              message: 'It may have been removed.',
              actionLabel: 'Back to listings',
              onAction: () => context.pop(),
            ),
          );
        }
        _seed(product);
        return _scaffold(child: _form(existing: product));
      },
    );
  }

  /// Everything the seller could have typed or picked, flattened so the form's
  /// current state can be compared against the state it was seeded with.
  ///
  /// A field-by-field comparison would work too; one string is simply harder to
  /// forget to extend when a field is added.
  String _snapshot() => [
    _title.text,
    _shopName.text,
    _description.text,
    _price.text,
    _stock.text,
    _tags.text,
    _category.name,
    _imageUrls.join('|'),
  ].join('\u0000');

  /// The state the form was opened with — the stored listing, or the defaults
  /// for a new one. Set by [_seed] and by the create branch in [build].
  String? _pristine;

  bool get _hasUnsavedChanges =>
      _pristine != null && _snapshot() != _pristine && !_saving;

  Widget _scaffold({required Widget child}) {
    // `PopScope.canPop` is read when the widget builds, and typing into a
    // `TextEditingController` does not rebuild this State — so without this the
    // guard would still be holding the value it had when the form opened, and
    // would wave the first back gesture straight through. Only the guard is
    // rebuilt on each keystroke: the scaffold below is passed through as
    // `child`, so the same widget instance is reused and the form itself does
    // not rebuild.
    return ListenableBuilder(
      listenable: Listenable.merge([
        _title,
        _shopName,
        _description,
        _price,
        _stock,
        _tags,
      ]),
      builder: (context, scaffold) => UnsavedChangesGuard(
        hasChanges: _hasUnsavedChanges,
        title: 'Discard this listing?',
        message: _isNew
            // Worth naming: a photograph is uploaded the moment it is picked,
            // so an abandoned new listing is not merely lost typing.
            ? 'This listing has not been saved. Any photograph you added stays '
                  'uploaded but will not belong to a listing.'
            : 'Your edits to this listing have not been saved, and leaving now '
                  'loses them.',
        child: scaffold!,
      ),
      child: Scaffold(
        appBar: AppBar(title: Text(_isNew ? 'New listing' : 'Edit listing')),
        body: child,
      ),
    );
  }

  Widget _form({ProductModel? existing}) {
    final theme = Theme.of(context);

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.gapMd,
          AppTheme.gapMd,
          AppTheme.gapMd,
          AppTheme.gap2Xl,
        ),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppTheme.maxContentWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PhotoStrip(
                    urls: _imageUrls,
                    uploading: _uploading,
                    onAdd: _pickPhoto,
                    onRemove: (url) => setState(
                      () => _imageUrls = [..._imageUrls]..remove(url),
                    ),
                  ),

                  const SizedBox(height: AppTheme.gapLg),
                  TextFormField(
                    controller: _title,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      helperText: 'What a Champion searches for',
                    ),
                    maxLength: ProductLimits.titleMax,
                    validator: (value) =>
                        (value ?? '').trim().length < ProductLimits.titleMin
                        ? 'Give the product a name'
                        : null,
                  ),

                  TextFormField(
                    controller: _shopName,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Shop name',
                      helperText: 'Shown on every listing you publish',
                    ),
                    maxLength: 80,
                    validator: (value) => (value ?? '').trim().length < 2
                        ? 'Enter the name Champions will see'
                        : null,
                  ),

                  const SizedBox(height: AppTheme.gapSm),
                  DropdownButtonFormField<ProductCategory>(
                    initialValue: _category,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: [
                      for (final category in ProductCategory.values)
                        DropdownMenuItem(
                          value: category,
                          child: Text(category.label),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => _category = value ?? _category),
                  ),

                  const SizedBox(height: AppTheme.gapMd),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _price,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Price',
                            prefixText: '৳ ',
                            // Whole taka, because the points economy is integer
                            // arithmetic end to end (§7.3).
                            helperText: 'Whole taka',
                          ),
                          validator: _validatePrice,
                        ),
                      ),
                      const SizedBox(width: AppTheme.gapMd),
                      Expanded(
                        child: TextFormField(
                          controller: _stock,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Stock',
                            helperText: 'Zero is allowed',
                          ),
                          validator: _validateStock,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: AppTheme.gapMd),
                  TextFormField(
                    controller: _description,
                    textCapitalization: TextCapitalization.sentences,
                    minLines: 3,
                    maxLines: 8,
                    maxLength: ProductLimits.descriptionMax,
                    decoration: const InputDecoration(
                      labelText: 'Description',
                      alignLabelWithHint: true,
                    ),
                    validator: (value) =>
                        (value ?? '').trim().length <
                            ProductLimits.descriptionMin
                        ? 'Describe the product in at least '
                              '${ProductLimits.descriptionMin} characters'
                        : null,
                  ),

                  TextFormField(
                    controller: _tags,
                    decoration: const InputDecoration(
                      labelText: 'Tags',
                      helperText:
                          'Comma separated. Tidied up and indexed for search — '
                          'at most ${ProductLimits.maxTags}.',
                    ),
                  ),

                  const SizedBox(height: AppTheme.gapLg),
                  Text(
                    'Search matches whole words from the title, the tags and '
                    'the category. There is no full-text search behind this, so '
                    'name the product the way a Champion would look for it.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),

                  const SizedBox(height: AppTheme.gapLg),
                  FilledButton.icon(
                    onPressed: _saving ? null : () => _save(existing),
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(
                      _saving
                          ? 'Saving…'
                          : _isNew
                          ? 'Publish listing'
                          : 'Save changes',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? _validatePrice(String? value) {
    final price = int.tryParse((value ?? '').trim());
    if (price == null) return 'Enter a price in whole taka';
    if (price < ProductLimits.priceMin) return 'Must be at least ৳1';
    if (price > ProductLimits.priceMax) return 'That is above the maximum';
    return null;
  }

  String? _validateStock(String? value) {
    final stock = int.tryParse((value ?? '').trim());
    if (stock == null) return 'Enter how many you have';
    if (stock > ProductLimits.stockMax) return 'That is above the maximum';
    return null;
  }

  Future<void> _pickPhoto() async {
    if (_imageUrls.length >= ProductLimits.maxImages) return;

    final messenger = ScaffoldMessenger.of(context);

    // `image_picker` returns bytes on web as well as on mobile, so nothing here
    // touches `dart:io` and the seller console works on both targets (§5.5).
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 90,
    );
    if (picked == null) return;

    final original = await picked.readAsBytes();

    setState(() => _uploading = true);
    try {
      // Compressed on the same path the disposal and claim flows use.
      //
      // This used to rely on ImagePicker's resize alone, on the stated grounds
      // that `flutter_image_compress` has no web implementation. It does —
      // `flutter_image_compress_web` resolves in `pubspec.lock` and the plugin
      // registers for web — so the premise was simply wrong and a listing
      // photograph went up two to three times larger than it needed to be,
      // carrying whatever EXIF the seller's camera stamped into it.
      //
      // The EXIF half matters more than the bytes: a seller photographing stock
      // at home would otherwise publish their home coordinates to every buyer.
      // Re-encoding strips it (§7.4).
      final bytes = await FlutterImageCompress.compressWithList(
        original,
        quality: 70,
        minWidth: 1080,
        minHeight: 1080,
        keepExif: false,
      );

      if (bytes.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('That photo could not be processed. Try another.'),
          ),
        );
        return;
      }

      final url = await ref
          .read(sellerProductActionsProvider)
          .uploadPhoto(bytes);
      if (!mounted) return;
      setState(() => _imageUrls = [..._imageUrls, url]);
    } on PhotoUploadException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'The photo could not be uploaded. ${friendlyErrorMessage(error)}',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _save(ProductModel? existing) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final uid = ref.read(currentUserProvider).value?.uid;
    if (uid == null) return;

    final draft = ProductModel.forSave(
      id: existing?.id,
      sellerId: uid,
      shopName: _shopName.text,
      title: _title.text,
      description: _description.text,
      category: _category,
      price: int.parse(_price.text.trim()),
      stock: int.parse(_stock.text.trim()),
      tags: _tags.text.split(','),
      imageUrls: _imageUrls,
      // An edit keeps whatever the listing already was; a new one is on sale.
      // Delisting is a separate, named action on the console.
      active: existing?.active ?? true,
      hiddenBySuspension: existing?.hiddenBySuspension ?? false,
      createdAt: existing?.createdAt,
    );

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final actions = ref.read(sellerProductActionsProvider);
      if (existing == null) {
        await actions.create(draft);
      } else {
        await actions.update(existing.id!, draft);
      }

      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            existing == null ? 'Listing published.' : 'Listing saved.',
          ),
        ),
      );
      context.pop();
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(_saveFailureMessage(error))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Turns a rules refusal into something a seller can act on.
  ///
  /// Rules give no reason by design, so `permission-denied` here means one of
  /// two things worth distinguishing: the account is not a seller, or it is
  /// suspended. Both are states the seller can check; "missing or insufficient
  /// permissions" is not.
  String _saveFailureMessage(Object error) {
    final text = error.toString();
    if (text.contains('permission-denied')) {
      return 'The listing was refused. Check that your Greenpreneur profile is '
          'active — a suspended account cannot publish.';
    }
    return 'That did not save. ${friendlyErrorMessage(error)}';
  }
}

class _PhotoStrip extends StatelessWidget {
  const _PhotoStrip({
    required this.urls,
    required this.uploading,
    required this.onAdd,
    required this.onRemove,
  });

  final List<String> urls;
  final bool uploading;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final full = urls.length >= ProductLimits.maxImages;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 110,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final url in urls) ...[
                Stack(
                  children: [
                    ProductThumbnail(url: url, size: 110),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: IconButton(
                        tooltip: 'Remove photo',
                        style: IconButton.styleFrom(
                          backgroundColor: theme.colorScheme.surface,
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () => onRemove(url),
                        icon: const Icon(Icons.close, size: 16),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: AppTheme.gapSm),
              ],
              if (!full)
                SizedBox(
                  width: 110,
                  height: 110,
                  child: OutlinedButton(
                    onPressed: uploading ? null : onAdd,
                    child: uploading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add_a_photo_outlined),
                              SizedBox(height: 4),
                              Text('Add photo'),
                            ],
                          ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppTheme.gapXs),
        Text(
          // The number is not arbitrary: rules cannot iterate a list, so each
          // slot is validated by index and the bound is what makes that possible.
          'Up to ${ProductLimits.maxImages} photos. Optional — a listing '
          'without one still sells.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (kIsWeb)
          Text(
            'On the web build, photos come from a file picker.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        Text(
          'Photos are resized and their location metadata removed before upload.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
