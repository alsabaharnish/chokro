import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/points_policy.dart';
import '../services/points_policy_service.dart';

final pointsPolicyServiceProvider = Provider<PointsPolicyService>((ref) {
  return PointsPolicyService();
});

/// The live policy from `config/points`.
///
/// A [FutureProvider] rather than a stream: the policy changes rarely and only
/// by administrator action, so a listener on the document would cost more than
/// it returns. The editor invalidates this after a successful save.
final pointsPolicyProvider = FutureProvider.autoDispose<PointsPolicy>((ref) {
  return ref.watch(pointsPolicyServiceProvider).fetch();
});

/// Save path for the editor.
///
/// Deliberately a plain class behind a `Provider` rather than a notifier: the
/// form already owns its own in-progress state through its text controllers,
/// so a second copy of that state in a notifier would be two things to keep in
/// step. This exists so the view calls a controller rather than a service.
class PointsPolicyEditor {
  PointsPolicyEditor(this._ref);

  final Ref _ref;

  /// Writes [policy] and refreshes the cached read.
  ///
  /// Returns what the server stored. Throws [PolicyException], carrying
  /// `problems` when the server's validation refused the values.
  Future<PointsPolicy> save(PointsPolicy policy) async {
    final stored = await _ref.read(pointsPolicyServiceProvider).save(policy);
    _ref.invalidate(pointsPolicyProvider);
    return stored;
  }
}

final pointsPolicyEditorProvider = Provider<PointsPolicyEditor>((ref) {
  return PointsPolicyEditor(ref);
});
