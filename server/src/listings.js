/**
 * Chokro — hiding and restoring a suspended seller's listings (§7.4, F5.2).
 *
 * "Suspension hides products from the catalogue but does not delete them, and
 * does not cancel orders in flight."
 *
 * WHY THIS NEEDS THE SERVER AT ALL
 * Suspension itself is a client write: an administrator sets `status` on the
 * user document, and `firestore.rules` can express who may do that, so it stays
 * there (see `AdminUserActions`). Hiding the catalogue is a different shape. The
 * listings belong to the seller, `products` is writable only by its owner, and
 * an administrator has no rule that would let them reach in — nor should one be
 * invented, because "an admin may edit any listing" is a much larger privilege
 * than the one actually needed.
 *
 * The Admin SDK bypasses rules, so the sweep runs here and the ownership rule
 * stays as narrow as it is.
 *
 * WHY A FLAG AND NOT JUST `active: false`
 * A seller may have taken listings down themselves. Restoring everything on
 * reinstatement would republish those, which is not the administrator's decision
 * to make. `hiddenBySuspension` marks the ones this sweep hid, and only those
 * come back. The rules keep it out of every seller-writable key set, so a
 * suspended seller cannot clear their own flag and reappear.
 */

const { db, admin, serverTimestamp } = require('./firebase');

/** Firestore's ceiling on a batched write. */
const BATCH_LIMIT = 400;

/**
 * Hides or restores every listing belonging to [sellerUid].
 *
 * Idempotent in both directions: hiding twice is a no-op, and restoring a seller
 * who was never swept touches nothing. That matters because the administrator's
 * screen calls this straight after a Firestore write it cannot bundle with —
 * two separate operations, so a retry has to be safe.
 *
 * @param {object} args
 * @param {string} args.sellerUid
 * @param {boolean} args.visible  false hides, true restores
 * @returns {Promise<{sellerId: string, visible: boolean, changed: number}>}
 */
async function setSellerListingsVisible({ sellerUid, visible }) {
  if (typeof sellerUid !== 'string' || sellerUid.length === 0) {
    throw new Error('A seller must be named.');
  }

  const firestore = db();

  // Every listing this seller owns, filtered in code rather than by a second
  // equality clause. A seller holds tens of products, and one query with no
  // composite index is easier to reason about than an index that has to be
  // deployed before a suspension can take effect.
  const snapshot = await firestore
    .collection('products')
    .where('sellerId', '==', sellerUid)
    .get();

  const targets = snapshot.docs.filter((doc) => {
    const data = doc.data();
    return visible
      ? data.hiddenBySuspension === true
      : data.active === true && data.hiddenBySuspension !== true;
  });

  if (targets.length === 0) {
    return { sellerId: sellerUid, visible, changed: 0 };
  }

  let changed = 0;
  for (let start = 0; start < targets.length; start += BATCH_LIMIT) {
    const batch = firestore.batch();

    for (const doc of targets.slice(start, start + BATCH_LIMIT)) {
      batch.update(
        doc.ref,
        visible
          ? {
              active: true,
              // Removed rather than set false, so the key exists only while it
              // means something and a seller's own edits never carry it.
              hiddenBySuspension: admin.firestore.FieldValue.delete(),
              updatedAt: serverTimestamp(),
            }
          : {
              active: false,
              hiddenBySuspension: true,
              updatedAt: serverTimestamp(),
            },
      );
      changed += 1;
    }

    await batch.commit();
  }

  return { sellerId: sellerUid, visible, changed };
}

module.exports = { setSellerListingsVisible, BATCH_LIMIT };
