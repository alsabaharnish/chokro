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
    this.isFromCache = false,
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

  /// Whether the account directory has not yet been confirmed by Firestore's
  /// server. The count is still displayed, but labelled as cached.
  final bool isFromCache;

  static const AccountTotals empty = AccountTotals();
}

final accountTotalsProvider = Provider.autoDispose<AsyncValue<AccountTotals>>((
  ref,
) {
  // Re-evaluate time-limited suspensions even when no user document changes.
  // Without this clock, a suspension that expired while the dashboard stayed
  // open remained in "Cannot act" until Firestore happened to emit again.
  final now = ref.watch(dashboardClockProvider).value ?? DateTime.now();
  return ref.watch(allUsersProvider).whenData((page) {
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
      isFromCache: page.isFromCache,
    );
  });
});

/// A low-frequency UI clock for values whose meaning changes as time passes.
///
/// One immediate event avoids delaying the account total, then a minute is a
/// sufficiently tight bound for an administrative summary without rebuilding
/// the screen every second. Auto-dispose cancels the periodic stream when no
/// dashboard consumer remains.
final dashboardClockProvider = StreamProvider.autoDispose<DateTime>((
  ref,
) async* {
  yield DateTime.now();
  yield* Stream<DateTime>.periodic(
    const Duration(minutes: 1),
    (_) => DateTime.now(),
  );
});
