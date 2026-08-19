const {
  isTrustedImageReference,
  PHOTO_KINDS,
} = require('../src/cloudinary');

describe('trusted Cloudinary references', () => {
  const clean = {
    uid: 'user_123',
    kind: 'disposals',
    cloudName: 'chokro-cloud',
    publicId: 'chokro/disposals/user_123/asset-Ab_12',
    url:
      'https://res.cloudinary.com/chokro-cloud/image/upload/v1720000000/' +
      'chokro/disposals/user_123/asset-Ab_12.jpg',
  };

  test('accepts the original URL returned for this user and purpose', () => {
    expect(isTrustedImageReference(clean)).toBe(true);
  });

  test('accepts every supported folder, and no others', () => {
    // Asserted as an exact list rather than a membership check: the folder name
    // is what `firestore.rules` builds its provenance pattern from, so a folder
    // added here without a matching rule would accept an image the rules then
    // refuse — a listing or a submission that uploads successfully and cannot be
    // saved.
    expect(PHOTO_KINDS).toEqual(['disposals', 'claims', 'products']);

    expect(
      isTrustedImageReference({
        ...clean,
        kind: 'claims',
        publicId: 'chokro/claims/user_123/claim1',
        url:
          'https://res.cloudinary.com/chokro-cloud/image/upload/' +
          'chokro/claims/user_123/claim1.png',
      }),
    ).toBe(true);

    expect(
      isTrustedImageReference({
        ...clean,
        kind: 'products',
        publicId: 'chokro/products/user_123/listing1',
        url:
          'https://res.cloudinary.com/chokro-cloud/image/upload/' +
          'chokro/products/user_123/listing1.jpg',
      }),
    ).toBe(true);
  });

  test('a listing image cannot borrow a disposal photograph folder', () => {
    // The folders are separate so a seller cannot dress evidence up as a
    // product, or point a listing at somebody's disposal photograph.
    expect(
      isTrustedImageReference({
        ...clean,
        kind: 'products',
        publicId: 'chokro/disposals/user_123/asset-Ab_12',
        url: clean.url,
      }),
    ).toBe(false);
  });

  test('rejects another user folder even on the same cloud', () => {
    expect(
      isTrustedImageReference({
        ...clean,
        publicId: 'chokro/disposals/other_user/asset-Ab_12',
      }),
    ).toBe(false);
  });

  test('rejects a URL and public id that do not name the same asset', () => {
    expect(
      isTrustedImageReference({
        ...clean,
        url:
          'https://res.cloudinary.com/chokro-cloud/image/upload/' +
          'chokro/disposals/user_123/different.jpg',
      }),
    ).toBe(false);
  });

  test('rejects another host, insecure transport, and transformed URLs', () => {
    expect(
      isTrustedImageReference({
        ...clean,
        url: clean.url.replace('res.cloudinary.com', 'example.com'),
      }),
    ).toBe(false);
    expect(
      isTrustedImageReference({
        ...clean,
        url: clean.url.replace('https:', 'http:'),
      }),
    ).toBe(false);
    expect(
      isTrustedImageReference({
        ...clean,
        url:
          'https://res.cloudinary.com/chokro-cloud/image/upload/w_100/' +
          'chokro/disposals/user_123/asset-Ab_12.jpg',
      }),
    ).toBe(false);
  });

  test('rejects malformed and unsupported input without throwing', () => {
    expect(isTrustedImageReference({ ...clean, url: 'not a URL' })).toBe(false);
    expect(isTrustedImageReference({ ...clean, cloudName: '' })).toBe(false);
    expect(isTrustedImageReference({ ...clean, kind: 'avatars' })).toBe(false);
    expect(isTrustedImageReference({ ...clean, publicId: '../secret' })).toBe(false);
  });
});
