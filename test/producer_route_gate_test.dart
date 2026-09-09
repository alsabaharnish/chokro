/// The producer portal's route policies (EPR-1, EPR-4, NFR-E-1).
///
/// These are the pure functions the gate is built from, kept outside GoRouter
/// precisely so role and suspension agreement can be asserted without
/// constructing Firebase-backed providers.
library;

import 'package:chokro/core/constants.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/routing/router.dart';
import 'package:flutter_test/flutter_test.dart';

UserModel _user(String role, {String status = AppConstants.statusActive}) =>
    UserModel(
      uid: 'uid-1',
      name: 'Test',
      email: 'test@example.com',
      role: role,
      status: status,
    );

void main() {
  group('canAccessProducerRoutes', () {
    test('an active producer passes', () {
      expect(canAccessProducerRoutes(_user(AppConstants.roleProducer)), isTrue);
    });

    test('a suspended producer does not', () {
      // The role alone is not authority: the rules and the server both refuse a
      // suspended account, so the route agrees rather than opening a workspace
      // whose every request will be denied.
      expect(
        canAccessProducerRoutes(
          _user(
            AppConstants.roleProducer,
            status: AppConstants.statusSuspended,
          ),
        ),
        isFalse,
      );
    });

    test('no citizen role passes, administrators included', () {
      for (final role in [
        AppConstants.roleAdmin,
        AppConstants.roleSeller,
        AppConstants.roleBuyer,
      ]) {
        expect(
          canAccessProducerRoutes(_user(role)),
          isFalse,
          reason: '$role must not open the producer workspace',
        );
      }
    });

    test('a producer does not gain the admin routes', () {
      expect(canAccessAdminRoutes(_user(AppConstants.roleProducer)), isFalse);
    });
  });

  group('homeFor', () {
    test('a producer goes to the producer workspace, not the citizen home', () {
      // `/home` for a producer is a screen offering a wallet, a shop and a bin
      // scanner, none of which the account can use.
      expect(homeFor(_user(AppConstants.roleProducer)), '/producer');
    });

    test('every citizen role keeps /home', () {
      for (final role in [
        AppConstants.roleAdmin,
        AppConstants.roleSeller,
        AppConstants.roleBuyer,
      ]) {
        expect(homeFor(_user(role)), '/home');
      }
    });
  });

  group('producerHomeRedirect', () {
    test('moves a producer off the citizen home', () {
      // `/home` is the router’s initialLocation, so a producer arrives there by
      // default rather than by asking.
      expect(
        producerHomeRedirect(_user(AppConstants.roleProducer)),
        '/producer',
      );
    });

    test('leaves everyone else alone', () {
      expect(producerHomeRedirect(_user(AppConstants.roleBuyer)), isNull);
      expect(producerHomeRedirect(_user(AppConstants.roleAdmin)), isNull);
    });
  });

  group('activeRouteRedirect', () {
    test('an active account is not redirected', () {
      expect(activeRouteRedirect(_user(AppConstants.roleProducer)), isNull);
      expect(activeRouteRedirect(_user(AppConstants.roleBuyer)), isNull);
    });

    test('a suspended producer is sent to the producer workspace', () {
      // Not `/home`. The workspace is where the suspension can be explained to
      // someone who has no citizen screens at all.
      expect(
        activeRouteRedirect(
          _user(
            AppConstants.roleProducer,
            status: AppConstants.statusSuspended,
          ),
        ),
        '/producer',
      );
    });

    test('a suspended citizen is still sent to /home', () {
      expect(
        activeRouteRedirect(
          _user(AppConstants.roleBuyer, status: AppConstants.statusSuspended),
        ),
        '/home',
      );
    });
  });

  group('sellerRouteRedirect', () {
    test('a producer is not sent to the seller application form', () {
      // A producer is not a Greenpreneur who has not applied yet — the roles
      // are disjoint, so the application form is the wrong destination and
      // would offer a citizen profile to a corporate account.
      expect(
        sellerRouteRedirect(_user(AppConstants.roleProducer)),
        '/producer',
      );
    });

    test('the citizen behaviour is unchanged', () {
      expect(sellerRouteRedirect(_user(AppConstants.roleSeller)), isNull);
      expect(sellerRouteRedirect(_user(AppConstants.roleAdmin)), isNull);
      expect(
        sellerRouteRedirect(_user(AppConstants.roleBuyer)),
        '/apply-seller',
      );
    });
  });

  group('the invitation route', () {
    test('has a stable path that the gate treats as an auth route', () {
      expect(invitationRedeemPath, '/join');
    });

    test('is not a bin link, so the acquisition path does not claim it', () {
      // `anonymousGateDestination` decides where an anonymous visitor to a
      // *non-auth* route is sent, and it sends bin QRs to /register because a
      // bin scan is a first-use acquisition path. An invitation is not: the
      // account is created by redeeming a token, not by filling in the
      // three-field form.
      //
      // The gate never consults this function for `/join`, because it lists
      // `/join` among the auth routes — locations an anonymous visitor is
      // supposed to be. This asserts the other half: that if that listing were
      // ever removed, `/join` would not silently fall into the registration
      // path and lose its token.
      expect(
        anonymousGateDestination(
          invitationRedeemPath,
          sessionJustEnded: false,
        ),
        isNot('/register'),
      );
    });

    test('the full location including the token survives restoration', () {
      // `state.uri`, not `matchedLocation`: the latter drops the query string,
      // and /join without its token is a form with nothing to redeem.
      expect(
        restorableRouteLocation(Uri.parse('/join?token=abc123')),
        '/join?token=abc123',
      );
    });
  });
}
