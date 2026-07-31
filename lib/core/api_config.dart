/// Where the trusted service lives.
///
/// Everything that decides a payout runs there, not here — see §5.1 of the
/// project brief. The client calls it for photo upload now, and for submission
/// verification once that endpoint exists.
class ApiConfig {
  const ApiConfig._();

  /// Deployed service. Override at build time for local development:
  ///
  ///   flutter run --dart-define=CHOKRO_API=http://10.0.2.2:8787
  ///
  /// Note `10.0.2.2` rather than `localhost` on the Android emulator — the
  /// emulator's localhost is the emulator itself. On a physical device, use the
  /// Mac's LAN address instead.
  static const String baseUrl = String.fromEnvironment(
    'CHOKRO_API',
    defaultValue: 'https://chokro.onrender.com',
  );

  static Uri path(String suffix) => Uri.parse('$baseUrl$suffix');

  /// Render's free instance sleeps after roughly 15 minutes idle and takes
  /// 30–60 seconds to wake. Requests must outlast that or the first submission
  /// after a quiet period fails for no good reason.
  static const Duration coldStartTimeout = Duration(seconds: 90);
}
