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

/// A display name. Trimmed, because ' ' is not a name.
String? validateName(String? value) {
  final name = value?.trim() ?? '';
  if (name.isEmpty) return 'Enter your name';
  if (name.length < 2) return 'That is too short to be a name';
  return null;
}

/// Free text with a minimum useful length, used for the seller application's
/// description and anywhere else a one-word answer is not an answer.
String? validateMinLength(String? value, int minimum, String subject) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return 'Enter $subject';
  if (text.length < minimum) {
    final needed = minimum - text.length;
    return '$needed more character${needed == 1 ? '' : 's'}';
  }
  return null;
}
