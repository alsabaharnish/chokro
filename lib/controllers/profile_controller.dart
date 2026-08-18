/// Profile management (F1.1).
///
/// The half of F1.1 that was never built. Account *creation* existed from M1;
/// nothing let a user look at their own account afterwards, or correct the name
/// they typed during signup. The security rules had been written for it all
/// along — `allow update: if isSelf(uid) && ...hasOnly(['name'])` — so the
/// permission to do this was deployed and simply unreachable from the app.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';


/// Why a rename failed, in words the user can act on.
class ProfileFailure implements Exception {
  const ProfileFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Renames the signed-in account.
///
/// Exposed as an [AsyncNotifier] so the view can show progress and surface a
/// failure without holding that state itself, matching [AuthController].
class ProfileController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  /// Saves [name] as the signed-in user's display name.
  ///
  /// Trims first. A trailing space is invisible in a text field and would be
  /// stored, then greet the user as "Hello, Nabil " forever.
  Future<void> rename(String name) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final user = ref.read(currentUserProvider).value;
      if (user == null) {
        throw const ProfileFailure(
          'You are not signed in. Sign in and try again.',
        );
      }

      final trimmed = name.trim();
      if (trimmed == user.name) return; // Nothing to write.

      try {
        await ref
            .read(userServiceProvider)
            .updateName(uid: user.uid, name: trimmed);
      } on FirebaseException catch (error) {
        throw ProfileFailure(_message(error.code));
      }
    });
  }

  /// Firestore's codes, translated.
  ///
  /// `permission-denied` deliberately does **not** blame a suspension. The
  /// self-update branch of the rule checks `isSelf` and the affected keys and
  /// never calls `isActive()`, so a suspended account can still correct its own
  /// name — a suspension withholds submitting and claiming, not spelling.
  /// `rules_test/rules.test.js` pins that behaviour, and an earlier draft of this
  /// message asserted the opposite.
  ///
  /// What actually reaches here is a session that no longer matches the account
  /// being written, or a write that grew a second field — the latter being a bug
  /// in this app rather than anything the user can act on, which is why the
  /// wording stays on the one thing they can try.
  static String _message(String code) => switch (code) {
        'permission-denied' =>
          'That change was refused. Try signing out and back in.',
        'unavailable' || 'deadline-exceeded' =>
          'Could not reach the database. Check your connection and try again.',
        'not-found' =>
          'Your account details could not be found. Try signing out and back '
              'in.',
        _ => 'The name could not be saved. Try again.',
      };
}

final profileControllerProvider =
    AsyncNotifierProvider<ProfileController, void>(ProfileController.new);
