import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/user_model.dart';
import '../services/product_service.dart';
import '../services/user_service.dart';
import 'catalog_controller.dart';

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

/// What a suspension or reinstatement actually did.
///
/// Two operations, not one — see [AdminUserActions.suspend]. This carries both
/// outcomes so the screen can tell an administrator the truth about each rather
/// than reporting the pair as a single success.
class SuspensionOutcome {
  const SuspensionOutcome({this.listingsChanged = 0, this.listingsProblem});

  /// How many listings were hidden or restored. Zero for an account that sells
  /// nothing, and zero when the sweep failed.
  final int listingsChanged;

  /// Non-null when the account write succeeded and the catalogue sweep did not.
  /// The administrator has to know: the account is suspended and its shop is
  /// still open.
  final String? listingsProblem;

  bool get sweptCleanly => listingsProblem == null;
}

/// Suspension actions (F5.2, F5.3), and the catalogue sweep that goes with them
/// (§7.4).
///
/// The account write goes straight to Firestore rather than through the Node
/// service, which is the exception to "the client writes nothing that matters"
/// — and it is deliberate. A suspension is not a payout: rules *can* express who
/// may set it and which keys they may touch, so the check that matters is
/// expressible where it is enforced. Compare a wallet balance, where rules
/// cannot check whether a photograph was screened, which is why that path goes
/// to the server.
///
/// The listing sweep is the opposite case and therefore goes the other way.
/// `products` is writable only by its owning seller, so an administrator has no
/// rule that would let them reach in — and adding one would grant "an admin may
/// edit any listing", a far larger privilege than hiding a shop needs. The Admin
/// SDK bypasses rules, so the sweep runs on the server and the ownership rule
/// stays as narrow as it is.
class AdminUserActions {
  AdminUserActions(this._ref);

  final Ref _ref;

  /// Suspends an account, and hides its shop if it has one (§7.4).
  ///
  /// [until] null suspends indefinitely.
  ///
  /// **These are two operations and the result says so.** They cannot be made
  /// atomic — one is a Firestore write from this client and the other is an HTTP
  /// call — so the honest thing is to do the account first, since that is what
  /// actually stops the person acting, and then report separately on the shop.
  /// A suspended seller whose catalogue is still visible is a state somebody has
  /// to be told about rather than left to discover.
  Future<SuspensionOutcome> suspend(
    String uid, {
    DateTime? until,
    bool isSeller = false,
  }) async {
    await _ref.read(adminUserServiceProvider).suspendUser(uid, until: until);
    return _sweepListings(uid, visible: false, isSeller: isSeller);
  }

  /// Reinstates an account and restores the listings this sweep hid.
  ///
  /// Only those. A seller may have taken products down themselves, and
  /// republishing those would be making a decision that is not the
  /// administrator's to make — which is what `hiddenBySuspension` is for.
  Future<SuspensionOutcome> reinstate(
    String uid, {
    bool isSeller = false,
  }) async {
    await _ref.read(adminUserServiceProvider).reinstateUser(uid);
    return _sweepListings(uid, visible: true, isSeller: isSeller);
  }

  Future<SuspensionOutcome> _sweepListings(
    String uid, {
    required bool visible,
    required bool isSeller,
  }) async {
    // A buyer has no catalogue, so there is nothing to sweep and no reason to
    // wake a sleeping Render instance to prove it.
    if (!isSeller) return const SuspensionOutcome();

    try {
      final changed = await _ref
          .read(productServiceProvider)
          .setSellerListingsVisible(uid, visible);
      return SuspensionOutcome(listingsChanged: changed);
    } on ProductException catch (error) {
      return SuspensionOutcome(listingsProblem: error.message);
    } catch (error) {
      return SuspensionOutcome(listingsProblem: '$error');
    }
  }
}

final adminUserActionsProvider = Provider<AdminUserActions>((ref) {
  return AdminUserActions(ref);
});
