import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/constants.dart';

/// A platform account.
///
/// ## Suspension and lazy expiry (F5.2, F5.3)
///
/// A suspension can be permanent or temporary. There is no scheduler in this
/// system — Cloud Functions need a billing card and the free Render instance
/// sleeps — so nothing exists that could wake up and lift a suspension when its
/// time is up. A temporary suspension therefore expires *lazily*: the account
/// is suspended for exactly as long as `suspendedUntil` is in the future, and
/// the question is answered whenever someone asks it.
///
/// The same rule is written twice: [isActiveAt] here, and `isActive()` in
/// `firestore.rules`, which compares `suspendedUntil` against `request.time`.
/// The rules version is the one that enforces; this one exists so the interface
/// can tell the user the truth. They must agree, and
/// `rules_test/suspension.rules.test.js` proves the rules half.
///
/// `status` stays `'suspended'` after the expiry passes. Nothing rewrites it,
/// because nothing is running to do so — a lapsed suspension is a suspended
/// status plus a past date, and every reader resolves that for itself.
class UserModel {
  final String uid;
  final String name;
  final String email;
  final String role;
  final String status;

  /// The Champion's current public-facing portrait.
  ///
  /// Both values are stored together. The URL is what Flutter renders; the
  /// public id lets Firestore prove the image belongs to this user's dedicated
  /// Cloudinary folder rather than accepting an arbitrary remote image.
  final String? profilePhotoUrl;
  final String? profilePhotoPublicId;

  /// When the account was opened, as the *server* saw it.
  ///
  /// Nullable, and honestly so. It is written with
  /// `FieldValue.serverTimestamp()`, which Firestore resolves on the server —
  /// so the locally cached snapshot Firestore hands back immediately after
  /// registration carries null here until the round trip completes. That window
  /// is brief, but it is real, and it is on the signup path where every account
  /// passes exactly once.
  final DateTime? createdAt;

  /// When a temporary suspension lapses.
  ///
  /// Null while active, and null for a *permanent* suspension — which is why
  /// null must never be read as "not suspended". Only [isActiveAt] should
  /// interpret this field.
  final DateTime? suspendedUntil;

  /// When the account was last suspended, and last reinstated.
  ///
  /// The server-side rule set has always permitted an administrator to write
  /// these, and `UserService` has always written them — but the model did not
  /// parse them, so the audit trail existed in Firestore and could not be shown
  /// to anybody. An administrator looking at a suspended account could see that
  /// it was suspended and not when, which is most of what an audit field is
  /// for.
  final DateTime? suspendedAt;
  final DateTime? reinstatedAt;

  const UserModel({
    required this.uid,
    required this.name,
    required this.email,
    required this.role,
    required this.status,
    this.profilePhotoUrl,
    this.profilePhotoPublicId,
    this.createdAt,
    this.suspendedUntil,
    this.suspendedAt,
    this.reinstatedAt,
  });

  bool get isAdmin => role == AppConstants.roleAdmin;

  bool get hasProfilePhoto =>
      profilePhotoUrl != null &&
      profilePhotoUrl!.isNotEmpty &&
      profilePhotoPublicId != null &&
      profilePhotoPublicId!.isNotEmpty;

  /// Higher tiers retain the profiles below them: every account is a Champion,
  /// and a 3ZERO Admin can also work as a Greenpreneur.
  bool get isChampion => true;
  bool get isGreenpreneur => role == AppConstants.roleSeller || isAdmin;

  /// Internal compatibility name for marketplace permission checks.
  bool get isSeller => isGreenpreneur;

  /// Whether this account may act, evaluated at [now].
  ///
  /// Pure and clock-injected so it can be unit-tested without waiting. An
  /// unrecognised status is not active — fail closed, the same way an
  /// unrecognised disposal status falls back to `pending`.
  bool isActiveAt(DateTime now) {
    if (status == AppConstants.statusActive) return true;
    if (status != AppConstants.statusSuspended) return false;

    final until = suspendedUntil;
    if (until == null) return false; // permanent
    return now.isAfter(until);
  }

  bool get isActive => isActiveAt(DateTime.now());

  /// Suspended with no end date.
  bool get isSuspendedIndefinitely =>
      status == AppConstants.statusSuspended && suspendedUntil == null;

  /// Suspended now, but with an end date in the future.
  bool get isSuspendedTemporarily =>
      status == AppConstants.statusSuspended &&
      suspendedUntil != null &&
      !isActive;

  /// Status still reads `suspended`, but the date has passed, so the account
  /// is acting normally again. Worth surfacing in the admin list: it explains
  /// why a "suspended" user is submitting.
  bool get hasLapsedSuspension =>
      status == AppConstants.statusSuspended &&
      suspendedUntil != null &&
      isActive;

  /// Reads a user document, tolerating a field that is missing or the wrong
  /// shape.
  ///
  /// Every cast here used to be unchecked — `data['name'] as String`,
  /// `(data['createdAt'] as Timestamp).toDate()`, and the whole payload as a
  /// `Map`. Any one of them throwing takes far more with it than
  /// a single screen, because this factory sits under `watchUser`, which feeds
  /// `currentUserProvider`, which the router's gate reads to decide where the
  /// user is allowed to be. A throw there surfaces as an `AsyncError` with no
  /// value, the gate reads "signed in with no profile", and a perfectly valid
  /// account is redirected to the account-recovery screen — a dead end reached
  /// because one field was the wrong type.
  ///
  /// `createdAt` is the case that actually happens: it is written with
  /// `FieldValue.serverTimestamp()`, so the local echo of the registration write
  /// has it as null for one round trip. The old cast crashed on precisely the
  /// document it had just created.
  ///
  /// A missing role or status falls back to the least privileged value, never a
  /// permissive one: an unreadable account gets buyer rights and an inactive
  /// status, and the rules refuse anything more regardless of what this says.
  factory UserModel.fromFirestore(DocumentSnapshot doc) =>
      UserModel.fromMap(doc.data(), uid: doc.id);

  /// The parsing itself, over a plain map.
  ///
  /// Split out so it can be tested without a `DocumentSnapshot` — that type is
  /// sealed, so faking one means implementing a sealed class, and the analyzer
  /// is right to object. This mirrors [BinModel.fromJson], which the rest of the
  /// codebase already shapes this way.
  factory UserModel.fromMap(Object? raw, {required String uid}) {
    final data = raw is Map<String, dynamic> ? raw : const <String, dynamic>{};

    return UserModel(
      uid: uid,
      name: _string(data['name']),
      email: _string(data['email']),
      // Fail closed. `isAdmin`/`isSeller` compare against these, so guessing
      // upward here would hand out privileges on malformed data.
      role: _string(data['role'], fallback: AppConstants.roleBuyer),
      status: _string(data['status'], fallback: AppConstants.statusSuspended),
      profilePhotoUrl: _nullableString(data['profilePhotoUrl']),
      profilePhotoPublicId: _nullableString(data['profilePhotoPublicId']),
      createdAt: _date(data['createdAt']),
      suspendedUntil: _date(data['suspendedUntil']),
      suspendedAt: _date(data['suspendedAt']),
      reinstatedAt: _date(data['reinstatedAt']),
    );
  }

  /// Field map for a Firestore write.
  ///
  /// Omits `suspendedUntil` when null rather than writing an explicit null.
  /// Registration writes this map, and an absent key is cleaner than a null one
  /// for a field that only an administrator ever sets.
  ///
  /// `createdAt` is deliberately omitted, exactly as [BinModel.toJson] omits
  /// its own: §6 of the brief requires every `createdAt` to be written with
  /// `FieldValue.serverTimestamp()`, and this used to write
  /// `Timestamp.fromDate(DateTime.now())` from the device instead. A phone with
  /// a wrong clock — or one deliberately set back — recorded a join date the
  /// server never agreed to. The service layer supplies it; the rules require
  /// the key to be present on create, and a server timestamp satisfies that.
  Map<String, dynamic> toFirestore() => {
    'name': name,
    'email': email,
    'role': role,
    'status': status,
    if (suspendedUntil != null)
      'suspendedUntil': Timestamp.fromDate(suspendedUntil!),
  };

  /// [clearSuspendedUntil] exists because passing null to [suspendedUntil]
  /// cannot be distinguished from omitting it.
  UserModel copyWith({
    String? name,
    String? role,
    String? status,
    String? profilePhotoUrl,
    String? profilePhotoPublicId,
    bool clearProfilePhoto = false,
    DateTime? suspendedUntil,
    bool clearSuspendedUntil = false,
  }) => UserModel(
    uid: uid,
    name: name ?? this.name,
    email: email,
    role: role ?? this.role,
    status: status ?? this.status,
    profilePhotoUrl: clearProfilePhoto
        ? null
        : (profilePhotoUrl ?? this.profilePhotoUrl),
    profilePhotoPublicId: clearProfilePhoto
        ? null
        : (profilePhotoPublicId ?? this.profilePhotoPublicId),
    createdAt: createdAt,
    suspendedUntil: clearSuspendedUntil
        ? null
        : (suspendedUntil ?? this.suspendedUntil),
    suspendedAt: suspendedAt,
    reinstatedAt: reinstatedAt,
  );
}

/// A string field, whatever Firestore actually returned.
String _string(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;

String? _nullableString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// A date field, tolerating both a resolved `Timestamp` and an unresolved
/// `FieldValue.serverTimestamp()` that has not come back from the server yet.
DateTime? _date(Object? value) {
  if (value is Timestamp) return value.toDate();
  // Firestore normally hands back Timestamp, but a document written by another
  // client or a migration script can carry an ISO string or epoch millis.
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
