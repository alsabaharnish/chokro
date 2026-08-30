import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/stats_model.dart';
import '../models/user_model.dart';
import '../services/stats_service.dart';
import 'admin_users_controller.dart';

final statsServiceProvider = Provider<StatsService>((ref) => StatsService());

/// The server-maintained counters behind the admin dashboard (F5.1).
final platformStatsProvider = StreamProvider.autoDispose<PlatformStats>((ref) {
  return ref.watch(statsServiceProvider).watchPlatformStats();
});

/// Account totals, counted live from the `users` collection.
///
/// Deliberately NOT counters. §6.3's argument for `FieldValue.increment()` is
/// that a dashboard must not read whole collections — and it holds for
/// disposals, claims and orders, which grow without bound. It does not hold for
/// accounts: registration is a client write that cannot touch `stats` (nothing
/// can), so a counter would need a server hook on a path that deliberately has
/// none, and the administrator's account list already streams this collection.
///
/// The dashboard labels these as counted rather than accumulated, so the two
/// kinds of figure are not presented as if they had the same provenance.
class AccountTotals {
  const AccountTotals({
    this.total = 0,
    this.buyers = 0,
    this.sellers = 0,
    this.admins = 0,
    this.suspended = 0,
    this.truncated = false,
  });

  final int total;
  final int buyers;
  final int sellers;
  final int admins;

  /// Accounts that cannot act right now. Resolved through [UserModel.isActiveAt]
  /// rather than by comparing `status`, so a lapsed temporary suspension is not
  /// counted as still in force (F5.3).
  final int suspended;

  /// True when every total is a floor because the account directory is capped.
  final bool truncated;

  static const AccountTotals empty = AccountTotals();
}

final accountTotalsProvider = Provider.autoDispose<AsyncValue<AccountTotals>>((
  ref,
) {
  return ref.watch(allUsersProvider).whenData((page) {
    final now = DateTime.now();
    var buyers = 0;
    var sellers = 0;
    var admins = 0;
    var suspended = 0;

    for (final user in page.users) {
      // Profile totals are inclusive. Every account is a Champion, a
      // Greenpreneur retains the Champion profile, and a 3ZERO Admin holds all
      // three. Exclusive security tiers would understate those profile counts.
      buyers += 1;
      if (user.isGreenpreneur) sellers += 1;
      if (user.isAdmin) admins += 1;
      if (!user.isActiveAt(now)) suspended += 1;
    }

    return AccountTotals(
      total: page.users.length,
      buyers: buyers,
      sellers: sellers,
      admins: admins,
      suspended: suspended,
      truncated: page.truncated,
    );
  });
});
