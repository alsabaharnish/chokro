import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/admin_workload_service.dart';
import 'admin_review_controller.dart';
import 'appeals_controller.dart';
import 'auth_controller.dart';
import 'claim_controller.dart';
import 'seller_application_controller.dart';

enum AdminTaskKind { disposal, claim, appeal, application }

class AdminTaskProgress {
  const AdminTaskProgress({this.pending = 0, this.completedToday = 0});

  final int pending;
  final int completedToday;

  bool get isVisible => pending > 0 || completedToday > 0;
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

final _completedDisposalsTodayProvider = StreamProvider.autoDispose<int>((ref) {
  final user = ref.watch(currentUserProvider).value;
  if (user == null || !user.isAdmin) return Stream.value(0);
  final day = ref.watch(adminWorkdayProvider);
  return ref
      .watch(adminWorkloadServiceProvider)
      .watchCompletedDisposals(adminUid: user.uid, day: day);
});

final _completedClaimsTodayProvider = StreamProvider.autoDispose<int>((ref) {
  final user = ref.watch(currentUserProvider).value;
  if (user == null || !user.isAdmin) return Stream.value(0);
  final day = ref.watch(adminWorkdayProvider);
  return ref
      .watch(adminWorkloadServiceProvider)
      .watchCompletedClaims(adminUid: user.uid, day: day);
});

final _completedAppealsTodayProvider = StreamProvider.autoDispose<int>((ref) {
  final user = ref.watch(currentUserProvider).value;
  if (user == null || !user.isAdmin) return Stream.value(0);
  final day = ref.watch(adminWorkdayProvider);
  return ref
      .watch(adminWorkloadServiceProvider)
      .watchCompletedAppeals(adminUid: user.uid, day: day);
});

final _completedApplicationsTodayProvider = StreamProvider.autoDispose<int>((
  ref,
) {
  final user = ref.watch(currentUserProvider).value;
  if (user == null || !user.isAdmin) return Stream.value(0);
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

  return AdminWorkload(
    disposals: AdminTaskProgress(
      pending: pendingDisposals.value?.length ?? 0,
      completedToday: doneDisposals.value ?? 0,
    ),
    claims: AdminTaskProgress(
      pending: pendingClaims.value?.length ?? 0,
      completedToday: doneClaims.value ?? 0,
    ),
    appeals: AdminTaskProgress(
      pending: pendingAppeals.value?.length ?? 0,
      completedToday: doneAppeals.value ?? 0,
    ),
    applications: AdminTaskProgress(
      pending: pendingApplications.value?.length ?? 0,
      completedToday: doneApplications.value ?? 0,
    ),
    isLoading: values.any((value) => value.isLoading && !value.hasValue),
    hasError: values.any((value) => value.hasError && !value.hasValue),
  );
});
