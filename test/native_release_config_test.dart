import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

int _occurrences(String source, String pattern) =>
    RegExp(RegExp.escape(pattern)).allMatches(source).length;

void main() {
  test('Android release protects cached identity and requires HTTPS', () {
    final releaseManifest = _read('android/app/src/main/AndroidManifest.xml');

    expect(releaseManifest, contains('android:allowBackup="false"'));
    expect(
      releaseManifest,
      contains('android:fullBackupContent="@xml/backup_rules"'),
    );
    expect(
      releaseManifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
    expect(releaseManifest, isNot(contains('usesCleartextTraffic')));

    final backupRules = _read(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    );
    expect(backupRules, contains('<cloud-backup>'));
    expect(backupRules, contains('<device-transfer>'));
    expect(backupRules, contains('domain="sharedpref" path="."'));
    expect(backupRules, contains('domain="database" path="."'));
  });

  test('Android local HTTP is restricted to debug and profile builds', () {
    expect(
      _read('android/app/src/debug/AndroidManifest.xml'),
      contains('android:usesCleartextTraffic="true"'),
    );
    expect(
      _read('android/app/src/profile/AndroidManifest.xml'),
      contains('android:usesCleartextTraffic="true"'),
    );
  });

  test('iOS target and push capabilities are release-ready', () {
    final project = _read('ios/Runner.xcodeproj/project.pbxproj');
    final info = _read('ios/Runner/Info.plist');
    final entitlements = _read('ios/Runner/Runner.entitlements');

    // Project and Runner target each carry Debug, Profile and Release values.
    expect(_occurrences(project, 'IPHONEOS_DEPLOYMENT_TARGET = 15.0;'), 6);
    expect(
      _occurrences(
        project,
        'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;',
      ),
      3,
    );
    expect(info, contains('<key>UIBackgroundModes</key>'));
    expect(info, contains('<string>fetch</string>'));
    expect(info, contains('<string>remote-notification</string>'));
    expect(entitlements, contains('<key>aps-environment</key>'));
    expect(entitlements, contains(r'<string>$(APS_ENVIRONMENT)</string>'));
  });
}
