const { uploadAndSaveProfilePhoto } = require('../src/profilePhoto');

function firestore(update) {
  const doc = jest.fn(() => ({ update }));
  const collection = jest.fn(() => ({ doc }));
  return { value: { collection }, collection, doc };
}

describe('trusted profile photo persistence', () => {
  test('uses the authenticated uid for both folder and user document', async () => {
    const upload = jest.fn().mockResolvedValue({
      url: 'https://res.cloudinary.com/demo/image/upload/chokro/profiles/auth_uid/photo.jpg',
      publicId: 'chokro/profiles/auth_uid/photo',
      bytes: 123,
    });
    const update = jest.fn().mockResolvedValue(undefined);
    const store = firestore(update);

    const result = await uploadAndSaveProfilePhoto({
      base64: 'image-bytes',
      uid: 'auth_uid',
      upload,
      remove: jest.fn(),
      firestore: store.value,
    });

    expect(upload).toHaveBeenCalledWith({
      base64: 'image-bytes',
      uid: 'auth_uid',
      kind: 'profiles',
    });
    expect(store.collection).toHaveBeenCalledWith('users');
    expect(store.doc).toHaveBeenCalledWith('auth_uid');
    expect(update).toHaveBeenCalledWith({
      profilePhotoUrl: result.url,
      profilePhotoPublicId: result.publicId,
    });
  });

  test('removes the new public image when Firestore persistence fails', async () => {
    const upload = jest.fn().mockResolvedValue({
      url: 'https://res.cloudinary.com/demo/image/upload/chokro/profiles/auth_uid/photo.jpg',
      publicId: 'chokro/profiles/auth_uid/photo',
    });
    const persistenceError = new Error('Firestore unavailable');
    const update = jest.fn().mockRejectedValue(persistenceError);
    const remove = jest.fn().mockResolvedValue(undefined);

    await expect(
      uploadAndSaveProfilePhoto({
        base64: 'image-bytes',
        uid: 'auth_uid',
        upload,
        remove,
        firestore: firestore(update).value,
      }),
    ).rejects.toBe(persistenceError);

    expect(remove).toHaveBeenCalledWith('chokro/profiles/auth_uid/photo');
  });

  test('keeps the original failure when best-effort cleanup also fails', async () => {
    const persistenceError = new Error('Firestore unavailable');
    const errorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

    await expect(
      uploadAndSaveProfilePhoto({
        base64: 'image-bytes',
        uid: 'auth_uid',
        upload: jest.fn().mockResolvedValue({
          url: 'https://example.test/photo.jpg',
          publicId: 'chokro/profiles/auth_uid/photo',
        }),
        remove: jest.fn().mockRejectedValue(new Error('Cloudinary unavailable')),
        firestore: firestore(jest.fn().mockRejectedValue(persistenceError)).value,
      }),
    ).rejects.toBe(persistenceError);

    expect(errorSpy).toHaveBeenCalledWith(
      'Profile photo cleanup failed:',
      'Cloudinary unavailable',
    );
    errorSpy.mockRestore();
  });
});
