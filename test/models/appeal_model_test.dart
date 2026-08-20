import 'package:chokro/models/appeal_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('create payload matches the key set in firestore.rules', () {
    test('carries exactly the allowed keys and no timestamp', () {
      const appeal = AppealModel(
        userId: 'u',
        subjectType: AppealSubject.disposal,
        subjectId: 'd1',
        message: 'The photograph clearly shows six bottles at the bin.',
      );

      expect(appeal.toCreateJson().keys.toSet(), {
        'userId',
        'subjectType',
        'subjectId',
        'message',
        'status',
      });
      expect(appeal.toCreateJson()['status'], 'pending');
      expect(appeal.documentId, 'u_disposal_d1');
      expect(appeal.subjectKey, 'disposal:d1');
    });

    test('trims the message it writes', () {
      const appeal = AppealModel(
        userId: 'u',
        subjectType: AppealSubject.claim,
        subjectId: 'c1',
        message: '   I planted the sapling on the date shown.   ',
      );

      expect(
        appeal.toCreateJson()['message'],
        'I planted the sapling on the date shown.',
      );
    });
  });

  group('status parsing', () {
    test('reads its own stored names', () {
      expect(AppealStatus.fromName('upheld'), AppealStatus.upheld);
      expect(AppealStatus.fromName('declined'), AppealStatus.declined);
    });

    test('an unrecognised status reads as still awaiting review', () {
      expect(AppealStatus.fromName('resolved'), AppealStatus.pending);
      expect(AppealStatus.fromName(null), AppealStatus.pending);
    });
  });

  group('subject parsing', () {
    test('rejects a subject outside the vocabulary', () {
      expect(AppealSubject.fromName('order'), isNull);
    });

    test('an unparseable subject falls back to disposal on read', () {
      final appeal = AppealModel.fromMap({'subjectType': 'order'});
      expect(appeal.subjectType, AppealSubject.disposal);
    });

    test('wrongly typed stored fields fail closed instead of throwing', () {
      final appeal = AppealModel.fromMap({
        'userId': 7,
        'subjectType': <String>['claim'],
        'message': false,
        'status': 99,
        'response': <String, dynamic>{},
      });

      expect(appeal.userId, isEmpty);
      expect(appeal.subjectType, AppealSubject.disposal);
      expect(appeal.message, isEmpty);
      expect(appeal.status, AppealStatus.pending);
      expect(appeal.response, isNull);
    });
  });

  group('validation mirrors the rules bounds', () {
    test('refuses an empty or too-short case', () {
      expect(AppealModel.validateMessage(''), isNotNull);
      expect(AppealModel.validateMessage('too short'), isNotNull);
    });

    test('accepts a message at the minimum length', () {
      expect(AppealModel.validateMessage('a' * AppealModel.messageMin), isNull);
    });

    test('refuses a message past the maximum', () {
      expect(
        AppealModel.validateMessage('a' * (AppealModel.messageMax + 1)),
        isNotNull,
      );
    });

    test('an administrator cannot resolve with an empty answer', () {
      expect(AppealModel.validateResponse(''), isNotNull);
      expect(AppealModel.validateResponse('  '), isNotNull);
      expect(
        AppealModel.validateResponse('a' * AppealModel.responseMin),
        isNull,
      );
    });
  });
}
