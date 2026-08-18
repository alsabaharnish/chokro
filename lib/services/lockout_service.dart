import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Duplicate-submission lockout, read side (F2.6).
///
/// After an approved disposal the server opens a per-user, per-bin window during
/// which another submission at the same bin is refused. `firestore.rules` is the
/// enforcement:
///
///     function lockoutActive(uid, binId) {
///       return exists(.../lockouts/$(uid + '_' + binId))
///         && get(.../lockouts/$(uid + '_' + binId)).data.expiresAt > request.time;
///     }
///
/// This class exists because that rule is written to be *readable* as well:
///
///     match /lockouts/{lockoutId} {
///       // Readable so the app can say "you can submit at this bin again in 4h"
///       // instead of letting the user photograph a bag for nothing.
///       allow read: if isSignedIn();
///     }
///
/// Nothing in the app ever read it. A locked-out user scanned the code, walked
/// through photographing a bag, waited for a GPS fix, declared a count, and was
/// then refused at submit with a message listing three possible causes — because
/// a rules rejection arrives as bare `permission-denied` and cannot say which
/// condition failed. Reading the window up front turns that into one sentence at
/// the scanner, with the time remaining in it.
///
/// TRUST NOTE. Like the client-side distance check (F2.5), this is feedback only.
/// The rules re-evaluate it against `request.time` on the write, so a device with
/// a wrong clock or a modified client gains nothing by lying here.
class LockoutService {
  LockoutService({this._firestore});

  final FirebaseFirestore? _firestore;

  /// Resolved on use, not in a field initializer — same reason as
  /// `UserService._db`: a `final` field would throw at construction unless
  /// Firebase were already initialised, which makes the class untestable.
  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;

  /// The document ID the server writes, and the rules read.
  ///
  /// `{uid}_{binId}`, composed identically in `server/src/award.js`. A single
  /// document per pair means the window can be opened, read and released without
  /// a query.
  static String lockoutId({required String uid, required String binId}) =>
      '${uid}_$binId';

  /// When this user may next submit at this bin, or null if they may now.
  ///
  /// Returns null for an **expired** document as well as a missing one. Nothing
  /// deletes these on expiry — there is no scheduler in this system, the same
  /// constraint that makes suspension expiry lazy — so a stale document is the
  /// normal resting state and treating its mere existence as a block would lock
  /// a user out of a bin permanently after one submission.
  ///
  /// Never throws. A failed read must not stop someone submitting: the rules
  /// still enforce the window, so the cost of being wrong here is one wasted
  /// walk-through, and the cost of throwing would be a scanner that refuses to
  /// proceed whenever Firestore hiccups.
  Future<DateTime?> activeUntil({
    required String uid,
    required String binId,
  }) async {
    if (uid.isEmpty || binId.isEmpty) return null;

    try {
      final snapshot = await _db
          .collection('lockouts')
          .doc(lockoutId(uid: uid, binId: binId))
          .get();

      if (!snapshot.exists) return null;

      final raw = snapshot.data()?['expiresAt'];
      final expiresAt = raw is Timestamp ? raw.toDate() : null;
      if (expiresAt == null) return null;

      // Compared the same way the rules compare it, against now.
      return expiresAt.isAfter(DateTime.now()) ? expiresAt : null;
    } catch (err) {
      debugPrint('[lockout] Could not read the window: $err');
      return null;
    }
  }
}
