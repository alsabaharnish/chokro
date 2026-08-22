import 'constants.dart';

/// The part of a multi-role account the person is currently using.
///
/// This is deliberately separate from the Firestore `users.role` value. The
/// stored role is an authorisation tier (`admin` includes Greenpreneur access,
/// and Greenpreneur includes Champion access); this value is only a view mode.
/// Switching profile must never grant a permission the account does not hold.
enum AccountProfile { admin, greenpreneur, champion }

extension AccountProfileDisplay on AccountProfile {
  String get label => switch (this) {
    AccountProfile.admin => AppConstants.roleAdminLabel,
    AccountProfile.greenpreneur => AppConstants.roleSellerLabel,
    AccountProfile.champion => AppConstants.roleBuyerLabel,
  };

  String get description => switch (this) {
    AccountProfile.admin =>
      'Review activity, manage accounts and guide the platform.',
    AccountProfile.greenpreneur =>
      'List sustainable products and fulfil Champion orders.',
    AccountProfile.champion =>
      'Take green actions, shop responsibly and support initiatives.',
  };
}

/// Profiles held by a stored authorisation role, most privileged first.
///
/// Unknown roles fail closed to the Champion experience. Firestore and the
/// trusted service still reject anything beyond the stored permissions.
List<AccountProfile> accountProfilesForRole(String role) => switch (role) {
  AppConstants.roleAdmin => const [
    AccountProfile.admin,
    AccountProfile.greenpreneur,
    AccountProfile.champion,
  ],
  AppConstants.roleSeller => const [
    AccountProfile.greenpreneur,
    AccountProfile.champion,
  ],
  _ => const [AccountProfile.champion],
};

AccountProfile defaultAccountProfileForRole(String role) =>
    accountProfilesForRole(role).first;

bool roleHoldsAccountProfile(String role, AccountProfile profile) =>
    accountProfilesForRole(role).contains(profile);
