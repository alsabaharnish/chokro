import 'constants.dart';

/// The part of a multi-role account the person is currently using.
///
/// This is deliberately separate from the Firestore `users.role` value. The
/// stored role is an authorisation tier (`admin` includes Greenpreneur access,
/// and Greenpreneur includes Champion access); this value is only a view mode.
/// Switching profile must never grant a permission the account does not hold.
enum AccountProfile {
  admin,
  greenpreneur,
  champion,

  /// The EPR producer workspace (EPR-1).
  ///
  /// The one profile in this enum that is *not* part of the inclusive ladder
  /// above it. See [accountProfilesForRole].
  producer,
}

extension AccountProfileDisplay on AccountProfile {
  String get label => switch (this) {
    AccountProfile.admin => AppConstants.roleAdminLabel,
    AccountProfile.greenpreneur => AppConstants.roleSellerLabel,
    AccountProfile.champion => AppConstants.roleBuyerLabel,
    AccountProfile.producer => AppConstants.roleProducerLabel,
  };

  String get description => switch (this) {
    AccountProfile.admin =>
      'Review activity, manage accounts and guide the platform.',
    AccountProfile.greenpreneur =>
      'List sustainable products and fulfil Champion orders.',
    AccountProfile.champion =>
      'Take green actions, shop responsibly and support initiatives.',
    AccountProfile.producer =>
      'Register products, track collected packaging and file EPR reports.',
  };
}

/// Profiles held by a stored authorisation role, most privileged first.
///
/// ## The ladder, and the one role that is not on it
///
/// `admin` → `seller` → `buyer` is inclusive by design: they are progressive
/// citizen profiles held by one person, so each tier retains the ones below it.
///
/// [AppConstants.roleProducer] is **disjoint** (EPR-1). A producer account gets
/// the producer workspace and nothing else — no Champion wallet, no
/// marketplace, no eco-actions. This is written as its own `case` rather than
/// left to the fallback below, and the difference is not stylistic: the
/// fallback returns Champion, so a producer that fell through it would silently
/// receive a points wallet it can earn into, which is precisely the coupling
/// EPR-1 exists to prevent. An explicit case is also something a test can
/// assert and a refactor cannot quietly delete.
///
/// Unknown roles still fail closed to the Champion experience — the least
/// privileged citizen profile. Firestore and the trusted service reject
/// anything beyond the stored permissions regardless of what this returns.
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
  AppConstants.roleProducer => const [AccountProfile.producer],
  _ => const [AccountProfile.champion],
};

/// Whether [role] is the disjoint producer role.
///
/// A single named predicate, so the several places that must exclude producers
/// from citizen surfaces all ask the same question rather than each writing
/// their own `role == 'producer'` comparison.
bool roleIsProducer(String role) => role == AppConstants.roleProducer;

AccountProfile defaultAccountProfileForRole(String role) =>
    accountProfilesForRole(role).first;

bool roleHoldsAccountProfile(String role, AccountProfile profile) =>
    accountProfilesForRole(role).contains(profile);
