import 'package:chokro/controllers/account_profile_controller.dart';
import 'package:chokro/controllers/admin_workload_controller.dart';
import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/controllers/cart_controller.dart';
import 'package:chokro/controllers/claim_controller.dart';
import 'package:chokro/core/account_profile.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/claim_model.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/views/admin/admin_claims_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _admin = UserModel(
  uid: 'admin-1',
  name: 'Admin Reviewer',
  email: 'admin@example.test',
  role: AppConstants.roleAdmin,
  status: AppConstants.statusActive,
);

final _approved = ClaimModel(
  id: 'claim-approved',
  userId: 'champion-1',
  actionType: ClaimActionType.treePlanting,
  photoUrl: 'https://example.test/action.jpg',
  story: 'We planted this sapling beside our community field.',
  publicationMode: ClaimPublicationMode.named,
  championName: 'Amina Rahman',
  championPhotoUrl: 'https://example.test/amina.jpg',
  status: ClaimStatus.approved,
  pointsAwarded: 15,
  reviewedBy: 'admin-1',
  reviewedAt: DateTime.utc(2026, 8, 24),
  createdAt: DateTime.utc(2026, 8, 23),
);

final _legacyWithoutPermission = ClaimModel(
  id: 'claim-legacy',
  userId: 'champion-2',
  actionType: ClaimActionType.composting,
  photoUrl: 'https://example.test/compost.jpg',
  story: 'An older approved action.',
  status: ClaimStatus.approved,
  pointsAwarded: 15,
  reviewedBy: 'admin-1',
  reviewedAt: DateTime.utc(2026, 8, 23),
  createdAt: DateTime.utc(2026, 8, 22),
);

void main() {
  testWidgets('approved eco-actions remain available in the Photocards tab', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/admin/claims',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('Admin home')),
        ),
        GoRoute(
          path: '/admin/claims',
          builder: (_, _) => const AdminClaimsView(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) => Stream.value(_admin)),
          activeAccountProfileProvider.overrideWithValue(AccountProfile.admin),
          cartCountProvider.overrideWithValue(0),
          adminWorkloadProvider.overrideWithValue(AdminWorkload.empty),
          pendingClaimsProvider.overrideWith((ref) => Stream.value(const [])),
          approvedClaimsProvider.overrideWith(
            (ref) => Stream.value([_approved, _legacyWithoutPermission]),
          ),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing waiting'), findsOneWidget);
    expect(find.text('Create photocard'), findsNothing);

    await tester.tap(find.text('Photocards'));
    await tester.pumpAndSettle();

    expect(find.text('Tree planting'), findsOneWidget);
    expect(find.text('Name & picture permitted'), findsOneWidget);
    expect(find.text('Create photocard'), findsOneWidget);
    expect(find.text('No public sharing permission'), findsOneWidget);
    expect(find.text('Permission not recorded'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
