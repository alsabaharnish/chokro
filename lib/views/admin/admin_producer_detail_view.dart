library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/admin_oversight_controller.dart';
import '../../core/epr_period.dart';
import '../../core/mass_math.dart';
import '../../core/theme.dart';
import '../../models/admin_oversight_model.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';

/// One producer, for an Admin (EPR-44, EPR-46, EPR-48).
///
/// ## The first addressable admin route with a parameter
///
/// Every other admin screen in this app is a flat, parameterless list, and
/// detail is a dialog over it. That convention is right for "verify this SKU"
/// and wrong here: view-as is a whole read-only dashboard, and a timeline is a
/// long scroll. Neither fits a dialog, and both are inherently about ONE
/// organisation.
///
/// So this sets a precedent — `/admin/producers/:orgId` — deliberately and
/// once. It is reached from the producer list, which already exists.
///
/// ## The read-only treatment is not decoration
///
/// EPR-46: "in a visually distinct read-only mode". An Admin who mistook this
/// for their own console and tried to act would find every write refused by the
/// server, which is safe but confusing. Worse is the opposite mistake — an
/// Admin who believed they had already acted.
///
/// So the read-only banner is persistent, the surface is tinted, and there is
/// no write affordance anywhere on the view tab. The payload's own
/// `isSafeReadOnlyView` is checked in the service before this screen renders
/// anything: if a future server change ever sent a writable payload down this
/// route, the screen refuses rather than quietly offering a button.
class AdminProducerDetailView extends ConsumerStatefulWidget {
  const AdminProducerDetailView({super.key, required this.orgId});

  final String orgId;

  @override
  ConsumerState<AdminProducerDetailView> createState() =>
      _AdminProducerDetailViewState();
}

class _AdminProducerDetailViewState
    extends ConsumerState<AdminProducerDetailView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Producer',
      child: Column(
        children: [
          TabBar(
            controller: _tabs,
            tabs: const [
              Tab(text: 'Their view'),
              Tab(text: 'History'),
              Tab(text: 'Reconciliation'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _ViewAsTab(orgId: widget.orgId),
                _TimelineTab(orgId: widget.orgId),
                _OrgReconciliationTab(orgId: widget.orgId),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// View as organisation (EPR-46)
// ---------------------------------------------------------------------------

class _ViewAsTab extends ConsumerWidget {
  const _ViewAsTab({required this.orgId});

  final String orgId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final periodId = ref.watch(oversightPeriodProvider);
    final result = ref.watch(
      organizationViewProvider((orgId: orgId, periodId: periodId)),
    );

    return result.when(
      loading: () => const ContentLoading(
        label: 'Opening the producer’s view…',
        slowHint: ContentLoading.serverWakingHint,
      ),
      error: (error, _) => ErrorRetry(
        error: error,
        onRetry: () => ref.invalidate(
          organizationViewProvider((orgId: orgId, periodId: periodId)),
        ),
      ),
      data: (data) {
        if (data.hasError) {
          // The likeliest failure is the one that matters, and it is stated
          // rather than shown as a generic error: the view could not be
          // recorded, so it was not opened.
          return Padding(
            padding: const EdgeInsets.all(AppTheme.gapMd),
            child: NoticeCard(
              icon: Icons.lock_outline,
              tone: NoticeTone.error,
              title: 'The view was not opened',
              message: data.error!,
              action: NoticeAction(
                label: 'Try again',
                onPressed: () => ref.invalidate(
                  organizationViewProvider((orgId: orgId, periodId: periodId)),
                ),
              ),
            ),
          );
        }

        return _ReadOnlyProducerView(view: data.view!);
      },
    );
  }
}

class _ReadOnlyProducerView extends StatelessWidget {
  const _ReadOnlyProducerView({required this.view});

  final OrganizationView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      // The tint is the visual distinctness EPR-46 asks for. It runs behind the
      // whole tab rather than sitting in a banner at the top, so it is still
      // visible after a scroll — which is when an Admin is most likely to have
      // forgotten whose screen they are looking at.
      color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.18),
      child: ListView(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        children: [
          NoticeCard(
            icon: Icons.visibility_outlined,
            tone: NoticeTone.warning,
            title: 'You are looking at ${view.tradeName}’s own view',
            message: view.capabilityNote,
          ),
          const SizedBox(height: AppTheme.gapMd),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.gapMd),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(view.legalName, style: theme.textTheme.titleMedium),
                  if (view.tradeName != view.legalName)
                    Text(
                      view.tradeName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  const SizedBox(height: AppTheme.gapSm),
                  _Line('Status', view.status),
                  if (view.doeRegistrationNo != null)
                    _Line('DoE registration', view.doeRegistrationNo!),
                  if (view.sizeClass != null) _Line('Industry size', view.sizeClass!),
                  _Line('Reporting period', periodLabel(view.periodId)),
                  _Line('People with access', '${view.memberCount}'),
                ],
              ),
            ),
          ),

          const SizedBox(height: AppTheme.gapMd),
          Text(
            'Their certificates',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: AppTheme.gapSm),

          if (view.certificates.isEmpty)
            Text(
              'None issued.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            )
          else
            for (final certificate in view.certificates)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${certificate.serial}  ·  '
                        '${periodLabel(certificate.periodId)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Text(
                      certificate.status,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: certificate.isStanding
                            ? theme.colorScheme.outline
                            : theme.colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),

          const SizedBox(height: AppTheme.gapLg),
          NoticeCard(
            icon: Icons.history_edu_outlined,
            tone: NoticeTone.info,
            title: 'This visit is recorded',
            message:
                'Opening this view wrote an entry to ${view.tradeName}’s audit '
                'trail, naming you and the period. Chokro records reading a '
                'producer’s compliance position for the same reason it records '
                'changing one.',
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          Expanded(flex: 3, child: Text(value, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The activity timeline (EPR-44, SEC-12)
// ---------------------------------------------------------------------------

class _TimelineTab extends ConsumerStatefulWidget {
  const _TimelineTab({required this.orgId});

  final String orgId;

  @override
  ConsumerState<_TimelineTab> createState() => _TimelineTabState();
}

class _TimelineTabState extends ConsumerState<_TimelineTab> {
  /// Whether the hash chain has been walked.
  ///
  /// Off by default, and explicit: verification is a whole-collection read, and
  /// a list refreshing on screen should not pay for it.
  bool _verify = false;

  @override
  Widget build(BuildContext context) {
    final timeline = _verify
        ? ref.watch(verifiedTimelineProvider(widget.orgId))
        : ref.watch(organizationTimelineProvider(widget.orgId));

    return timeline.when(
      loading: () => const ContentLoading(
        label: 'Loading…',
        slowHint: ContentLoading.serverWakingHint,
      ),
      error: (error, _) => ErrorRetry(
        error: error,
        onRetry: () => ref.invalidate(
          _verify
              ? verifiedTimelineProvider(widget.orgId)
              : organizationTimelineProvider(widget.orgId),
        ),
      ),
      data: (data) => ListView(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        children: [
          _ChainCard(
            timeline: data,
            verifying: _verify,
            onVerify: () => setState(() => _verify = true),
          ),
          const SizedBox(height: AppTheme.gapMd),

          if (data.entries.isEmpty)
            Text(
              'Nothing recorded for this organisation yet.',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            for (final entry in data.entries) _TimelineRow(entry: entry),
        ],
      ),
    );
  }
}

class _ChainCard extends StatelessWidget {
  const _ChainCard({
    required this.timeline,
    required this.verifying,
    required this.onVerify,
  });

  final ActivityTimeline timeline;
  final bool verifying;
  final VoidCallback onVerify;

  @override
  Widget build(BuildContext context) {
    final verified = timeline.verified;

    // Null is not false. "Not checked" and "checked and failed" are different
    // statements, and a card that conflated them would either alarm nobody or
    // alarm everybody.
    if (verified == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.gapMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'The chain has not been checked',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: AppTheme.gapXs),
              Text(
                'Entries are hash-chained, so a removal or an edit is '
                'detectable. Checking walks every entry and is not done on '
                'every load.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppTheme.gapSm),
              OutlinedButton.icon(
                onPressed: verifying ? null : onVerify,
                icon: const Icon(Icons.verified_outlined, size: 18),
                label: const Text('Verify the chain'),
              ),
            ],
          ),
        ),
      );
    }

    return NoticeCard(
      icon: verified ? Icons.verified_outlined : Icons.gpp_bad_outlined,
      tone: verified ? NoticeTone.success : NoticeTone.error,
      title: verified ? 'The chain is intact' : 'The chain is BROKEN',
      // The caveat is part of the result, not a footnote. An unkeyed chain is
      // tamper-evident against anyone WITHOUT write access and is not evidence
      // against an insider holding the database credential — printing "intact"
      // without saying which would overstate the control (SEC-12).
      message: verified
          ? (timeline.verificationCaveat ??
                'Every entry links to the one before it, under an '
                    'operator-held key.')
          : 'One or more entries do not match their digest, or the sequence '
                'has a gap. Treat this organisation’s history as unreliable '
                'and escalate.',
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.entry});

  final TimelineEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.gapSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Who acted. The distinction EPR-46 exists to preserve: an audit
          // trail that cannot tell Chokro from the producer is not an audit
          // trail, so it is the first thing on every row.
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: entry.byChokro
                  ? theme.colorScheme.tertiaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              entry.byChokro ? 'Chokro' : 'Producer',
              style: theme.textTheme.labelSmall,
            ),
          ),
          const SizedBox(width: AppTheme.gapSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.summary, style: theme.textTheme.bodySmall),
                Text(
                  '#${entry.sequence}  ·  ${entry.action}'
                  '${entry.actorName.isEmpty ? '' : '  ·  ${entry.actorName}'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// This producer's reconciliation history (EPR-48)
// ---------------------------------------------------------------------------

class _OrgReconciliationTab extends ConsumerWidget {
  const _OrgReconciliationTab({required this.orgId});

  final String orgId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(organizationReconciliationProvider(orgId));

    return history.when(
      loading: () => const ContentLoading(
        label: 'Loading…',
        slowHint: ContentLoading.serverWakingHint,
      ),
      error: (error, _) => ErrorRetry(
        error: error,
        onRetry: () => ref.invalidate(organizationReconciliationProvider(orgId)),
      ),
      data: (rows) {
        if (rows.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.gapLg),
              child: Text(
                'No reporting periods recorded for this producer.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.all(AppTheme.gapMd),
          children: [
            for (final row in rows) _PeriodReconciliationRow(row: row),
          ],
        );
      },
    );
  }
}

class _PeriodReconciliationRow extends StatelessWidget {
  const _PeriodReconciliationRow({required this.row});

  final ReconciliationRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    periodLabel(row.periodId),
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    '${formatKilograms(row.incrementedMassMg)}'
                    '  ·  ${row.attributionCount} attributions',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            _ReconciliationVerdict(row: row),
          ],
        ),
      ),
    );
  }
}

class _ReconciliationVerdict extends StatelessWidget {
  const _ReconciliationVerdict({required this.row});

  final ReconciliationRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Three states, never two. "Never checked" is its own answer, and rendering
    // it as agreement is how an entirely unverified year looks clean.
    if (!row.isChecked) {
      return Text(
        'Never checked',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      );
    }

    if (row.isMismatched) {
      final variance = row.variance;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            'Disagrees',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          if (variance != null)
            Text(
              '${variance >= 0 ? '+' : '−'}'
              '${formatKilograms(variance.abs())}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      );
    }

    return Text(
      'Agrees',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.outline,
      ),
    );
  }
}
