import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/services/user_service.dart';
import 'package:chokro/views/profile/profile_view.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Profile management (F1.1).
///
/// The rename write is the whole feature, and the thing most easily got wrong is
/// its *shape*: the rule permits a diff containing `name` and nothing else, so a
/// companion field would make every rename fail with permission-denied. That is
/// asserted here rather than left to a manual check against a live project.

class _RecordingUserService extends UserService {
  final List<Map<String, Object?>> writes = [];
  Object? throwThis;

  @override
  Future<void> updateName({required String uid, required String name}) async {
    if (throwThis != null) throw throwThis!;
    writes.add({'uid': uid, 'name': name});
  }
}

UserModel _user({
  String name = 'Nabil',
  String role = AppConstants.roleBuyer,
  String status = AppConstants.statusActive,
  DateTime? createdAt,
  DateTime? suspendedUntil,
}) => UserModel(
  uid: 'uid-1',
  name: name,
  email: 'nabil@example.com',
  role: role,
  status: status,
  createdAt: createdAt,
  suspendedUntil: suspendedUntil,
);

Future<_RecordingUserService> _pump(
  WidgetTester tester, {
  required UserModel user,
}) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final service = _RecordingUserService();

  final router = GoRouter(
    initialLocation: '/profile',
    routes: [
      GoRoute(
        path: '/profile',
        builder: (context, state) => const ProfileView(),
      ),
      GoRoute(
        path: '/apply-seller',
        builder: (context, state) =>
            const Scaffold(body: Text('seller application')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        userServiceProvider.overrideWithValue(service),
        currentUserProvider.overrideWith((ref) => Stream.value(user)),
      ],
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return service;
}

Finder get _nameField => find.byType(TextFormField);
Finder get _save => find.widgetWithText(FilledButton, 'Save');

void main() {
  testWidgets('shows the stored name and the account facts', (tester) async {
    await _pump(
      tester,
      user: _user(
        role: AppConstants.roleSeller,
        createdAt: DateTime(2026, 3, 4),
      ),
    );

    expect(tester.widget<TextFormField>(_nameField).controller?.text, 'Nabil');
    expect(find.text('nabil@example.com'), findsOneWidget);
    expect(find.text('Using 3ZERO Greenpreneur'), findsOneWidget);
    expect(find.text('4 Mar 2026'), findsOneWidget);
  });

  testWidgets('save is withheld until the name actually changes', (
    tester,
  ) async {
    await _pump(tester, user: _user());

    // Nothing to write yet: the field holds exactly what is stored.
    expect(tester.widget<FilledButton>(_save).onPressed, isNull);

    await tester.enterText(_nameField, 'Nabil Ahmed');
    await tester.pump();
    expect(tester.widget<FilledButton>(_save).onPressed, isNotNull);

    // Typing it back to the stored value withdraws the offer again.
    await tester.enterText(_nameField, 'Nabil');
    await tester.pump();
    expect(tester.widget<FilledButton>(_save).onPressed, isNull);
  });

  testWidgets('the write carries only the name', (tester) async {
    final service = await _pump(tester, user: _user());

    await tester.enterText(_nameField, 'Nabil Ahmed');
    await tester.pump();
    await tester.tap(_save);
    await tester.pumpAndSettle();

    expect(service.writes, hasLength(1));
    // Anything beyond uid and name here means the Firestore write grew a field,
    // and `hasOnly(['name'])` in the rules would refuse the whole update.
    expect(service.writes.single, {'uid': 'uid-1', 'name': 'Nabil Ahmed'});
    expect(find.text('Name updated.'), findsOneWidget);
  });

  testWidgets('a surrounding space is trimmed before it is stored', (
    tester,
  ) async {
    final service = await _pump(tester, user: _user());

    // Invisible in the field, and it would greet the user as "Hello, Nabil "
    // on every screen from then on.
    await tester.enterText(_nameField, '  Nabil Ahmed  ');
    await tester.pump();
    await tester.tap(_save);
    await tester.pumpAndSettle();

    expect(service.writes.single['name'], 'Nabil Ahmed');
  });

  testWidgets('an empty name is refused before any write', (tester) async {
    final service = await _pump(tester, user: _user());

    await tester.enterText(_nameField, '');
    await tester.pump();
    await tester.tap(_save);
    await tester.pumpAndSettle();

    expect(find.text('Enter your name'), findsOneWidget);
    expect(service.writes, isEmpty);
  });

  testWidgets('a refused write explains itself and keeps the typed name', (
    tester,
  ) async {
    final service = await _pump(tester, user: _user());
    service.throwThis = _permissionDenied();

    await tester.enterText(_nameField, 'Nabil Ahmed');
    await tester.pump();
    await tester.tap(_save);
    await tester.pumpAndSettle();

    expect(find.textContaining('refused'), findsOneWidget);
    // Deliberately not blamed on a suspension: the rules allow a suspended
    // account to rename itself, proven in rules_test/rules.test.js.
    expect(find.textContaining('suspended'), findsNothing);
    // The typed value survives, so the user can retry rather than retype.
    expect(
      tester.widget<TextFormField>(_nameField).controller?.text,
      'Nabil Ahmed',
    );
  });

  testWidgets('a suspended account is told why, with the date', (tester) async {
    await _pump(
      tester,
      user: _user(
        status: AppConstants.statusSuspended,
        suspendedUntil: DateTime(2026, 9, 1),
      ),
    );

    expect(find.text('Account suspended'), findsOneWidget);
    expect(find.textContaining('1 Sep 2026'), findsOneWidget);
  });

  testWidgets('an indefinite suspension names no date', (tester) async {
    await _pump(tester, user: _user(status: AppConstants.statusSuspended));

    expect(find.text('Account suspended'), findsOneWidget);
    expect(find.textContaining('Contact a 3ZERO Admin'), findsOneWidget);
  });

  testWidgets('a pending join date reads as just now, not as an error', (
    tester,
  ) async {
    // createdAt is null for one server round trip after registration.
    await _pump(tester, user: _user(createdAt: null));

    expect(find.text('Just now'), findsOneWidget);
  });

  testWidgets('a Champion is offered the Greenpreneur application', (
    tester,
  ) async {
    await _pump(tester, user: _user(role: AppConstants.roleBuyer));
    expect(find.text('Become a 3ZERO Greenpreneur'), findsOneWidget);
  });

  testWidgets('a Greenpreneur is not offered it again', (tester) async {
    await _pump(tester, user: _user(role: AppConstants.roleSeller));
    expect(find.text('Become a 3ZERO Greenpreneur'), findsNothing);
  });
}

/// A real Firestore permission failure — the exact type the controller catches,
/// and what the rules produce for a diff carrying more than `name`.
Object _permissionDenied() => FirebaseException(
  plugin: 'cloud_firestore',
  code: 'permission-denied',
  message: 'Missing or insufficient permissions.',
);
