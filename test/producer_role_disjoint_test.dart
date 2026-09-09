/// The producer role is disjoint from the citizen hierarchy (EPR-1, EPR-2).
///
/// Every assertion here exists because the failure it prevents is silent. The
/// inclusive fallback in `accountProfilesForRole` returns Champion, and
/// `UserModel.isChampion` used to return an unconditional `true` — so a
/// producer role added without touching either would have compiled, run, and
/// handed a corporate compliance account a points wallet.
library;

import 'package:chokro/controllers/account_profile_controller.dart';
import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/core/account_profile.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/models/user_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

UserModel _user(String role, {String status = AppConstants.statusActive}) =>
    UserModel(
      uid: 'uid-producer',
      name: 'Compliance Officer',
      email: 'compliance@example.com',
      role: role,
      status: status,
    );

void main() {
  group('wire values', () {
    test('the producer role keeps its stored value and its label', () {
      expect(AppConstants.roleProducer, 'producer');
      expect(
        AppConstants.roleLabel(AppConstants.roleProducer),
        'EPR Producer',
      );
    });

    test('org roles, statuses and gazette values are the stored strings', () {
      expect(OrgRoles.owner, 'orgOwner');
      expect(OrgRoles.reporter, 'orgReporter');
      expect(OrgRoles.viewer, 'orgViewer');
      expect(OrgMemberStatus.invited, 'invited');
      expect(OrgMemberStatus.active, 'active');
      expect(OrgMemberStatus.removed, 'removed');
      expect(OrgStatus.pendingReview, 'pendingReview');
      expect(OrgSizeClass.large, 'large');
      expect(ComplianceRoute.self, 'self');
    });
  });

  group('profiles held', () {
    test('a producer holds the producer profile and nothing else', () {
      expect(accountProfilesForRole(AppConstants.roleProducer), [
        AccountProfile.producer,
      ]);
      expect(
        defaultAccountProfileForRole(AppConstants.roleProducer),
        AccountProfile.producer,
      );
    });

    test('a producer does not hold the Champion profile', () {
      // The specific failure this guards: the `_ =>` fallback in
      // `accountProfilesForRole` returns Champion, so a producer that reached
      // it would be handed a wallet by inheritance (EPR-1).
      expect(
        roleHoldsAccountProfile(
          AppConstants.roleProducer,
          AccountProfile.champion,
        ),
        isFalse,
      );
      expect(
        roleHoldsAccountProfile(
          AppConstants.roleProducer,
          AccountProfile.greenpreneur,
        ),
        isFalse,
      );
      expect(
        roleHoldsAccountProfile(
          AppConstants.roleProducer,
          AccountProfile.admin,
        ),
        isFalse,
      );
    });

    test('no citizen role holds the producer profile', () {
      for (final role in [
        AppConstants.roleAdmin,
        AppConstants.roleSeller,
        AppConstants.roleBuyer,
      ]) {
        expect(
          roleHoldsAccountProfile(role, AccountProfile.producer),
          isFalse,
          reason: '$role must not reach the producer workspace',
        );
      }
    });

    test('an unknown role still fails closed to Champion, not to producer', () {
      expect(accountProfilesForRole('something-new'), [
        AccountProfile.champion,
      ]);
    });

    test('roleIsProducer names the disjoint role and only that role', () {
      expect(roleIsProducer(AppConstants.roleProducer), isTrue);
      expect(roleIsProducer(AppConstants.roleAdmin), isFalse);
      expect(roleIsProducer(AppConstants.roleBuyer), isFalse);
      expect(roleIsProducer(''), isFalse);
    });
  });

  group('UserModel capability', () {
    test('a producer is not a Champion, Greenpreneur or Admin', () {
      final producer = _user(AppConstants.roleProducer);
      expect(producer.isProducer, isTrue);
      expect(producer.isChampion, isFalse);
      expect(producer.isGreenpreneur, isFalse);
      expect(producer.isSeller, isFalse);
      expect(producer.isAdmin, isFalse);
    });

    test('the citizen hierarchy is unchanged by the new role', () {
      final admin = _user(AppConstants.roleAdmin);
      expect(admin.isAdmin, isTrue);
      expect(admin.isGreenpreneur, isTrue);
      expect(admin.isChampion, isTrue);
      expect(admin.isProducer, isFalse);

      final seller = _user(AppConstants.roleSeller);
      expect(seller.isAdmin, isFalse);
      expect(seller.isGreenpreneur, isTrue);
      expect(seller.isChampion, isTrue);

      final buyer = _user(AppConstants.roleBuyer);
      expect(buyer.isGreenpreneur, isFalse);
      expect(buyer.isChampion, isTrue);
    });

    test('suspension applies to a producer exactly as to any account', () {
      final suspended = _user(
        AppConstants.roleProducer,
        status: AppConstants.statusSuspended,
      );
      expect(suspended.isActive, isFalse);
      expect(suspended.isProducer, isTrue);
    });

    test('a malformed role document does not become a producer', () {
      // `fromMap` falls back to buyer, and buyer is not a producer. A permissive
      // fallback here would let an unreadable document open a compliance
      // workspace.
      final parsed = UserModel.fromMap(
        <String, dynamic>{'role': 42},
        uid: 'uid-1',
      );
      expect(parsed.isProducer, isFalse);
      expect(parsed.role, AppConstants.roleBuyer);
    });
  });

  group('profile selection', () {
    test('a producer cannot select a Champion workspace', () {
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWithValue(
            AsyncData(_user(AppConstants.roleProducer)),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(activeAccountProfileProvider),
        AccountProfile.producer,
      );

      // EPR-2: selecting a profile never grants a role. The request is refused
      // and the active profile does not move.
      container
          .read(accountProfileControllerProvider.notifier)
          .select(AccountProfile.champion);

      expect(
        container.read(activeAccountProfileProvider),
        AccountProfile.producer,
      );
    });

    test('a Champion cannot select the producer workspace', () {
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWithValue(
            AsyncData(_user(AppConstants.roleBuyer)),
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(accountProfileControllerProvider.notifier)
          .select(AccountProfile.producer);

      expect(
        container.read(activeAccountProfileProvider),
        AccountProfile.champion,
      );
    });
  });

  group('OrgRoles.atLeast', () {
    test('owner outranks reporter outranks viewer', () {
      expect(OrgRoles.atLeast(OrgRoles.owner, OrgRoles.viewer), isTrue);
      expect(OrgRoles.atLeast(OrgRoles.owner, OrgRoles.reporter), isTrue);
      expect(OrgRoles.atLeast(OrgRoles.owner, OrgRoles.owner), isTrue);
      expect(OrgRoles.atLeast(OrgRoles.reporter, OrgRoles.viewer), isTrue);
      expect(OrgRoles.atLeast(OrgRoles.reporter, OrgRoles.owner), isFalse);
      expect(OrgRoles.atLeast(OrgRoles.viewer, OrgRoles.reporter), isFalse);
    });

    test('an unrecognised role satisfies nothing', () {
      // Fail closed. A membership document written by a later release must
      // grant no capability in this build rather than an unbounded one.
      expect(OrgRoles.atLeast('orgSuperuser', OrgRoles.viewer), isFalse);
      expect(OrgRoles.atLeast(OrgRoles.owner, 'orgSuperuser'), isFalse);
      expect(OrgRoles.atLeast('', OrgRoles.viewer), isFalse);
    });
  });
}
