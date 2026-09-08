import 'dart:io';
import 'dart:convert';

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

  test('Android claims only the hosted bin-entry path', () {
    final manifest = _read('android/app/src/main/AndroidManifest.xml');

    expect(manifest, contains('android:autoVerify="true"'));
    expect(manifest, contains('android:host="chokro-30887.web.app"'));
    expect(manifest, contains('android:pathPrefix="/b/"'));
    expect(manifest, contains('flutter_deeplinking_enabled'));

    final association =
        jsonDecode(_read('web/assetlinks.json')) as List<dynamic>;
    final target = association.single['target'] as Map<String, dynamic>;
    expect(target['package_name'], 'com.arnish.chokro');
    expect(target['sha256_cert_fingerprints'], isNotEmpty);
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
    expect(info, contains('<key>FlutterDeepLinkingEnabled</key>'));
    expect(project, contains('com.apple.AssociatedDomains'));
    expect(
      entitlements,
      contains('<string>applinks:chokro-30887.web.app</string>'),
    );

    final association =
        jsonDecode(_read('web/apple-app-site-association'))
            as Map<String, dynamic>;
    final details =
        (association['applinks'] as Map<String, dynamic>)['details']
            as List<dynamic>;
    expect(details.single['appID'], 'UDBARM7GH7.com.arnish.chokro');
    expect(details.single['paths'], contains('/b/*'));
  });

  test('Firebase Hosting serves association files before the SPA fallback', () {
    final config = jsonDecode(_read('firebase.json')) as Map<String, dynamic>;
    final hosting = config['hosting'] as Map<String, dynamic>;
    final main = _read('lib/main.dart');
    final pubspec = _read('pubspec.yaml');
    final webIndex = _read('web/index.html');
    final headers = hosting['headers'] as List<dynamic>;

    expect(
      headers.map((entry) => entry['source']),
      containsAll([
        '/.well-known/assetlinks.json',
        '/.well-known/apple-app-site-association',
      ]),
    );
    final rewrites = hosting['rewrites'] as List<dynamic>;
    expect(
      rewrites.map((entry) => entry['source']),
      containsAll([
        '/.well-known/assetlinks.json',
        '/.well-known/apple-app-site-association',
        '**',
      ]),
    );
    expect(rewrites.last['destination'], '/index.html');
    expect(main, contains('usePathUrlStrategy();'));
    expect(pubspec, contains('flutter_web_plugins:'));
    expect(webIndex, contains("window.location.hash.startsWith('#/')"));
  });
}
