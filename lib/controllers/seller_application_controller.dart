import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/seller_application_model.dart';
import '../core/constants.dart';
import 'auth_controller.dart';

final pendingApplicationsProvider =
    StreamProvider<List<SellerApplicationModel>>((ref) {
  return ref.watch(userServiceProvider).watchPendingApplications();
});

final userApplicationsProvider =
    StreamProvider<List<SellerApplicationModel>>((ref) {
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
      if (user == null) throw Exception('Not signed in');

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
      if (user == null) throw Exception('Not signed in');

      await ref.read(userServiceProvider).reviewApplication(
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
      if (user == null) throw Exception('Not signed in');

      await ref.read(userServiceProvider).reviewApplication(
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
        SellerApplicationController.new);
