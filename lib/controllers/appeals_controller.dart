import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/appeal_model.dart';
import '../services/appeal_service.dart';
import 'current_user_provider.dart';

final appealServiceProvider = Provider<AppealService>((ref) => AppealService());

/// The signed-in user's appeals (F5.4).
final userAppealsProvider = StreamProvider.autoDispose<List<AppealModel>>((
  ref,
) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) {
    return Stream<List<AppealModel>>.value(const <AppealModel>[]);
  }
  return ref.watch(appealServiceProvider).watchUserAppeals(uid);
});

/// The subject ids this user has already appealed. The submission history uses
/// it to link to the existing appeal; deterministic ids and rules enforce the
/// same one-per-subject invariant at the database boundary.
final appealedSubjectIdsProvider = Provider.autoDispose<Set<String>>((ref) {
  final appeals = ref.watch(userAppealsProvider).asData?.value ?? const [];
  return appeals.map((appeal) => appeal.subjectKey).toSet();
});

/// The administrator's queue, oldest first.
final pendingAppealsProvider = StreamProvider.autoDispose<List<AppealModel>>((
  ref,
) {
  return ref.watch(appealServiceProvider).watchPendingAppeals();
});

/// Raising and resolving an appeal.
class AppealActions {
  AppealActions(this._ref);

  final Ref _ref;

  /// Raises an appeal against a rejected disposal or claim.
  ///
  /// The rules check far more than this does: that the named submission exists,
  /// belongs to the caller, and was actually rejected. What is validated here is
  /// only the text, so the user is told about a too-short message before a round
  /// trip that would come back as an undiagnosable `permission-denied`.
  Future<String> raise({
    required AppealSubject subjectType,
    required String subjectId,
    required String message,
  }) async {
    final uid = _ref.read(currentUidProvider);
    if (uid == null) throw StateError('Not signed in.');

    final problem = AppealModel.validateMessage(message);
    if (problem != null) throw AppealValidationException(problem);

    return _ref
        .read(appealServiceProvider)
        .create(
          AppealModel(
            userId: uid,
            subjectType: subjectType,
            subjectId: subjectId,
            message: message,
          ),
        );
  }

  /// Resolves an appeal with a written answer.
  ///
  /// The answer is mandatory on either outcome, and the rules enforce a minimum
  /// length: a status with no words is not an answer, and the user reading it is
  /// the person who was already told "rejected" once with a reason they
  /// disputed.
  Future<void> resolve({
    required String appealId,
    required bool uphold,
    required String response,
  }) async {
    final uid = _ref.read(currentUidProvider);
    if (uid == null) throw StateError('Not signed in.');

    final problem = AppealModel.validateResponse(response);
    if (problem != null) throw AppealValidationException(problem);

    await _ref
        .read(appealServiceProvider)
        .resolve(
          appealId: appealId,
          adminUid: uid,
          uphold: uphold,
          response: response,
        );
  }
}

final appealActionsProvider = Provider<AppealActions>(
  (ref) => AppealActions(ref),
);

/// Text that failed the same bounds `firestore.rules` enforces.
class AppealValidationException implements Exception {
  const AppealValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}
