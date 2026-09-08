/// The public link printed in every Chokro bin QR code.
///
/// Firestore keeps the opaque `chokro:bin:…` token as the bin lookup key. The
/// printed code wraps that token in an HTTPS URL so the operating system can
/// open the installed app, while a phone without the app receives the same
/// disposal flow from Firebase Hosting.
class BinLink {
  const BinLink._();

  /// Override for a custom production domain, for example:
  ///
  /// `--dart-define=CHOKRO_WEB_URL=https://chokro.example.org`
  static const String publicBaseUrl = String.fromEnvironment(
    'CHOKRO_WEB_URL',
    defaultValue: 'https://chokro-30887.web.app',
  );

  /// A universal/app-link origin must be a clean HTTPS origin: native
  /// associated-domain declarations cannot include credentials, ports, query
  /// strings, fragments, or a base path.
  static bool isValidPublicBaseUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    return uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasPort &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        (uri.path.isEmpty || uri.path == '/');
  }

  /// Fails the build configuration before it can print a dead QR label.
  static void validateConfiguration() => _baseUri();

  static Uri forPayload(String payload) {
    final base = _baseUri();
    return base.replace(pathSegments: ['b', payload]);
  }

  /// Accepts both generations of Chokro labels.
  ///
  /// Older labels contain the token directly. New labels contain this app's
  /// HTTPS entry URL. Restricting URL extraction to the configured host keeps a
  /// lookalike domain from being presented as a valid Chokro code.
  static String? payloadFromScannedValue(String value) {
    final trimmed = value.trim();
    if (_isPayload(trimmed)) return trimmed;

    final uri = Uri.tryParse(trimmed);
    if (uri == null || !isValidPublicBaseUrl(publicBaseUrl)) return null;
    final base = Uri.parse(publicBaseUrl);
    if (uri.scheme != 'https' ||
        uri.host != base.host ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }

    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (segments.length != 2 || segments.first != 'b') return null;

    final payload = segments.last;
    return _isPayload(payload) ? payload : null;
  }

  /// Current server allocations are 12 lowercase hex characters. The broader
  /// safe suffix intentionally retains compatibility with labels created by
  /// older/demo data (`seed_bin_merul`, short test identifiers, and similar)
  /// without accepting whitespace, slashes, query syntax, or an unbounded
  /// Firestore lookup value.
  static bool _isPayload(String value) =>
      RegExp(r'^chokro:bin:[A-Za-z0-9_-]{1,64}$').hasMatch(value);

  static Uri _baseUri() {
    if (!isValidPublicBaseUrl(publicBaseUrl)) {
      throw StateError(
        'CHOKRO_WEB_URL must be a clean HTTPS origin without a port, path, '
        'query, fragment, or credentials.',
      );
    }
    return Uri.parse(publicBaseUrl);
  }
}
