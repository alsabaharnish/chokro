import 'package:chokro/controllers/admin_users_controller.dart';
import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/controllers/current_user_provider.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/services/user_service.dart';
import 'package:chokro/views/admin/admin_users_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

UserModel _user({
  required String uid,
  required String name,
  required String email,
  String status = AppConstants.statusActive,
}) {
  return UserModel(
    uid: uid,
    name: name,
    email: email,
    role: AppConstants.roleBuyer,
    status: status,
  );
}

void main() {
  testWidgets('filters and account actions fit a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final admin = UserModel(
      uid: 'admin',
      name: 'Admin',
      email: 'admin@example.com',
      role: AppConstants.roleAdmin,
      status: AppConstants.statusActive,
    );
    final router = GoRouter(
      initialLocation: '/admin/users',
      routes: [
        GoRoute(
          path: '/admin/users',
          builder: (_, _) => const AdminUsersView(),
        ),
        GoRoute(
          path: '/profile',
          builder: (_, _) => const Scaffold(body: Text('Profile')),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) => Stream.value(admin)),
          currentUidProvider.overrideWithValue('admin'),
          allUsersProvider.overrideWith(
            (ref) => Stream.value(
              UserDirectoryPage(
                users: [
                  _user(
                    uid: 'buyer-1',
                    name: 'A user with a fairly long name',
                    email: 'long-address@example.com',
                  ),
                  _user(
                    uid: 'buyer-2',
                    name: 'Suspended account',
                    email: 'suspended@example.com',
                    status: AppConstants.statusSuspended,
                  ),
                ],
                truncated: false,
              ),
            ),
          ),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Active'), findsWidgets);
    expect(find.text('Suspended'), findsOneWidget);
    expect(find.text('Reinstate'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Suspend'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Suspend'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
