import 'dart:async';

import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/services/user_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Registration that never finishes (F1.1).
///
/// Offline persistence is enabled app-wide, which makes `WriteBatch.commit()`
/// resolve on the *server's* acknowledgement rather than on the local write. On
/// a connection that never delivers it therefore neither returns nor throws, and
/// registration awaits it: the button spun forever, the rollback in `signUp`'s
/// `catch` never ran, and `authControllerProvider` stayed `AsyncLoading` — the
/// flag `AppShell`, `StartupErrorView` and `AccountIncompleteView` all read to
/// disable sign-out. A stalled registration locked every way out of the account
/// it had half-created.
///
/// `push_service.dart` documents the identical trap for an offline delete and
/// bounds it. These are the same guarantee for the registration path.
void main() {
  group('the profile write is bounded', () {
    test('a commit that never acknowledges gives up', () {
      // The unacknowledged write, exactly: a Future with no completion.
      expect(
        UserService.commitRegistration(
          () => Completer<void>().future,
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a commit that lands inside the deadline is untouched', () async {
      var committed = false;
      await UserService.commitRegistration(() async {
        committed = true;
      }, timeout: const Duration(seconds: 5));

      expect(committed, isTrue);
    });

    test('a rejected commit still reports its own failure', () {
      // The deadline must not swallow the reason. A rules refusal has to reach
      // `signUp`'s catch as itself, so the rollback runs and the message names
      // the real cause.
      expect(
        UserService.commitRegistration(
          () async => throw StateError('permission-denied'),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('the shipped deadline is finite and generous', () {
      // Named rather than asserted exactly: the value is a judgement, but an
      // unbounded one is the bug this file exists for, and anything under ten
      // seconds fails registrations on a roadside connection that would have
      // succeeded.
      expect(
        UserService.registrationTimeout,
        greaterThanOrEqualTo(const Duration(seconds: 10)),
      );
      expect(UserService.registrationTimeout, isA<Duration>());
    });
  });

  group('RegistrationInFlight', () {
    ProviderContainer container() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('nothing is in flight by default', () {
      expect(container().read(registrationInFlightProvider), isFalse);
    });

    test('begin raises it and end lowers it', () {
      final c = container();
      c.read(registrationInFlightProvider.notifier).begin();
      expect(c.read(registrationInFlightProvider), isTrue);

      c.read(registrationInFlightProvider.notifier).end();
      expect(c.read(registrationInFlightProvider), isFalse);
    });

    test('the flag is observable, not just readable', () {
      // The router's gate listens to this to re-run its redirects. A change
      // nothing is notified of is a redirect pass that never happens, which is
      // what would strand a failed registration on a form the gate holds shut.
      final c = container();
      final seen = <bool>[];
      c.listen(registrationInFlightProvider, (_, next) => seen.add(next));

      c.read(registrationInFlightProvider.notifier).begin();
      c.read(registrationInFlightProvider.notifier).end();

      expect(seen, [true, false]);
    });
  });
}
