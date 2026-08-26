import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/label_format.dart';
import '../../core/image_delivery.dart';
import '../../core/theme.dart';
import '../../models/product_model.dart';

/// One listing in a list or grid (F4.2).
///
/// Shared by the buyer's catalogue and the seller's own console, which is why it
/// takes [showSellerState]: the seller sees whether a listing is delisted and
/// the buyer never should, because a delisted product is not in their catalogue
/// at all.
class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.product,
    this.onTap,
    this.showSellerState = false,
    this.trailing,
  });

  final ProductModel product;
  final VoidCallback? onTap;

  /// Adds the delisted / out-of-stock state the owning seller needs to see.
  final bool showSellerState;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.gapSm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ProductThumbnail(url: product.primaryImageUrl, size: 76),
              const SizedBox(width: AppTheme.gapMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // "Shop", not "Seller". The name is the seller's own
                      // declaration, bounded by the rules and verified by
                      // nothing — see `ProductModel.shopName`.
                      product.shopName.isEmpty
                          ? product.category.label
                          : '${product.shopName} · ${product.category.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: AppTheme.gapSm),
                    Wrap(
                      spacing: AppTheme.gapSm,
                      runSpacing: AppTheme.gapXs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          formatTaka(product.price),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: scheme.primary,
                          ),
                        ),
                        if (product.isOutOfStock)
                          const _Pill(
                            label: 'Out of stock',
                            tone: _Tone.warning,
                          )
                        else if (showSellerState && !product.active)
                          const _Pill(label: 'Delisted', tone: _Tone.muted)
                        else if (product.stock <= 3)
                          _Pill(
                            label: '${product.stock} left',
                            tone: _Tone.warning,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: AppTheme.gapSm),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A listing image, or a placeholder that does not pretend to be one.
///
/// Images are optional on a listing — the rules allow an empty `imageUrls` —
/// because requiring a photograph would stop a seller listing at all when the
/// upload service is unreachable. A grey box with a category-neutral icon says
/// "no photo" rather than "still loading forever".
class ProductThumbnail extends StatelessWidget {
  const ProductThumbnail({super.key, required this.url, this.size = 76});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final address = url;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      child: SizedBox(
        width: size,
        height: size,
        child: address == null || address.isEmpty
            ? Container(
                color: scheme.surfaceContainerHighest,
                child: Icon(
                  Icons.inventory_2_outlined,
                  color: scheme.onSurfaceVariant,
                  size: size * .38,
                ),
              )
            // Asks the host for a thumbnail rather than the 1600 px
            // original, and caps the decode either way. A twenty-item
            // catalogue was pulling ~8 MB over the wire and putting ~200 MB of
            // decoded bitmaps into the image cache to paint twenty 76 px
            // squares.
            : CachedNetworkImage(
                imageUrl: thumbnailUrl(address, width: size),
                memCacheWidth: decodeWidthFor(size),
                fit: BoxFit.cover,
                placeholder: (context, _) =>
                    Container(color: scheme.surfaceContainerHighest),
                errorWidget: (context, _, _) => Container(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: scheme.onSurfaceVariant,
                    size: size * .38,
                  ),
                ),
              ),
      ),
    );
  }
}

enum _Tone { warning, muted }

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.tone});

  final String label;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (background, foreground) = switch (tone) {
      // `warningContainer`, not `errorContainer`. This tone marks "3 left" and
      // "Out of stock", which are stock facts a shopper should notice, not
      // errors — and the red pill read as though something about the listing
      // had gone wrong. Red is also the shop's only signal for a genuine
      // failure, so spending it here weakened it there.
      _Tone.warning => (scheme.warningContainer, scheme.onWarningContainer),
      _Tone.muted => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
