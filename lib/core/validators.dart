/// Form validators, shared so the same field is judged the same way everywhere.
///
/// The login and register screens each carried their own copy of
/// `v == null || !v.contains('@') ? 'Enter a valid email' : null`, which accepts
/// `@`, `a@`, and `@@@` — so the first real feedback a user got was a
/// `invalid-email` round trip to Firebase.
///
/// No Flutter import, so these are unit-testable directly. Each returns null
/// when the value is acceptable and a message to display otherwise, matching
/// `FormFieldValidator`'s contract.
library;

/// Deliberately permissive: one or more non-space, non-`@` characters, an `@`,
/// a dotted domain with a 2+ character final label.
///
/// Validating email exactly is famously not worth attempting — the grammar in
/// RFC 5322 admits addresses no provider would issue, and any regex strict
/// enough to be "correct" rejects valid ones. The only authority on whether an
/// address works is whether mail reaches it. This catches typing mistakes,
/// which is all a form field should try to do.
final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s.]+(\.[^@\s.]+)*\.[^@\s.]{2,}$');

String? validateEmail(String? value) {
  final email = value?.trim() ?? '';
  if (email.isEmpty) return 'Enter your email address';
  if (!_emailPattern.hasMatch(email)) {
    return 'That does not look like an email address';
  }
  return null;
}

/// Firebase Auth's own floor is six characters and it rejects anything shorter
/// with `weak-password`. Checking here means the user is told before a round
/// trip, and told in terms of what to do.
String? validateNewPassword(String? value) {
  final password = value ?? '';
  if (password.isEmpty) return 'Choose a password';
  if (password.length < 6) {
    final needed = 6 - password.length;
    return '$needed more character${needed == 1 ? '' : 's'}';
  }
  return null;
}

/// Upper bounds on free-text fields, duplicated from `firestore.rules`.
///
/// ## Why the maxima have to be here as well
///
/// Rules pin an exact length on every stored string — `validString(u.name, 2,
/// 80)`, `validString(a.businessName, 2, 120)`, `validString(a.description, 20,
/// 1000)` — and a write that breaks one is refused with a bare
/// `permission-denied` that cannot say which field was wrong. Only the minima
/// were checked on this side, so an over-long value passed the form, reached
/// Firestore, and came back as a failure the user could neither read nor act
/// on. On the registration path it was worse than a refusal: the Auth account
/// is created first, so the profile write failing rolled the account back and
/// the user was told, generically, to try again — which reproduced it exactly.
///
/// Any change here must be made in `firestore.rules` too, the same contract
/// `ProductLimits` already documents for the marketplace bounds.
class TextLimits {
  const TextLimits._();

  /// `users.name`.
  static const int nameMin = 2;
  static const int nameMax = 80;

  /// `sellerApplications.businessName`.
  static const int businessNameMin = 2;
  static const int businessNameMax = 120;

  /// `sellerApplications.description`.
  static const int applicationDescriptionMin = 20;
  static const int applicationDescriptionMax = 1000;

  /// `sellerApplications.reason`, the tightest of the rejection reasons and so
  /// the one the shared dialog is bounded by.
  static const int rejectionReasonMin = 10;
  static const int rejectionReasonMax = 500;
}

/// A display name. Trimmed, because ' ' is not a name.
String? validateName(String? value) {
  final name = value?.trim() ?? '';
  if (name.isEmpty) return 'Enter your name';
  if (name.length < TextLimits.nameMin) {
    return 'That is too short to be a name';
  }
  if (name.length > TextLimits.nameMax) {
    return 'Names are limited to ${TextLimits.nameMax} characters';
  }
  return null;
}

/// Free text with a minimum useful length, used for the seller application's
/// description and anywhere else a one-word answer is not an answer.
///
/// [maximum] mirrors the ceiling `firestore.rules` enforces on the same field —
/// see [TextLimits]. It is optional only so existing callers that have no stored
/// ceiling keep working; anything written to Firestore should pass it.
String? validateMinLength(
  String? value,
  int minimum,
  String subject, {
  int? maximum,
}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return 'Enter $subject';
  if (text.length < minimum) {
    final needed = minimum - text.length;
    return '$needed more character${needed == 1 ? '' : 's'}';
  }
  if (maximum != null && text.length > maximum) {
    final over = text.length - maximum;
    return '$over character${over == 1 ? '' : 's'} too many (limit $maximum)';
  }
  return null;
}
