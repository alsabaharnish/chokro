/**
 * Trusted profile-photo persistence.
 *
 * Upload and Firestore update form one logical operation, but Cloudinary and
 * Firestore cannot share a transaction. If the user-document update fails, the
 * new public image is removed best-effort so a retry does not leak an orphan.
 * A successful replacement deliberately retains the old asset: named claims
 * snapshot the portrait that was permitted at submission time and existing
 * photocards must not silently change or break.
 */

const { db } = require('./firebase');
const { uploadImage, deleteImage } = require('./cloudinary');

async function uploadAndSaveProfilePhoto({
  base64,
  uid,
  upload = uploadImage,
  remove = deleteImage,
  firestore = db(),
}) {
  const result = await upload({ base64, uid, kind: 'profiles' });

  try {
    await firestore.collection('users').doc(uid).update({
      profilePhotoUrl: result.url,
      profilePhotoPublicId: result.publicId,
    });
  } catch (error) {
    try {
      await remove(result.publicId);
    } catch (cleanupError) {
      console.error(
        'Profile photo cleanup failed:',
        cleanupError instanceof Error ? cleanupError.message : 'unknown error',
      );
    }
    throw error;
  }

  return result;
}

module.exports = { uploadAndSaveProfilePhoto };
