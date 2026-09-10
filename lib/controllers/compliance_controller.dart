import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/carbon_math.dart';
import '../core/compliance_math.dart';
import '../core/constants.dart';
import '../core/epr_categories.dart';
import '../models/plastic_passport_model.dart';
import '../models/producer_sdg_model.dart';
import '../services/compliance_service.dart';
import 'attribution_controller.dart';
import 'producer_workspace_controller.dart';

final complianceServiceProvider = Provider<ComplianceService>(
  (ref) => ComplianceService(),
);

/// The EPR policy thresholds, read from the server.
///
/// Kept alive rather than `autoDispose`: the policy changes rarely and only by
/// an Admin action, and re-fetching it on every screen entry would be a round
/// trip per navigation for a value that is almost always the same.
final eprPolicyProvider = FutureProvider<EprPolicyThresholds?>(
  (ref) => ref.watch(complianceServiceProvider).loadPolicy(),
);

/// The selected period's declaration, its history, and the words to sign.
final declarationProvider = FutureProvider.autoDispose<DeclarationDetail>((
  ref,
) async {
  final workspace = await ref.watch(producerWorkspaceProvider.future);
  final periodId = ref.watch(selectedPeriodProvider);

  if (!workspace.isReady) {
    return DeclarationDetail(
      periodId: periodId,
      declaration: null,
      versions: const [],
      attestationText: '',
    );
  }

  return ref.watch(complianceServiceProvider).loadDeclaration(periodId);
});

/// This organisation's certificates, newest first.
final passportsProvider =
    FutureProvider.autoDispose<List<PlasticPassportModel>>((ref) async {
      final workspace = await ref.watch(producerWorkspaceProvider.future);
      if (!workspace.isReady) return const <PlasticPassportModel>[];
      return ref.watch(complianceServiceProvider).listPassports();
    });

/// The selected period's compliance position (EPR-24, EPR-25, EPR-26).
///
/// ## Why the collected mass and the declaration are combined HERE and not on
/// either side alone
///
/// A collection percentage is a ratio between two figures with entirely
/// different provenance. The numerator is Chokro's — incremented by the service
/// as each attribution commits. The denominator is the producer's own attested
/// statement. Neither side can compute the ratio, because neither holds both
/// numbers.
///
/// What that means in practice is the thing this provider exists to get right:
/// **a period with collected mass and no declaration has no percentage at
/// all.** Not zero, not a dash, not "0% of 0". `CollectionRate` cannot be
/// constructed without either a rate or a stated reason for its absence, so the
/// screen is forced to render the difference rather than choosing to.
///
/// ## Why the target can be null even when the rate is not
///
/// EPR-26: no target is shown unless the obligation year is established. A
/// producer whose obligation start date has not been recorded has a real
/// collection percentage and no gazette threshold to compare it against, and
/// guessing "probably year 1, so 15%" would put a compliance verdict on the
/// screen that Chokro has no basis for.
final compliancePositionProvider =
    FutureProvider.autoDispose<CompliancePosition>((ref) async {
      final periodId = ref.watch(selectedPeriodProvider);
      final period = await ref.watch(selectedPeriodDataProvider.future);
      final detail = await ref.watch(declarationProvider.future);
      final workspace = await ref.watch(producerWorkspaceProvider.future);

      // ====================================================================
      // A FAILED READ IS NOT AN ABSENT DECLARATION
      // ====================================================================
      //
      // `ComplianceService.loadDeclaration` returns a failure as DATA rather
      // than throwing, so that a screen can say what went wrong instead of
      // showing a bare error. That is right for the declaration screen and
      // wrong here: without this guard, a timeout or a 503 arrives as
      // `declaration: null`, which `CompliancePosition.from` reads as
      // `RateAbsence.noDeclaration` — and the dashboard then says "No
      // percentage without a declaration" and the SDG page says "no
      // put-on-market declaration has been filed for this period".
      //
      // Both are FALSE STATEMENTS ABOUT THE PRODUCER'S PAPERWORK, produced by
      // a network fault. A producer who has filed, and is shown that sentence,
      // has been told its filing is missing.
      //
      // Thrown rather than returned, so the provider is in an error state and
      // `_CollectionPosition`'s error branch renders — which says the
      // percentage could not be worked out and that this is not a statement
      // about the filing. That branch existed already and was unreachable.
      if (detail.hasError) {
        throw ComplianceUnavailable(detail.error!);
      }

      final declaration = detail.declaration;

      // Null unless a SUBMITTED declaration exists. A draft has not been
      // attested to, so certifying against it would let a producer set its own
      // denominator without signing for it.
      final declaredByCategory = declaration != null && declaration.isUsable
          ? <String, int>{
              for (final category in GazetteCategory.all)
                if (declaration.massMgFor(category) case final int mg)
                  category: mg,
            }
          : null;

      final organization = workspace.organization;
      final obligationYear = organization?.obligationYearForPeriod(periodId);

      return CompliancePosition.from(
        periodId: periodId,
        collectedMassMgByCategory: period.massMgByCategory,
        declaredMassMgByCategory: declaredByCategory,
        // Both null together: a year that is not established has no target, and
        // `CompliancePosition` renders `notComparable` rather than a verdict.
        applicableCollectionTarget: organization?.collectionTargetForPeriod(
          periodId,
        ),
        obligationYear: obligationYear,
      );
    });

/// Whether the current member may file and attest (EPR-3).
///
/// Two separate answers, because the form shows both states: a reporter can
/// enter the figures and cannot sign them, and a screen that hid the sign
/// button entirely would leave a reporter unable to see that the step exists.
final declarationPermissionsProvider =
    FutureProvider.autoDispose<DeclarationPermissions>((ref) async {
      final workspace = await ref.watch(producerWorkspaceProvider.future);
      return DeclarationPermissions(
        canDraft: workspace.can(OrgRoles.reporter) && !workspace.isReadOnly,
        canAttest: workspace.can(OrgRoles.owner) && !workspace.isReadOnly,
        isReadOnly: workspace.isReadOnly,
      );
    });

class DeclarationPermissions {
  const DeclarationPermissions({
    required this.canDraft,
    required this.canAttest,
    required this.isReadOnly,
  });

  final bool canDraft;
  final bool canAttest;

  /// A suspended workspace: everything readable, nothing new filed.
  final bool isReadOnly;
}

/// The selected period's SDG alignment (EPR-36, EPR-37).
///
/// Assembled from the same two sources the compliance position uses, plus the
/// carbon estimate — so a figure on an SDG card and the same figure on the
/// dashboard cannot disagree.
///
/// The carbon estimate is computed here rather than read from the server
/// because it is a *display* derivation over figures the server already
/// produced: the collected mass and the estimated share are both stored, the
/// factor comes from the registry, and `carbonAvoided` is a pure function
/// (QA-1). Nothing about it is a compliance figure the client is writing — the
/// authoritative carbon line on a certificate is computed server-side in
/// `passports.js` and frozen into the certificate's snapshot.
final producerSdgProvider = FutureProvider.autoDispose<ProducerSdgSnapshot>((
  ref,
) async {
  final period = await ref.watch(selectedPeriodDataProvider.future);
  // Awaited, so a `ComplianceUnavailable` from the position propagates here
  // rather than being silently rendered as an absent declaration on the SDG
  // cards too.
  final position = await ref.watch(compliancePositionProvider.future);
  final policy = await ref.watch(eprPolicyProvider.future);

  return ProducerSdgSnapshot.from(
    period: period,
    collectionRate: position.overall,
    carbon: carbonAvoided(
      massMg: period.totalMassMg,
      factor: turnerMixedPlastics2015,
      estimatedShare: period.estimatedShare,
      // EPR-39's ceiling, from the SERVER's policy where it can be read.
      //
      // Not the compiled-in constant: the server's copy is admin-writable, and
      // if an Admin lowers it the certificate stops printing a carbon figure
      // for periods above the new value. A client still using the old constant
      // would keep printing one, and the producer would have a figure on its
      // dashboard that is absent from its own certificate.
      //
      // The constant is the fallback for a failed policy read, and it is the
      // same number as the server's default — so the two agree unless an Admin
      // has changed it.
      uncertaintyCeiling:
          policy?.carbonUncertaintyCeiling ?? carbonUncertaintyCeiling,
    ),
  );
});

/// The compliance position could not be assembled.
///
/// Its own type rather than a bare `Exception`, because the distinction it
/// carries is the whole point: this is Chokro failing to READ the producer's
/// declaration, not the producer having failed to FILE one. A screen that
/// conflated them would tell a company its paperwork is missing because a
/// request timed out.
class ComplianceUnavailable implements Exception {
  const ComplianceUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
