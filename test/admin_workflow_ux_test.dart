import 'package:chokro/controllers/account_profile_controller.dart';
import 'package:chokro/controllers/admin_workload_controller.dart';
import 'package:chokro/controllers/appeals_controller.dart';
import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/controllers/cart_controller.dart';
import 'package:chokro/core/account_profile.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/appeal_model.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/views/admin/admin_appeals_view.dart';
import 'package:chokro/views/admin/admin_todo_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _admin = UserModel(
  uid: 'admin-1',
  name: 'AL SABAH ARNISH',
  email: 'admin@example.com',
  role: AppConstants.roleAdmin,
  status: AppConstants.statusActive,
);

const _workload = AdminWorkload(
  claims: AdminTaskProgress(completedToday: 1),
  appeals: AdminTaskProgress(pending: 1, completedToday: 1),
);

void main() {
  testWidgets('to-do list shows done and waiting work and opens its queue', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/todo',
      routes: [
        GoRoute(
          path: '/todo',
          builder: (_, _) => const Scaffold(
            body: SingleChildScrollView(child: AdminTodoList()),
          ),
        ),
        GoRoute(
          path: '/admin/appeals',
          builder: (_, _) => const Scaffold(body: Text('Appeal queue opened')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [adminWorkloadProvider.overrideWithValue(_workload)],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Today's review list"), findsOneWidget);
    expect(find.text('1 waiting'), findsOneWidget);
    expect(find.text('1 done today'), findsNWidgets(2));
    expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(2));

    await tester.tap(find.text('Appeals'));
    await tester.pumpAndSettle();
    expect(find.text('Appeal queue opened'), findsOneWidget);
  });

  testWidgets('an appeal cannot be decided without its original photograph', (
    tester,
  ) async {
    const appeal = AppealModel(
      id: 'appeal-1',
      userId: 'champion-1',
      subjectType: AppealSubject.disposal,
      subjectId: 'disposal-1',
      message: 'The submitted photograph clearly shows the recycled items.',
    );
    final router = GoRouter(
      initialLocation: '/admin/appeals',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('Admin home')),
        ),
        GoRoute(
          path: '/admin/appeals',
          builder: (_, _) => const AdminAppealsView(),
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
          adminWorkloadProvider.overrideWithValue(_workload),
          pendingAppealsProvider.overrideWith(
            (ref) => Stream.value(const [appeal]),
          ),
          appealSubjectEvidenceProvider.overrideWith(
            (ref, subject) async => null,
          ),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('This appeal cannot be decided safely'),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Uphold'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    final uphold = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Uphold'),
    );
    final decline = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Decline'),
    );
    expect(uphold.onPressed, isNull);
    expect(decline.onPressed, isNull);
  });
}
