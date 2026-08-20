/// Defensive readers for JSON returned by the trusted HTTP service.
///
/// A successful status code is not proof that a proxy, stale deployment or
/// partial response returned the expected field types. These helpers keep that
/// boundary from leaking `TypeError` into the UI.
library;

String? wireString(Object? value) => value is String ? value : null;

int? wireInt(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return null;
}
