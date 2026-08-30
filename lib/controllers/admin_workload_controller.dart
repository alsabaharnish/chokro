import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../services/admin_workload_service.dart';
import 'admin_review_controller.dart';
import 'appeals_controller.dart';
import 'auth_controller.dart';
import 'claim_controller.dart';
import 'seller_application_controller.dart';

enum AdminTaskKind { disposal, claim, appeal, application }

class AdminTaskProgress {
  const AdminTaskProgress({
    this.pending = 0,
    this.completedToday = 0,
    this.atCap = false,
    this.completedAtCap = false,
  });

  final int pending;
  final int completedToday;
  final bool completedAtCap;

  /// True when [pending] is a floor rather than a total.
  ///
  /// Every queue this counts is read through `.limit(QueryLimits.reviewQueue)`,
  /// so `pending` saturates at 50 and stops moving. Presented as a plain number
  /// that is a lie the admin cannot detect: a 300-item backlog reads as "50",
  /// the badge never falls as they work, and nothing hints that older items
  /// exist. Surfacing the cap is what makes the truncation degrade visibly,
  /// which is what `QueryLimits` was written for.
  final bool atCap;

  bool get isVisible => pending > 0 || completedToday > 0;

  /// The badge text: `50+` when the count is capped, the number otherwise.
  String get badgeLabel => atCap ? '$pending+' : '$pending';
}

class AdminWorkload {
  const AdminWorkload({
    this.disposals = const AdminTaskProgress(),
    this.claims = const AdminTaskProgress(),
    this.appeals = const AdminTaskProgress(),
    this.applications = const AdminTaskProgress(),
    this.isLoading = false,
    this.hasError = false,
  });

  final AdminTaskProgress disposals;
  final AdminTaskProgress claims;
  final AdminTaskProgress appeals;
  final AdminTaskProgress applications;
  final bool isLoading;
  final bool hasError;

  static const empty = AdminWorkload();

  AdminTaskProgress progressFor(AdminTaskKind kind) => switch (kind) {
    AdminTaskKind.disposal => disposals,
    AdminTaskKind.claim => claims,
    AdminTaskKind.appeal => appeals,
    AdminTaskKind.application => applications,
  };

  int get pendingTotal =>
      disposals.pending +
      claims.pending +
      appeals.pending +
      applications.pending;

  int get completedTodayTotal =>
      disposals.completedToday +
      claims.completedToday +
      appeals.completedToday +
      applications.completedToday;

  bool get hasCappedPending => AdminTaskKind.values.any(
    (kind) => progressFor(kind).pending > 0 && progressFor(kind).atCap,
  );

  bool get hasCappedCompleted => AdminTaskKind.values.any(
    (kind) =>
        progressFor(kind).completedToday > 0 &&
        progressFor(kind).completedAtCap,
  );
}

final adminWorkloadServiceProvider = Provider<AdminWorkloadService>((ref) {
  return AdminWorkloadService();
});

/// Invalidates itself at local midnight so yesterday's green checks disappear
/// even when the dashboard remains open overnight. The timer is cancelled as
/// soon as the admin workspace leaves the widget tree.
final adminWorkdayProvider = Provider.autoDispose<DateTime>((ref) {
  final now = DateTime.now();
  final nextDay = DateTime(now.year, now.month, now.day + 1);
  final timer = Timer(nextDay.difference(now), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return now;
});

final _completedDisposalsTodayProvider =
    StreamProvider.autoDispose<AdminCompletedCount>((ref) {
      final user = ref.watch(currentUserProvider).value;
      if (user == null || !user.isAdmin) {
        return Stream.value(const AdminCompletedCount(count: 0, atCap: false));
      }
      final day = ref.watch(adminWorkdayProvider);
      return ref
          .watch(adminWorkloadServiceProvider)
          .watchCompletedDisposals(adminUid: user.uid, day: day);
    });

final _completedClaimsTodayProvider =
    StreamProvider.autoDispose<AdminCompletedCount>((ref) {
      final user = ref.watch(currentUserProvider).value;
      if (user == null || !user.isAdmin) {
        return Stream.value(const AdminCompletedCount(count: 0, atCap: false));
      }
      final day = ref.watch(adminWorkdayProvider);
      return ref
          .watch(adminWorkloadServiceProvider)
          .watchCompletedClaims(adminUid: user.uid, day: day);
    });

final _completedAppealsTodayProvider =
    StreamProvider.autoDispose<AdminCompletedCount>((ref) {
      final user = ref.watch(currentUserProvider).value;
      if (user == null || !user.isAdmin) {
        return Stream.value(const AdminCompletedCount(count: 0, atCap: false));
      }
      final day = ref.watch(adminWorkdayProvider);
      return ref
          .watch(adminWorkloadServiceProvider)
          .watchCompletedAppeals(adminUid: user.uid, day: day);
    });

final _completedApplicationsTodayProvider =
    StreamProvider.autoDispose<AdminCompletedCount>((ref) {
      final user = ref.watch(currentUserProvider).value;
      if (user == null || !user.isAdmin) {
        return Stream.value(const AdminCompletedCount(count: 0, atCap: false));
      }
      final day = ref.watch(adminWorkdayProvider);
      return ref
          .watch(adminWorkloadServiceProvider)
          .watchCompletedApplications(adminUid: user.uid, day: day);
    });

/// One reactive view of all work that feeds badges and the dashboard to-do list.
/// Queue streams remain the authority for what is pending; the audit streams
/// above only provide today's completed counts.
final adminWorkloadProvider = Provider.autoDispose<AdminWorkload>((ref) {
  final user = ref.watch(currentUserProvider).value;
  if (user == null || !user.isAdmin) return AdminWorkload.empty;

  final pendingDisposals = ref.watch(pendingDisposalsProvider);
  final pendingClaims = ref.watch(pendingClaimsProvider);
  final pendingAppeals = ref.watch(pendingAppealsProvider);
  final pendingApplications = ref.watch(pendingApplicationsProvider);
  final doneDisposals = ref.watch(_completedDisposalsTodayProvider);
  final doneClaims = ref.watch(_completedClaimsTodayProvider);
  final doneAppeals = ref.watch(_completedAppealsTodayProvider);
  final doneApplications = ref.watch(_completedApplicationsTodayProvider);

  final values = <AsyncValue<Object?>>[
    pendingDisposals,
    pendingClaims,
    pendingAppeals,
    pendingApplications,
    doneDisposals,
    doneClaims,
    doneAppeals,
    doneApplications,
  ];

  // Every one of these four queues is read with `.limit(QueryLimits.reviewQueue)`,
  // so a length that has reached the limit means "at least this many".
  AdminTaskProgress progress(
    AsyncValue<List<Object?>> queue,
    AdminCompletedCount? done,
  ) {
    final pending = queue.value?.length ?? 0;
    return AdminTaskProgress(
      pending: pending,
      atCap: pending >= QueryLimits.reviewQueue,
      completedToday: done?.count ?? 0,
      completedAtCap: done?.atCap ?? false,
    );
  }

  return AdminWorkload(
    disposals: progress(pendingDisposals, doneDisposals.value),
    claims: progress(pendingClaims, doneClaims.value),
    appeals: progress(pendingAppeals, doneAppeals.value),
    applications: progress(pendingApplications, doneApplications.value),
    isLoading: values.any((value) => value.isLoading && !value.hasValue),
    hasError: values.any((value) => value.hasError && !value.hasValue),
  );
});
