import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart' show firebaseAuthStateProvider;

/// The signed-in user's uid, or null.
///
/// Delegates to the auth layer's existing stream rather than opening a second
/// listener on `authStateChanges()`. One subscription, one source of truth.
final currentUidProvider = Provider<String?>((ref) {
  return ref.watch(firebaseAuthStateProvider).asData?.value?.uid;
});
