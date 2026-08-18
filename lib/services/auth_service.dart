import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  Future<UserCredential> signUp({
    required String email,
    required String password,
  }) =>
      _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) =>
      _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

  Future<void> signOut() => _auth.signOut();

  /// Sends a password-reset email (F1.1).
  ///
  /// The only in-app recovery path there is. Without it a forgotten password is
  /// terminal — there is no other route back into an account, and
  /// `core/auth_errors.dart` was already carrying a `requires-recent-login`
  /// message for a feature nothing implemented.
  ///
  /// Firebase deliberately does **not** report whether the address is registered,
  /// and this does not attempt to find out. Telling a caller "no account exists
  /// with that email" turns the reset form into an account-enumeration oracle —
  /// the same reason `authErrorMessage` keeps the three credential failures
  /// indistinguishable at sign-in. The caller shows the same confirmation either
  /// way.
  Future<void> sendPasswordReset(String email) =>
      _auth.sendPasswordResetEmail(email: email.trim());
}
