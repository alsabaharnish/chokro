import 'package:chokro/core/validators.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('validateEmail', () {
    test('accepts ordinary addresses', () {
      expect(validateEmail('arnish@lamppost.org.bd'), isNull);
      expect(validateEmail('a@b.co'), isNull);
      expect(validateEmail('first.last+tag@sub.example.com'), isNull);
    });

    test('trims before judging, so a trailing space is not a failure', () {
      expect(validateEmail('  arnish@lamppost.org.bd  '), isNull);
    });

    test('rejects what the old contains-@ check let through', () {
      // The whole reason this validator exists: every one of these passed the
      // previous `!v.contains('@')` test and was only refused by Firebase, one
      // network round trip later.
      expect(validateEmail('@'), isNotNull);
      expect(validateEmail('a@'), isNotNull);
      expect(validateEmail('@b.com'), isNotNull);
      expect(validateEmail('a@b'), isNotNull);
      expect(validateEmail('a@@b.com'), isNotNull);
      expect(validateEmail('a b@c.com'), isNotNull);
    });

    test('rejects a single-character final label', () {
      expect(validateEmail('a@b.c'), isNotNull);
    });

    test('asks for the field rather than complaining when it is empty', () {
      expect(validateEmail(''), 'Enter your email address');
      expect(validateEmail(null), 'Enter your email address');
      expect(validateEmail('   '), 'Enter your email address');
    });
  });

  group('validateNewPassword', () {
    test('accepts six characters, matching Firebase\'s own floor', () {
      expect(validateNewPassword('abcdef'), isNull);
    });

    test('counts down rather than restating the rule', () {
      // "2 more characters" is actionable; "minimum 6 characters" makes the user
      // count what they have typed.
      expect(validateNewPassword('abcd'), '2 more characters');
    });

    test('uses the singular for exactly one remaining', () {
      expect(validateNewPassword('abcde'), '1 more character');
    });

    test('asks for a password when empty', () {
      expect(validateNewPassword(''), 'Choose a password');
      expect(validateNewPassword(null), 'Choose a password');
    });

    test('does not trim — leading and trailing spaces are valid password characters', () {
      expect(validateNewPassword('   a  '), isNull);
    });
  });

  group('validateName', () {
    test('accepts a name', () {
      expect(validateName('Arnish'), isNull);
      expect(validateName('Al Sabah Arnish'), isNull);
    });

    test('a whitespace-only name is not a name', () {
      expect(validateName('   '), 'Enter your name');
    });

    test('rejects a single character', () {
      expect(validateName('A'), isNotNull);
    });

    test('accepts a name at exactly the stored ceiling', () {
      expect(validateName('a' * TextLimits.nameMax), isNull);
    });

    test('rejects a name longer than firestore.rules will store', () {
      // `validUser` caps `name` at 80. Without this check the form passed, the
      // Auth account was created, the profile write came back
      // permission-denied, and `AuthController.signUp` rolled the account back
      // — so the user saw a generic failure and could reproduce it forever.
      expect(validateName('a' * (TextLimits.nameMax + 1)), isNotNull);
    });
  });

  group('validateMinLength', () {
    test('accepts text at exactly the minimum', () {
      expect(validateMinLength('12345', 5, 'a description'), isNull);
    });

    test('names the subject when empty', () {
      expect(validateMinLength('', 20, 'a description'), 'Enter a description');
    });

    test('counts the shortfall on trimmed length', () {
      expect(validateMinLength('  abc  ', 5, 'a description'),
          '2 more characters');
    });

    test('accepts text at exactly the maximum', () {
      expect(
        validateMinLength('a' * 1000, 20, 'a description', maximum: 1000),
        isNull,
      );
    });

    test('reports how far over the ceiling the text runs', () {
      expect(
        validateMinLength('a' * 1002, 20, 'a description', maximum: 1000),
        '2 characters too many (limit 1000)',
      );
    });

    test('no maximum given means no ceiling, as before', () {
      expect(validateMinLength('a' * 5000, 20, 'a description'), isNull);
    });
  });

  group('TextLimits', () {
    // These are the numbers `firestore.rules` enforces. If a rule changes, the
    // matching constant has to change with it or a valid form produces a write
    // the database refuses without saying which field was wrong.
    test('mirror the bounds in firestore.rules', () {
      expect(TextLimits.nameMin, 2);
      expect(TextLimits.nameMax, 80);
      expect(TextLimits.businessNameMin, 2);
      expect(TextLimits.businessNameMax, 120);
      expect(TextLimits.applicationDescriptionMin, 20);
      expect(TextLimits.applicationDescriptionMax, 1000);
      expect(TextLimits.rejectionReasonMin, 10);
      expect(TextLimits.rejectionReasonMax, 500);
    });
  });
}
