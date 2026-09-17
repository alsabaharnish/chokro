/// No user-facing string tells somebody to make contact without saying how.
///
/// The product had four of these — "Contact a 3ZERO Admin", naming no address
/// — and the document that catalogued the problem recorded three, because the
/// fourth lived in a widget no test touched and no inventory found. Counting
/// them by hand is how the fourth was missed; this counts them on every run.
///
/// Two of the four are shown to somebody who CANNOT SIGN IN, where an unnamed
/// contact is not an inconvenience but the end of the road: a disabled account
/// never reaches a screen where an address could be found later.
///
/// Erasure requests are email-only by decision (16 September 2026), which is
/// defensible only while the address is reachable from inside the product. A
/// regression here is not a cosmetic one — it removes the only door.
library;

import 'dart:io';

import 'package:chokro/core/constants.dart';
import 'package:flutter_test/flutter_test.dart';

/// Source with comments removed, so prose ABOUT the phrase does not read as a
/// use of it — including the explanatory comments left at each call site.
String _code(String source) {
  return source
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .split('\n')
      .map((line) {
        final comment = line.indexOf('//');
        if (comment < 0) return line;
        // Crude on purpose: a `//` inside a string literal would truncate the
        // line early. That can only cause this test to look at LESS text, and
        // the phrases below never appear near a URL, so the failure direction
        // is a missed catch rather than a false alarm — and the exact-phrase
        // assertions are checked against the full source separately.
        return line.substring(0, comment);
      })
      .join('\n');
}

void main() {
  final dartFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('lib/ is not empty, so a passing run means something', () {
    // Guards the assertions below: a glob that matched nothing would pass
    // every check in this file while proving nothing at all.
    expect(dartFiles.length, greaterThan(50));
  });

  test('nothing tells a reader to contact an admin without naming how', () {
    // Matches the instruction, not the label. "Attributed by a 3ZERO Admin"
    // and `roleAdminLabel` are descriptions of who did something; this is the
    // imperative that sends somebody looking for a door.
    final instruction = RegExp(
      r'[Cc]ontact\s+(a|an|the)?\s*3ZERO\s+Admin',
    );

    final offenders = <String>[];
    for (final file in dartFiles) {
      final code = _code(file.readAsStringSync());
      if (instruction.hasMatch(code)) offenders.add(file.path);
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These tell somebody to make contact and name no way to do it. Use '
          'AppConstants.contactEmail:\n  ${offenders.join('\n  ')}',
    );
  });

  test('the contact address is a real address held in one place', () {
    // It is the data-protection contact of record and appears in consent text
    // people have already agreed to, so a placeholder or a typo here is a
    // promise the product cannot keep.
    expect(AppConstants.contactEmail, matches(RegExp(r'^[^@\s]+@[^@\s]+\.[a-z]{2,}$')));
    expect(AppConstants.contactEmail, isNot(contains('[')));
    expect(AppConstants.contactEmail, isNot(contains('example')));

    // Written once and referenced, never re-typed. A second literal is how the
    // app and the consent text drift apart about an address somebody has
    // already been told to write to.
    final literals = dartFiles
        .where((f) => !f.path.endsWith('core/constants.dart'))
        .where((f) => f.readAsStringSync().contains(AppConstants.contactEmail))
        .map((f) => f.path)
        .toList();

    expect(
      literals,
      isEmpty,
      reason:
          'The address is hard-coded here instead of referencing '
          'AppConstants.contactEmail:\n  ${literals.join('\n  ')}',
    );
  });
}
