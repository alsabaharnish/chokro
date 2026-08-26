import 'package:chokro/controllers/admin_review_controller.dart';
import 'package:chokro/controllers/appeals_controller.dart';
import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/appeal_model.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/views/admin/admin_appeals_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The appeal queue's safety gate must not survive the appeal it belongs to.
///
/// An admin cannot decide an appeal until they have loaded the original
/// photograph and ticked "I reviewed" — that gate is the only thing standing
/// between a queue and a rubber stamp. It lives in the card's local State, and
/// the cards were built unkeyed: resolving one appeal removes it from the
/// stream, every later appeal shifts up a position, and Flutter's unkeyed
/// reconciliation matches State to widget by index. So the tick given to the
/// first appeal was inherited by the second, arming Uphold and Decline on
/// evidence nobody had looked at.
const _admin = UserModel(
  uid: 'admin-1',
  name: 'Admin One',
  email: 'admin@example.com',
  role: AppConstants.roleAdmin,
  status: AppConstants.statusActive,
);

AppealModel _appeal(String id) => AppealModel(
  id: id,
  userId: 'champion-$id',
  subjectType: AppealSubject.disposal,
  subjectId: 'disposal-$id',
  message: 'Please look at this again, the photograph shows the full bag.',
  createdAt: DateTime(2026, 8, 20),
);

AppealSubjectEvidence _evidence(String id) => AppealSubjectEvidence(
  subjectType: AppealSubject.disposal,
  title: 'Plastic bottles',
  photoUrl:
      'https://res.cloudinary.com/demo/image/upload/v1/chokro/d/u/$id.jpg',
  rejectionReason: 'The photograph did not show the bin.',
  submittedAt: DateTime(2026, 8, 19),
);

void main() {
  testWidgets('each appeal card gets its own gate, keyed by appeal id', (
    tester,
  ) async {
    final appeals = [_appeal('a'), _appeal('b'), _appeal('c')];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) => Stream.value(_admin)),
          pendingAppealsProvider.overrideWith((ref) => Stream.value(appeals)),
          appealSubjectEvidenceProvider.overrideWith(
            (ref, subject) async => _evidence(subject.subjectId),
          ),
          adminReviewControllerProvider.overrideWith(AdminReviewController.new),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: GoRouter(
            routes: [
              GoRoute(path: '/', builder: (_, _) => const AdminAppealsView()),
            ],
          ),
        ),
      ),
    );
    // Bounded pumps rather than `pumpAndSettle`: the evidence panel holds a
    // `CachedNetworkImage`, whose placeholder never settles under the test
    // binding (no request completes), and `SlowServerNote` runs a timer.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The identity that makes State un-reusable across appeals. Without it the
    // confirmation tick migrates between cards as the queue shortens.
    for (final appeal in appeals) {
      expect(
        find.byKey(ValueKey(appeal.id)),
        findsOneWidget,
        reason: 'appeal ${appeal.id} must own its own card State',
      );
    }
  });
}
