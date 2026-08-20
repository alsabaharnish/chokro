import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import '../services/user_service.dart';
import '../models/user_model.dart';
import '../core/auth_errors.dart';
import '../core/constants.dart';
// Scoped import. `push_controller.dart` imports `firebaseAuthStateProvider` from
// this file, so the two form a cycle — which Dart permits for library imports
// (unlike `part` files). Both sides are `show`-scoped to keep the intent legible.
import 'push_controller.dart' show pushServiceProvider;

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
    // A failed auth subscription is not the same state as "signed out". Keep
    // the error so the router can show recovery instead of claiming the user's
    // Firestore profile is missing.
    error: (error, stackTrace) => Stream<UserModel?>.error(error, stackTrace),
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
        // Persist the address Firebase Auth accepted, including any provider
        // normalization. Firestore rules bind this field to the token claim.
        email: created.email ?? email,
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

  Future<void> signIn({required String email, required String password}) async {
    await _guard(() async {
      await ref
          .read(authServiceProvider)
          .signIn(email: email, password: password);
    });
  }

  /// Sends a password-reset email (F1.1).
  ///
  /// Succeeds silently whether or not the address is registered. Firebase does
  /// not say, and the view must not imply it either: a form that answered "no
  /// such account" would let anyone test which email addresses hold accounts,
  /// which is the same leak `authErrorMessage` avoids by keeping the three
  /// credential failures indistinguishable at sign-in.
  ///
  /// `invalid-email` is still reported, because that is about the text typed
  /// rather than about who exists.
  Future<void> sendPasswordReset(String email) async {
    await _guard(() async {
      await ref.read(authServiceProvider).sendPasswordReset(email);
    });
  }

  /// Signs out, retiring this device's push registration first (F7.1).
  ///
  /// The order is the whole point, and getting it wrong fails silently.
  ///
  /// `users/{uid}/devices/{token}` is deletable only by `isSelf(uid)`. After
  /// `signOut` there is no `request.auth`, so the rules refuse the delete and the
  /// document is stranded server-side — still listed, still notified. The next
  /// decision for *this* account then lights up the phone of whoever signs in
  /// next, carrying a rejection reason written for somebody else. Shared and
  /// borrowed phones are normal in this project's setting, so that is a real
  /// disclosure rather than a hypothetical one.
  ///
  /// It cannot be driven off the auth stream going null for the same reason —
  /// see `PushRegistrar`, which handles registration but deliberately not this.
  ///
  /// The cleanup never throws and is not allowed to block the sign-out. A user
  /// who taps sign out must end up signed out even if the network is gone; a
  /// stranded token is the lesser failure, and the server prunes tokens FCM
  /// reports as dead anyway.
  Future<void> signOut() async {
    await _guard(() async {
      final uid = ref.read(authServiceProvider).currentUser?.uid;
      if (uid != null) {
        await ref.read(pushServiceProvider).unregisterDevice(uid);
      }

      await ref.read(authServiceProvider).signOut();
    });
  }
}

final authControllerProvider = AsyncNotifierProvider<AuthController, void>(
  AuthController.new,
);
