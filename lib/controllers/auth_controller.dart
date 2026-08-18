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

      final created = credential.user;
      if (created == null) {
        // Should not happen after a successful signUp, but the alternative was
        // `credential.user!`, and a null there would have surfaced as a bare
        // type error instead of anything a user could act on.
        throw const AuthFailure(
          'The account was created but could not be opened. Try signing in.',
          code: 'missing-credential-user',
        );
      }

      final user = UserModel(
        uid: created.uid,
        name: name,
        email: email,
        role: AppConstants.roleBuyer,
        status: AppConstants.statusActive,
        // createdAt comes from the server — see UserModel.toFirestore.
      );

      try {
        // atomic: user doc + wallet doc in one batch
        await userService.createUserWithWallet(user);
      } catch (error) {
        // Registration is two steps against two different systems: an Auth
        // account, then a Firestore profile. Failing the second used to leave
        // an account that could authenticate and do nothing else — no role, no
        // wallet, no name — and the only way out was the recovery screen.
        //
        // Rolling the Auth account back turns that dead end into a plain retry,
        // and frees the email address so the second attempt is not refused as
        // already-in-use.
        //
        // Best effort: if the delete also fails the account survives and the
        // recovery screen is still there to catch it. Either way the original
        // failure is what gets reported, because that is the one that explains
        // what went wrong.
        try {
          await created.delete();
        } catch (_) {
          // Swallowed on purpose. Reporting a cleanup failure instead of the
          // real cause would send the user chasing the wrong problem.
        }
        rethrow;
      }
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
