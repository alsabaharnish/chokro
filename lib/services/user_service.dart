import '../core/network_errors.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart';
import '../models/wallet_model.dart';
import '../models/seller_application_model.dart';
import '../core/constants.dart';

class UserService {
  /// Resolved on use rather than in a field initializer.
  ///
  /// As a `final` field this ran at construction, so `UserService()` threw
  /// unless Firebase had already been initialised — which made the class
  /// impossible to subclass in a unit test even to replace a single method that
  /// never touches Firestore. `FirebaseFirestore.instance` returns the same
  /// object every call, so deferring it costs nothing.
  FirebaseFirestore get _db => FirebaseFirestore.instance;

  // ── registration ──────────────────────────────────────────────────────────

  /// Creates user doc + wallet doc atomically at registration (F1.1).
  ///
  /// Both timestamps come from `FieldValue.serverTimestamp()` rather than the
  /// device, per §6 of the brief. They used to be `DateTime.now()`, which meant
  /// a phone with a skewed clock wrote a join date and a wallet date that the
  /// server never agreed to — and unlike a disposal, nothing downstream ever
  /// re-checks these, so a wrong value would have stayed wrong forever.
  ///
  /// The batch is what makes this safe to run from the client: the rules allow
  /// creating a wallet only at a zero balance, and a user document only for
  /// yourself at role `buyer` and status `active`, so neither half can be abused
  /// and both land together or not at all.
  Future<void> createUserWithWallet(UserModel user) async {
    final batch = _db.batch();

    batch.set(_db.collection('users').doc(user.uid), {
      ...user.toFirestore(),
      'createdAt': FieldValue.serverTimestamp(),
    });

    batch.set(_db.collection('wallets').doc(user.uid), {
      ...WalletModel(userId: user.uid, balance: 0).toFirestore(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    await batch.commit();
  }

  // ── profile management (F1.1) ─────────────────────────────────────────────

  /// Renames the signed-in user's own account.
  ///
  /// The write carries **only** `name`, and that is a hard requirement rather
  /// than tidiness. The rule is:
  ///
  ///     allow update: if isSelf(uid)
  ///       && request.resource.data.diff(resource.data)
  ///            .affectedKeys().hasOnly(['name'])
  ///
  /// `hasOnly` means the diff may contain nothing else. Adding a companion
  /// `updatedAt` — the reflex on a write like this — would make every rename
  /// fail with permission-denied, and the failure would look like a rules
  /// misconfiguration rather than an extra field.
  ///
  /// Role and status are absent for the same reason they are absent from the
  /// rule: a user must not be able to promote or un-suspend themselves.
  Future<void> updateName({required String uid, required String name}) =>
      _db.collection('users').doc(uid).update({'name': name});

  // ── user reads ────────────────────────────────────────────────────────────

  Future<UserModel?> getUser(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return UserModel.fromFirestore(doc);
  }

  /// The signed-in user's profile.
  ///
  /// Throws [ProfileUnavailableException] rather than emitting null when the
  /// document is absent *and the answer came from the cache*. Those two states
  /// are not the same thing and were indistinguishable: an offline user with a
  /// cold cache — a reinstall, cleared storage, a new device — produced a
  /// `doc.exists == false` snapshot that the router read as "registration was
  /// interrupted", routing them to a screen that states as fact that their
  /// profile is missing and suggests registering again. Their profile is fine;
  /// the phone simply has no signal. An error routes to `StartupErrorView`
  /// instead, which says the account service could not be reached and offers a
  /// retry — both true and actionable.
  Stream<UserModel?> watchUser(String uid) =>
      _db.collection('users').doc(uid).snapshots().map((doc) {
        if (doc.exists) return UserModel.fromFirestore(doc);
        if (doc.metadata.isFromCache) {
          throw const ProfileUnavailableException();
        }
        return null;
      });

  // ── admin: user list ──────────────────────────────────────────────────────

  Stream<List<UserModel>> watchAllUsers() => _db
      .collection('users')
      .limit(QueryLimits.accounts)
      .snapshots()
      .map((snap) => snap.docs.map(UserModel.fromFirestore).toList());

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
        'suspendedUntil': until == null
            ? FieldValue.delete()
            : Timestamp.fromDate(until),
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

  /// Files a seller application (F1.2).
  ///
  /// `createdAt` is supplied here with `FieldValue.serverTimestamp()`. The model
  /// used to stamp `Timestamp.fromDate(DateTime.now())` from the device — it was
  /// the last model still doing so — which let a phone with a skewed clock date
  /// its own application, and an administrator sorts the queue by that field.
  Future<void> submitSellerApplication(SellerApplicationModel app) => _db
      .collection('sellerApplications')
      .add({...app.toFirestore(), 'createdAt': FieldValue.serverTimestamp()});

  Stream<List<SellerApplicationModel>> watchPendingApplications() => _db
      .collection('sellerApplications')
      .where('status', isEqualTo: AppConstants.statusPending)
      .limit(QueryLimits.reviewQueue)
      .snapshots()
      .map(
        (snap) => snap.docs.map(SellerApplicationModel.fromFirestore).toList(),
      );

  Stream<List<SellerApplicationModel>> watchUserApplications(String uid) => _db
      .collection('sellerApplications')
      .where('userId', isEqualTo: uid)
      .limit(QueryLimits.ownHistory)
      .snapshots()
      .map(
        (snap) => snap.docs.map(SellerApplicationModel.fromFirestore).toList(),
      );

  Future<void> reviewApplication({
    required String appId,
    required String status,
    required String reviewedBy,
    String? reason,
  }) async {
    final batch = _db.batch();

    batch.update(_db.collection('sellerApplications').doc(appId), {
      'status': status,
      'reviewedBy': reviewedBy,
      'reviewedAt': FieldValue.serverTimestamp(),
      'reason': ?reason,
    });

    if (status == AppConstants.statusApproved) {
      // find the userId from the application first
      final appDoc = await _db
          .collection('sellerApplications')
          .doc(appId)
          .get();

      // Checked rather than force-unwrapped. `appDoc.data()!['userId'] as String`
      // threw a raw type error on a deleted application or a document missing the
      // field, in the middle of a batch that also flips a role — so an
      // administrator pressing Approve got an unhandled exception instead of a
      // message, with no indication whether anything had been written.
      final userId = appDoc.data()?['userId'];
      if (userId is! String || userId.isEmpty) {
        throw StateError(
          'That application no longer names a user, so no role was changed.',
        );
      }

      batch.update(_db.collection('users').doc(userId), {
        'role': AppConstants.roleSeller,
      });
    }

    await batch.commit();
  }

  // ── wallet ────────────────────────────────────────────────────────────────

  Stream<WalletModel?> watchWallet(String uid) => _db
      .collection('wallets')
      .doc(uid)
      .snapshots()
      .map((doc) => doc.exists ? WalletModel.fromFirestore(doc) : null);
}

/// The profile could not be read, as distinct from not existing.
///
/// Raised when Firestore answers from its cache with no document: offline, and
/// this profile has never been cached on this device.
class ProfileUnavailableException implements UserFacingException {
  const ProfileUnavailableException();

  @override
  String get message =>
      'Chokro could not reach the account service. Your profile has not been '
      'changed.';

  @override
  String toString() => message;
}
