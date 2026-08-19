import 'package:chokro/core/theme.dart';
import 'package:chokro/views/shared/auth_frame.dart';
import 'package:chokro/views/shared/brand_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpAt(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: const AuthFrame(
        title: 'Welcome back',
        subtitle: 'Sign in to continue building your verified impact.',
        child: Column(
          children: [
            TextField(decoration: InputDecoration(labelText: 'Email')),
            SizedBox(height: 16),
            TextField(decoration: InputDecoration(labelText: 'Password')),
            SizedBox(height: 24),
            FilledButton(onPressed: null, child: Text('Sign in')),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('fits a narrow phone without overflow', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpAt(tester, const Size(320, 640));

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.byType(BrandMark), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adds the brand panel on a wide browser', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpAt(tester, const Size(1280, 800));

    expect(find.text('Every responsible action should count.'), findsOneWidget);
    expect(find.byType(BrandMark), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
