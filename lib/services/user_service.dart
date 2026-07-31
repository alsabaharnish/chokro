import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart';
import '../models/wallet_model.dart';
import '../models/seller_application_model.dart';
import '../core/constants.dart';

class UserService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ── registration ──────────────────────────────────────────────────────────

  /// Creates user doc + wallet doc atomically at registration.
  Future<void> createUserWithWallet(UserModel user) async {
    final batch = _db.batch();

    batch.set(
      _db.collection('users').doc(user.uid),
      user.toFirestore(),
    );

    batch.set(
      _db.collection('wallets').doc(user.uid),
      WalletModel(
        userId: user.uid,
        balance: 0,
        updatedAt: DateTime.now(),
      ).toFirestore(),
    );

    await batch.commit();
  }

  // ── user reads ────────────────────────────────────────────────────────────

  Future<UserModel?> getUser(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return UserModel.fromFirestore(doc);
  }

  Stream<UserModel?> watchUser(String uid) =>
      _db.collection('users').doc(uid).snapshots().map(
            (doc) => doc.exists ? UserModel.fromFirestore(doc) : null,
          );

  // ── admin: user list ──────────────────────────────────────────────────────

  Stream<List<UserModel>> watchAllUsers() =>
      _db.collection('users').snapshots().map(
            (snap) => snap.docs.map(UserModel.fromFirestore).toList(),
          );

  Future<void> updateUserRole(String uid, String role) =>
      _db.collection('users').doc(uid).update({'role': role});

  /// Suspends [uid], indefinitely when [until] is null (F5.2, F5.3).
  ///
  /// A timed suspension stores its expiry and nothing further happens. No job
  /// lifts it later — readers resolve the date themselves, in
  /// `UserModel.isActiveAt` and in `isActive()` in the rules.
  ///
  /// LIMITATION: [until] is computed from the administrator's device clock,
  /// because Firestore cannot offset a server timestamp within a single write.
  /// A skewed admin clock produces a skewed expiry. The comparison it is later
  /// checked against is server-side (`request.time`), so this affects how long
  /// a suspension lasts — never whether the suspended user can shorten it.
  Future<void> suspendUser(String uid, {DateTime? until}) =>
      _db.collection('users').doc(uid).update({
        'status': AppConstants.statusSuspended,
        'suspendedAt': FieldValue.serverTimestamp(),
        'suspendedUntil':
            until == null ? FieldValue.delete() : Timestamp.fromDate(until),
      });

  /// Lifts a suspension and clears any expiry, so a later indefinite
  /// suspension cannot inherit a stale date.
  Future<void> reinstateUser(String uid) =>
      _db.collection('users').doc(uid).update({
        'status': AppConstants.statusActive,
        'reinstatedAt': FieldValue.serverTimestamp(),
        'suspendedUntil': FieldValue.delete(),
      });

  // ── seller applications ───────────────────────────────────────────────────

  Future<void> submitSellerApplication(SellerApplicationModel app) =>
      _db.collection('sellerApplications').add(app.toFirestore());

  Stream<List<SellerApplicationModel>> watchPendingApplications() =>
      _db
          .collection('sellerApplications')
          .where('status', isEqualTo: AppConstants.statusPending)
          .snapshots()
          .map((snap) =>
              snap.docs.map(SellerApplicationModel.fromFirestore).toList());

  Stream<List<SellerApplicationModel>> watchUserApplications(String uid) =>
      _db
          .collection('sellerApplications')
          .where('userId', isEqualTo: uid)
          .snapshots()
          .map((snap) =>
              snap.docs.map(SellerApplicationModel.fromFirestore).toList());

  Future<void> reviewApplication({
    required String appId,
    required String status,
    required String reviewedBy,
    String? reason,
  }) async {
    final batch = _db.batch();

    batch.update(
      _db.collection('sellerApplications').doc(appId),
      {
        'status': status,
        'reviewedBy': reviewedBy,
        'reviewedAt': FieldValue.serverTimestamp(),
        'reason': ?reason,
      },
    );

    if (status == AppConstants.statusApproved) {
      // find the userId from the application first
      final appDoc =
          await _db.collection('sellerApplications').doc(appId).get();
      final userId = appDoc.data()!['userId'] as String;
      batch.update(
        _db.collection('users').doc(userId),
        {'role': AppConstants.roleSeller},
      );
    }

    await batch.commit();
  }

  // ── wallet ────────────────────────────────────────────────────────────────

  Stream<WalletModel?> watchWallet(String uid) =>
      _db.collection('wallets').doc(uid).snapshots().map(
            (doc) => doc.exists ? WalletModel.fromFirestore(doc) : null,
          );
}
