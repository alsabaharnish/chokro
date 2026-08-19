import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/views/shared/startup_error_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'explains a retryable account-service failure on a small screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            firebaseAuthStateProvider.overrideWith((ref) => Stream.value(null)),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const StartupErrorView(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Could not open your account'), findsOneWidget);
      expect(
        find.textContaining('Your profile has not been changed'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Sign out'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
