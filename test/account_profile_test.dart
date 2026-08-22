import 'package:chokro/controllers/account_profile_controller.dart';
import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/core/account_profile.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/models/user_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

UserModel _user(String role) => UserModel(
  uid: 'uid-1',
  name: 'Nabil',
  email: 'nabil@example.com',
  role: role,
  status: AppConstants.statusActive,
);

ProviderContainer _container(String role) => ProviderContainer(
  overrides: [currentUserProvider.overrideWithValue(AsyncData(_user(role)))],
);

void main() {
  test('the branded role labels keep database wire values unchanged', () {
    expect(AppConstants.roleAdmin, 'admin');
    expect(AppConstants.roleSeller, 'seller');
    expect(AppConstants.roleBuyer, 'buyer');
    expect(AppConstants.roleLabel(AppConstants.roleAdmin), '3ZERO Admin');
    expect(
      AppConstants.roleLabel(AppConstants.roleSeller),
      '3ZERO Greenpreneur',
    );
    expect(AppConstants.roleLabel(AppConstants.roleBuyer), '3ZERO Champion');
  });

  test('Admin holds all three profiles and defaults to Admin', () {
    expect(accountProfilesForRole(AppConstants.roleAdmin), [
      AccountProfile.admin,
      AccountProfile.greenpreneur,
      AccountProfile.champion,
    ]);
    expect(
      defaultAccountProfileForRole(AppConstants.roleAdmin),
      AccountProfile.admin,
    );
  });

  test('Greenpreneur also holds Champion and defaults to Greenpreneur', () {
    expect(accountProfilesForRole(AppConstants.roleSeller), [
      AccountProfile.greenpreneur,
      AccountProfile.champion,
    ]);
    expect(
      defaultAccountProfileForRole(AppConstants.roleSeller),
      AccountProfile.greenpreneur,
    );
  });

  test('Champion cannot select a profile the account does not hold', () async {
    final container = _container(AppConstants.roleBuyer);
    addTearDown(container.dispose);
    await container.read(currentUserProvider.future);

    expect(
      container.read(activeAccountProfileProvider),
      AccountProfile.champion,
    );
    expect(
      container
          .read(accountProfileControllerProvider.notifier)
          .select(AccountProfile.greenpreneur),
      isFalse,
    );
    expect(
      container.read(activeAccountProfileProvider),
      AccountProfile.champion,
    );
  });

  test('Greenpreneur can switch between work and Champion profiles', () async {
    final container = _container(AppConstants.roleSeller);
    addTearDown(container.dispose);
    await container.read(currentUserProvider.future);

    expect(
      container.read(activeAccountProfileProvider),
      AccountProfile.greenpreneur,
    );
    expect(
      container
          .read(accountProfileControllerProvider.notifier)
          .select(AccountProfile.champion),
      isTrue,
    );
    expect(
      container.read(activeAccountProfileProvider),
      AccountProfile.champion,
    );
  });

  test(
    'a profile choice never leaks into the next signed-in account',
    () async {
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWithValue(
            AsyncData(_user(AppConstants.roleAdmin)),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(currentUserProvider.future);
      final controller = container.read(
        accountProfileControllerProvider.notifier,
      );
      expect(controller.select(AccountProfile.champion), isTrue);
      expect(
        container.read(activeAccountProfileProvider),
        AccountProfile.champion,
      );

      container.updateOverrides([
        currentUserProvider.overrideWithValue(
          AsyncData(
            UserModel(
              uid: 'uid-2',
              name: 'Second Admin',
              email: 'second@example.com',
              role: AppConstants.roleAdmin,
              status: AppConstants.statusActive,
            ),
          ),
        ),
      ]);

      expect(container.read(selectedAccountProfileProvider), isNull);
      expect(
        container.read(activeAccountProfileProvider),
        AccountProfile.admin,
      );
    },
  );
}
