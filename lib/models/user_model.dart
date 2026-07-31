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
  final DateTime createdAt;

  /// When a temporary suspension lapses.
  ///
  /// Null while active, and null for a *permanent* suspension — which is why
  /// null must never be read as "not suspended". Only [isActiveAt] should
  /// interpret this field.
  final DateTime? suspendedUntil;

  const UserModel({
    required this.uid,
    required this.name,
    required this.email,
    required this.role,
    required this.status,
    required this.createdAt,
    this.suspendedUntil,
  });

  bool get isAdmin => role == AppConstants.roleAdmin;
  bool get isSeller => role == AppConstants.roleSeller || isAdmin;

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

  factory UserModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return UserModel(
      uid: doc.id,
      name: data['name'] as String,
      email: data['email'] as String,
      role: data['role'] as String,
      status: data['status'] as String,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      suspendedUntil: (data['suspendedUntil'] as Timestamp?)?.toDate(),
    );
  }

  /// Omits `suspendedUntil` when null rather than writing an explicit null.
  /// Registration writes this map, and an absent key is cleaner than a null
  /// one for a field that only an administrator ever sets.
  Map<String, dynamic> toFirestore() => {
        'name': name,
        'email': email,
        'role': role,
        'status': status,
        'createdAt': Timestamp.fromDate(createdAt),
        if (suspendedUntil != null)
          'suspendedUntil': Timestamp.fromDate(suspendedUntil!),
      };

  /// [clearSuspendedUntil] exists because passing null to [suspendedUntil]
  /// cannot be distinguished from omitting it.
  UserModel copyWith({
    String? name,
    String? role,
    String? status,
    DateTime? suspendedUntil,
    bool clearSuspendedUntil = false,
  }) =>
      UserModel(
        uid: uid,
        name: name ?? this.name,
        email: email,
        role: role ?? this.role,
        status: status ?? this.status,
        createdAt: createdAt,
        suspendedUntil:
            clearSuspendedUntil ? null : (suspendedUntil ?? this.suspendedUntil),
      );
}
