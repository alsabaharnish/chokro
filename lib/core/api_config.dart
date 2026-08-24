import 'package:flutter/foundation.dart' show kIsWeb;

/// Where the trusted service lives.
///
/// Everything that decides a payout runs there, not here — see §5.1 of the
/// project brief. The client calls it for photo upload now, and for submission
/// verification once that endpoint exists.
class ApiConfig {
  const ApiConfig._();

  /// Deployed service. Override at build time for local development, with the
  /// address that means "this Mac" **on the target you are running**:
  ///
  ///   # Flutter web, iOS simulator, macOS
  ///   flutter run -d chrome --dart-define=CHOKRO_API=http://localhost:8787
  ///
  ///   # Android emulator — its own localhost is the emulator itself
  ///   flutter run -d emulator-5554 --dart-define=CHOKRO_API=http://10.0.2.2:8787
  ///
  ///   # Physical device — the Mac's LAN address
  ///   flutter run --dart-define=CHOKRO_API=http://192.168.1.20:8787
  ///
  /// The web line is first deliberately. This comment used to show only the
  /// `10.0.2.2` form, which is meaningless to a browser, and copying it into a
  /// `-d chrome` run produces a bare `ClientException: Failed to fetch` with no
  /// hint that the address is the problem. See [configurationWarning].
  static const String baseUrl = String.fromEnvironment(
    'CHOKRO_API',
    defaultValue: 'https://chokro.onrender.com',
  );

  static Uri path(String suffix) => Uri.parse('$baseUrl$suffix');

  /// Hosts that only resolve inside an Android emulator.
  ///
  /// `10.0.2.2` is the standard AVD alias for the host machine's loopback;
  /// `10.0.3.2` is Genymotion's. Neither means anything anywhere else.
  static const Set<String> _androidEmulatorHosts = {'10.0.2.2', '10.0.3.2'};

  /// A description of a base URL that cannot work on this platform, or null.
  ///
  /// Only one case is detectable with certainty, and it is the one that costs
  /// the most time: an Android-emulator alias on the web build. Every request
  /// then fails in the browser's network stack before CORS is even evaluated,
  /// so the error says `Failed to fetch` and points at nothing.
  ///
  /// Deliberately not auto-corrected to `localhost`. Silently rewriting a
  /// configured endpoint would hide a misconfiguration rather than fix it, and
  /// this value decides which server sees authenticated calls.
  /// Whether [url] names a host only an Android emulator can resolve.
  ///
  /// Split out from [configurationWarning] so the decision is testable:
  /// `kIsWeb` is a compile-time constant that a VM test cannot fake, so a test
  /// of the getter alone can only ever exercise the "not web" branch and would
  /// pass however wrong this matching was.
  static bool isAndroidEmulatorHost(String url) =>
      _androidEmulatorHosts.contains(Uri.tryParse(url)?.host);

  static String? get configurationWarning {
    if (!kIsWeb || !isAndroidEmulatorHost(baseUrl)) return null;
    return 'CHOKRO_API is set to $baseUrl, which is an Android-emulator '
        'address for the host machine. A browser cannot reach it, so every '
        'call to the trusted service will fail with "Failed to fetch". '
        'Re-run with --dart-define=CHOKRO_API=http://localhost:8787';
  }

  /// Render's free instance sleeps after roughly 15 minutes idle and takes
  /// 30–60 seconds to wake. Requests must outlast that or the first submission
  /// after a quiet period fails for no good reason.
  static const Duration coldStartTimeout = Duration(seconds: 90);
}
