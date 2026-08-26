/// Asking the image host for the size actually being painted.
///
/// ## The cost this removes
///
/// Every photograph in this app is delivered by Cloudinary at whatever
/// resolution it was uploaded at — the compressor in `DisposalDraftController`
/// targets 1600 px on the long edge, and profile pictures and listing photos
/// are comparable. The app then painted them into 40 px avatars, 76 px
/// catalogue thumbnails and 72 px history rows.
///
/// That costs twice, and both costs are ones the user feels:
///
/// 1. **Bytes.** A 1600 px JPEG is on the order of 300-500 KB. Twenty of them
///    is roughly 8 MB pulled over a mobile connection to draw twenty
///    thumbnails, and the shop is the screen a Champion opens most.
/// 2. **Memory.** Flutter decodes to uncompressed RGBA regardless of the box it
///    is drawn into: 1600x1600x4 is **10 MB of RAM per image**. A catalogue
///    page of twenty is ~200 MB of image cache, which on a mid-range Android
///    handset is where the scrolling stutters and the low-memory killer starts
///    looking at the app.
///
/// A Cloudinary delivery URL takes a transformation segment directly after
/// `/image/upload/`, so both costs are removed at the source: the host resizes
/// and re-encodes, and what arrives is a few KB that decodes to a few hundred
/// KB.
///
/// ## Why it is safe for evidence
///
/// The stored `photoUrl` is never rewritten — this only changes what a
/// particular widget *requests*. `isTrustedImageReference` on the server
/// validates the stored URL against the stored `publicId`, and that check runs
/// against the document, not against anything the client renders. Reviewers
/// still open the untransformed original in the full-screen viewer; only
/// thumbnails are downscaled, and a thumbnail was never the thing a decision
/// was made on.
library;

import 'package:flutter/widgets.dart';

/// Host that serves this app's images. Anything else is returned untouched.
const String _cloudinaryHost = 'res.cloudinary.com';

/// A Cloudinary delivery URL for [url] rendered no larger than [width] logical
/// pixels, or [url] unchanged when it is not a Cloudinary delivery URL.
///
/// [width] is in **logical** pixels — the widget's own width. The device pixel
/// ratio is applied here so a 3x phone still gets a sharp image, which is the
/// part that is easy to get wrong by hand at each call site.
///
/// `q_auto` lets the host pick a quality that suits the content, and `f_auto`
/// serves WebP or AVIF to clients that accept them, which is most of them.
/// `c_limit` never enlarges: an image already smaller than the box is passed
/// through at its own size rather than upscaled into blur.
String thumbnailUrl(String url, {required double width}) {
  if (url.isEmpty) return url;

  final Uri parsed;
  try {
    parsed = Uri.parse(url);
  } on FormatException {
    return url;
  }

  if (parsed.host != _cloudinaryHost) return url;

  final segments = parsed.pathSegments;
  // `{cloud}/image/upload/...` — anything shorter is not a delivery URL.
  final uploadIndex = segments.indexOf('upload');
  if (uploadIndex < 2 || uploadIndex + 1 >= segments.length) return url;
  if (segments[uploadIndex - 1] != 'image') return url;

  // Already carries a transformation. Adding a second one would either fight
  // the first or silently change what a caller deliberately asked for.
  final next = segments[uploadIndex + 1];
  if (next.contains(',') || _looksLikeTransform(next)) return url;

  final pixels = (width * _devicePixelRatio()).round().clamp(16, 2000);
  final transform = 'c_limit,w_$pixels,q_auto,f_auto';

  final rebuilt = [
    ...segments.sublist(0, uploadIndex + 1),
    transform,
    ...segments.sublist(uploadIndex + 1),
  ];

  return parsed.replace(pathSegments: rebuilt).toString();
}

/// The decode ceiling to hand `CachedNetworkImage.memCacheWidth`.
///
/// Belt and braces with [thumbnailUrl]: a URL this helper declined to rewrite —
/// a non-Cloudinary host, or one that already carries a transformation — still
/// gets a bounded decode, so no single image can put 10 MB into the image cache
/// to fill a 76 px box.
int decodeWidthFor(double width) =>
    (width * _devicePixelRatio()).round().clamp(16, 2000);

/// A single transformation component looks like `w_400` or `c_fill`.
bool _looksLikeTransform(String segment) {
  // A version marker (`v1712345678`) is not a transformation; it is expected
  // between `upload` and the public id and must not suppress the rewrite.
  if (RegExp(r'^v\d+$').hasMatch(segment)) return false;
  return RegExp(r'^[a-z]{1,2}_').hasMatch(segment);
}

/// Overridable in tests, where there is no view to read a ratio from.
@visibleForTesting
double Function()? debugDevicePixelRatioOverride;

double _devicePixelRatio() {
  final override = debugDevicePixelRatioOverride;
  if (override != null) return override();

  // `PlatformDispatcher` rather than a `MediaQuery`, so this stays a pure
  // function callable from anywhere — including from a `const`-heavy widget
  // tree where threading a BuildContext down would be the larger change.
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) return 1;
  final ratio = views.first.devicePixelRatio;
  return ratio <= 0 ? 1 : ratio;
}
