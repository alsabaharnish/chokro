import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import '../services/user_service.dart';
import '../models/user_model.dart';
import '../core/auth_errors.dart';
import '../core/constants.dart';

final authServiceProvider = Provider<AuthService>((ref) => AuthService());
final userServiceProvider = Provider<UserService>((ref) => UserService());

// raw Firebase auth state
final firebaseAuthStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(authServiceProvider).authStateChanges;
});

// resolved UserModel from Firestore
final currentUserProvider = StreamProvider<UserModel?>((ref) {
  final authState = ref.watch(firebaseAuthStateProvider);
  return authState.when(
    data: (user) {
      if (user == null) return Stream.value(null);
      return ref.watch(userServiceProvider).watchUser(user.uid);
    },
    loading: () => Stream.value(null),
    error: (_, _) => Stream.value(null),
  );
});

// auth actions
class AuthController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  /// Runs [action], converting any Firebase auth failure into an [AuthFailure]
  /// whose message is already fit to display.
  ///
  /// The views read `state.error` and render it directly, so the conversion has
  /// to happen here — on the far side of that boundary there is no longer
  /// enough information to say anything useful, and `toString()` on the vendor
  /// exception is what used to reach the user.
  Future<void> _guard(Future<void> Function() action) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      try {
        await action();
      } on FirebaseAuthException catch (err) {
        throw AuthFailure(authErrorMessage(err.code), code: err.code);
      }
    });
  }

  Future<void> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    await _guard(() async {
      final authService = ref.read(authServiceProvider);
      final userService = ref.read(userServiceProvider);

      final credential = await authService.signUp(
        email: email,
        password: password,
      );

      final user = UserModel(
        uid: credential.user!.uid,
        name: name,
        email: email,
        role: AppConstants.roleBuyer,
        status: AppConstants.statusActive,
        createdAt: DateTime.now(),
      );

      // atomic: user doc + wallet doc in one batch
      await userService.createUserWithWallet(user);
    });
  }

  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    await _guard(() async {
      await ref.read(authServiceProvider).signIn(
            email: email,
            password: password,
          );
    });
  }

  Future<void> signOut() async {
    await _guard(() async {
      await ref.read(authServiceProvider).signOut();
    });
  }
}

final authControllerProvider =
    AsyncNotifierProvider<AuthController, void>(AuthController.new);
