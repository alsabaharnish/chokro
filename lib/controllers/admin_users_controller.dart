import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/user_model.dart';
import '../services/user_service.dart';

/// Uniquely named so it cannot collide with any `userServiceProvider` declared
/// elsewhere. `UserService` holds only `FirebaseFirestore.instance`, so a
/// second instance costs nothing; if a shared provider already exists, point
/// this at it instead.
final adminUserServiceProvider = Provider<UserService>((ref) => UserService());

/// Every account, for the admin list (F5.2).
///
/// Unpaginated: the whole `users` collection in one stream. Fine at the scale
/// this prototype runs at, and stated as a limitation rather than pretended
/// away — NFR-2 asks for paginated reads, and this is not one.
final allUsersProvider = StreamProvider.autoDispose<List<UserModel>>((ref) {
  return ref.watch(adminUserServiceProvider).watchAllUsers();
});

/// Suspension actions (F5.2, F5.3).
///
/// These write Firestore directly rather than calling the Node service, which
/// is the exception to "the client writes nothing that matters" — and it is
/// deliberate. A suspension is not a payout: rules *can* express who may set it
/// and which keys they may touch, so the check that matters is expressible
/// where it is enforced. Compare a wallet balance, where rules cannot check
/// whether a photograph was screened, which is why that path goes to the
/// server.
class AdminUserActions {
  AdminUserActions(this._ref);

  final Ref _ref;

  /// [until] null suspends indefinitely.
  Future<void> suspend(String uid, {DateTime? until}) {
    return _ref.read(adminUserServiceProvider).suspendUser(uid, until: until);
  }

  Future<void> reinstate(String uid) {
    return _ref.read(adminUserServiceProvider).reinstateUser(uid);
  }
}

final adminUserActionsProvider = Provider<AdminUserActions>((ref) {
  return AdminUserActions(ref);
});
