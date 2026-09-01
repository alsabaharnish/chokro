import 'package:chokro/services/push_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FCM token is retired when the Firestore delete fails', () async {
    var tokenRetired = false;
    final failures = <String>[];

    await retirePushRegistration(
      deleteRegistration: () async => throw StateError('offline'),
      deleteMessagingToken: () async => tokenRetired = true,
      onFailure: (step, _) => failures.add(step),
    );

    expect(tokenRetired, isTrue);
    expect(failures, ['device registration']);
  });

  test('Firestore cleanup is attempted when FCM retirement fails', () async {
    var registrationDeleted = false;
    final failures = <String>[];

    await retirePushRegistration(
      deleteRegistration: () async => registrationDeleted = true,
      deleteMessagingToken: () async => throw StateError('FCM unavailable'),
      onFailure: (step, _) => failures.add(step),
    );

    expect(registrationDeleted, isTrue);
    expect(failures, ['messaging token']);
  });
}
