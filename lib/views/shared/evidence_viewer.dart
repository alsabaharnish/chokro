import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Opens [url] full screen, zoomable, at its original resolution.
///
/// ## Why this is shared, and why it matters
///
/// A reviewer decides whether a photograph is genuine evidence. What they can
/// see is therefore the whole basis of the decision, and `core/image_delivery`
/// states the invariant that follows: reviewers open the untransformed
/// original, and only thumbnails are downscaled, because "a thumbnail was never
/// the thing a decision was made on".
///
/// The appeals queue honoured that with a private viewer. The eco-action queue
/// had no viewer at all, so an admin approved or rejected a Champion's claim
/// from a 110 px square and could not enlarge it — and the row of the
/// submitter's previous claims, which exists so a repeated photograph can be
/// spotted, was 58 px. Sharing the viewer is what lets every review surface
/// meet the same standard rather than each screen deciding for itself.
Future<void> showEvidencePhoto(
  BuildContext context, {
  required String url,
  String? caption,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(AppTheme.gapMd),
      child: Stack(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960, maxHeight: 760),
            child: InteractiveViewer(
              minScale: .8,
              maxScale: 5,
              child: CachedNetworkImage(
                // No `thumbnailUrl` and no `memCacheWidth`: this is the one
                // place the full original is the point.
                imageUrl: url,
                fit: BoxFit.contain,
                placeholder: (_, _) => const SizedBox(
                  height: 320,
                  child: Center(child: CircularProgressIndicator()),
                ),
                errorWidget: (_, _, _) => const SizedBox(
                  height: 320,
                  child: Center(
                    child: Icon(Icons.broken_image_outlined, size: 48),
                  ),
                ),
              ),
            ),
          ),
          if (caption != null)
            Positioned(
              left: 8,
              right: 56,
              bottom: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.inverseSurface.withValues(alpha: .82),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.gapMd,
                    vertical: AppTheme.gapSm,
                  ),
                  child: Text(
                    caption,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onInverseSurface,
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            right: 8,
            top: 8,
            child: IconButton.filled(
              tooltip: 'Close photograph',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    ),
  );
}

/// A review thumbnail that opens the original when tapped.
///
/// The tap target carries a tooltip and a semantic label, because an image with
/// neither is invisible to a screen reader and undiscoverable to everyone else.
class EvidenceThumbnail extends StatelessWidget {
  const EvidenceThumbnail({
    super.key,
    required this.url,
    required this.size,
    this.caption,
    this.semanticLabel = 'Evidence photograph',
  });

  final String url;
  final double size;
  final String? caption;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: 'Open the full photograph',
      child: Semantics(
        button: true,
        label: '$semanticLabel — open full size',
        child: InkWell(
          onTap: () => showEvidencePhoto(context, url: url, caption: caption),
          borderRadius: BorderRadius.circular(10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CachedNetworkImage(
              // The original, not a host-side thumbnail: this image is part of
              // a decision, and the reviewer must be able to enlarge what they
              // are looking at rather than a re-encoded copy of it. Only the
              // decode is bounded, which costs the reviewer nothing.
              imageUrl: url,
              memCacheWidth: 1600,
              width: size,
              height: size,
              fit: BoxFit.cover,
              placeholder: (_, _) => Container(
                width: size,
                height: size,
                color: scheme.surfaceContainerHighest,
              ),
              errorWidget: (_, _, _) => Container(
                width: size,
                height: size,
                color: scheme.surfaceContainerHighest,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
