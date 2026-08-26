import 'package:chokro/core/image_delivery.dart';
import 'package:flutter_test/flutter_test.dart';

/// A delivery URL in the shape `server/src/cloudinary.js` writes and
/// `isTrustedImageReference` validates: `{cloud}/image/upload/[v#/]{publicId}`.
String delivery({String version = 'v1712345678', String kind = 'disposals'}) =>
    'https://res.cloudinary.com/demo-cloud/image/upload/'
    '$version/chokro/$kind/uid123/abc123.jpg';

void main() {
  setUp(() => debugDevicePixelRatioOverride = () => 2);
  tearDown(() => debugDevicePixelRatioOverride = null);

  group('thumbnailUrl', () {
    test('inserts the transformation directly after /image/upload/', () {
      final result = thumbnailUrl(delivery(), width: 76);

      expect(
        result,
        'https://res.cloudinary.com/demo-cloud/image/upload/'
        'c_limit,w_152,q_auto,f_auto/'
        'v1712345678/chokro/disposals/uid123/abc123.jpg',
      );
    });

    test('multiplies by the device pixel ratio, so a 3x phone stays sharp', () {
      debugDevicePixelRatioOverride = () => 3;

      expect(thumbnailUrl(delivery(), width: 76), contains('w_228'));
    });

    test('leaves the public id and version untouched', () {
      // The public id is what `isTrustedImageReference` matches the stored URL
      // against. Rewriting the delivered path here must never reach into it.
      final result = thumbnailUrl(delivery(), width: 40);

      expect(result, contains('/v1712345678/chokro/disposals/uid123/abc123.jpg'));
      expect(result, endsWith('abc123.jpg'));
    });

    test('handles a URL with no version segment', () {
      final noVersion =
          'https://res.cloudinary.com/demo-cloud/image/upload/'
          'chokro/profiles/uid123/pic.jpg';

      expect(
        thumbnailUrl(noVersion, width: 40),
        'https://res.cloudinary.com/demo-cloud/image/upload/'
        'c_limit,w_80,q_auto,f_auto/chokro/profiles/uid123/pic.jpg',
      );
    });

    test('passes through a host that is not the image host', () {
      const foreign = 'https://example.com/image/upload/v1/a/b.jpg';

      expect(thumbnailUrl(foreign, width: 76), foreign);
    });

    test('does not stack a second transformation on one already there', () {
      // `server/src/phash.js` builds URLs of exactly this shape. Adding a
      // second transformation would fight the first.
      const already =
          'https://res.cloudinary.com/demo-cloud/image/upload/'
          'c_scale,w_8,h_8,e_grayscale,f_png/chokro/disposals/uid/a.png';

      expect(thumbnailUrl(already, width: 76), already);
    });

    test('an empty or malformed URL is returned rather than thrown on', () {
      expect(thumbnailUrl('', width: 76), '');
      expect(thumbnailUrl('not a url at all', width: 76), 'not a url at all');
      expect(
        thumbnailUrl('https://res.cloudinary.com/demo', width: 76),
        'https://res.cloudinary.com/demo',
      );
    });

    test('clamps so a bad width cannot ask the host for a huge render', () {
      expect(thumbnailUrl(delivery(), width: 0), contains('w_16'));
      expect(thumbnailUrl(delivery(), width: 99999), contains('w_2000'));
    });
  });

  group('decodeWidthFor', () {
    test('is the same pixel figure the URL asks the host for', () {
      expect(decodeWidthFor(76), 152);
      expect(thumbnailUrl(delivery(), width: 76), contains('w_152'));
    });

    test('is clamped the same way', () {
      expect(decodeWidthFor(0), 16);
      expect(decodeWidthFor(99999), 2000);
    });
  });
}
