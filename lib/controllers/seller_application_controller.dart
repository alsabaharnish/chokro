import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/seller_application_model.dart';
import '../core/constants.dart';
import '../core/network_errors.dart';
import 'auth_controller.dart';

final pendingApplicationsProvider =
    StreamProvider<List<SellerApplicationModel>>((ref) {
      return ref.watch(userServiceProvider).watchPendingApplications();
    });

final userApplicationsProvider = StreamProvider<List<SellerApplicationModel>>((
  ref,
) {
  final user = ref.watch(currentUserProvider).value;
  if (user == null) return Stream.value([]);
  return ref.watch(userServiceProvider).watchUserApplications(user.uid);
});

class SellerApplicationController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  Future<void> submit({
    required String businessName,
    required String description,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final user = ref.read(currentUserProvider).value;
      if (user == null) {
        throw const SellerApplicationException(
          'You are signed out. Sign in again to continue.',
        );
      }

      // A second pending request adds noise to the Admin queue and makes it
      // unclear which business description should be reviewed. The screen also
      // disables the form, but the controller repeats the check so another UI
      // entry point cannot accidentally bypass it.
      final existing = await ref.read(userApplicationsProvider.future);
      if (existing.any((application) => application.isPending)) {
        throw const SellerApplicationException(
          'You already have an application waiting for review. Its status is '
          'on your profile.',
        );
      }

      final app = SellerApplicationModel(
        id: '',
        userId: user.uid,
        businessName: businessName,
        description: description,
        status: AppConstants.statusPending,
        // createdAt omitted: the service supplies a server timestamp (§6).
      );

      await ref.read(userServiceProvider).submitSellerApplication(app);
    });
  }

  Future<void> approve(String appId) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final user = ref.read(currentUserProvider).value;
      if (user == null) {
        throw const SellerApplicationException(
          'You are signed out. Sign in again to continue.',
        );
      }

      await ref
          .read(userServiceProvider)
          .reviewApplication(
            appId: appId,
            status: AppConstants.statusApproved,
            reviewedBy: user.uid,
          );
    });
  }

  Future<void> reject(String appId, String reason) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final user = ref.read(currentUserProvider).value;
      if (user == null) {
        throw const SellerApplicationException(
          'You are signed out. Sign in again to continue.',
        );
      }

      await ref
          .read(userServiceProvider)
          .reviewApplication(
            appId: appId,
            status: AppConstants.statusRejected,
            reviewedBy: user.uid,
            reason: reason,
          );
    });
  }
}

final sellerApplicationControllerProvider =
    AsyncNotifierProvider<SellerApplicationController, void>(
      SellerApplicationController.new,
    );

/// A Greenpreneur-application failure with a sentence already fit to display.
///
/// The three sites that used to throw `Exception('Not signed in')` and
/// `StateError('A Greenpreneur application is already pending.')` reached the
/// applicant through `friendlyErrorMessage` complete with Dart's own
/// `Exception: ` / `Bad state: ` prefix.
class SellerApplicationException implements UserFacingException {
  const SellerApplicationException(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}
