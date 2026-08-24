import 'package:chokro/core/api_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the default endpoint is the deployed service', () {
    // No --dart-define in a test run, so this exercises the fallback.
    expect(ApiConfig.baseUrl, 'https://chokro.onrender.com');
  });

  test('paths are appended to the base URL', () {
    expect(
      ApiConfig.path('/health'),
      Uri.parse('https://chokro.onrender.com/health'),
    );
  });

  test('a deployed URL raises no configuration warning', () {
    // The suite runs on the Dart VM, where `kIsWeb` is false, so this is the
    // "not web" branch. The Android-emulator case is covered by the analyser
    // of the string itself below — a widget test cannot fake `kIsWeb`.
    expect(ApiConfig.configurationWarning, isNull);
  });

  group('the emulator-address guard', () {
    test('matches the AVD and Genymotion host aliases, on any port', () {
      // `10.0.2.2` is the standard AVD alias for the host machine's loopback,
      // `10.0.3.2` is Genymotion's. Neither resolves in a browser, which is the
      // whole failure this catches.
      expect(ApiConfig.isAndroidEmulatorHost('http://10.0.2.2:8787'), isTrue);
      expect(ApiConfig.isAndroidEmulatorHost('http://10.0.3.2:8787'), isTrue);
      expect(ApiConfig.isAndroidEmulatorHost('http://10.0.2.2'), isTrue);
      expect(ApiConfig.isAndroidEmulatorHost('https://10.0.2.2:443/x'), isTrue);
    });

    test('leaves every address a browser can actually reach alone', () {
      for (final url in [
        'http://localhost:8787',
        'http://127.0.0.1:8787',
        'https://chokro.onrender.com',
        'http://192.168.1.20:8787',
      ]) {
        expect(ApiConfig.isAndroidEmulatorHost(url), isFalse, reason: url);
      }
    });

    test('does not match a host that merely contains the alias', () {
      // Substring matching here would be a false alarm on a real deployment.
      expect(
        ApiConfig.isAndroidEmulatorHost('https://10.0.2.2.example.com'),
        isFalse,
      );
      expect(
        ApiConfig.isAndroidEmulatorHost('https://api.io/10.0.2.2'),
        isFalse,
      );
    });

    test('an unparseable value is not reported as an emulator address', () {
      expect(ApiConfig.isAndroidEmulatorHost(''), isFalse);
      expect(ApiConfig.isAndroidEmulatorHost('::::'), isFalse);
    });
  });
}
