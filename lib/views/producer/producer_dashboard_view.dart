import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/producer_workspace_controller.dart';
import '../../core/constants.dart';
import '../../core/epr_categories.dart';
import '../../core/epr_claims.dart';
import '../../core/theme.dart';
import '../../models/organization_model.dart';
import '../../services/organization_service.dart';
import '../shared/action_card.dart';
import '../shared/app_shell.dart';
import '../shared/app_snackbar.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';

/// The EPR producer workspace (EPR-1, NFR-E-1).
///
/// ## What this screen deliberately does not show
///
/// It shows no kilograms, no percentage and no target. Not because the data is
/// missing from this build — Phase A has no attribution yet — but because the
/// rule that will still hold when it does is that a figure appears only when
/// its inputs exist: no percentage without a submitted put-on-market
/// declaration (EPR-24), no target without a size class and an obligation start
/// date, no recycling line at all (EPR-25).
///
/// So the empty state here says which of those are outstanding, in the words
/// they will be said in later. A workspace that showed "0 kg collected — 0% of
/// your 15% target" would be stating a compliance position from an absence of
/// evidence, which is the one thing §6.7 forbids outright.
class ProducerDashboardView extends ConsumerWidget {
  const ProducerDashboardView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(producerWorkspaceProvider);

    return AppShell(
      title: 'EPR workspace',
      child: workspace.when(
        loading: () => const ContentLoading(
          label: 'Opening your workspace…',
          slowHint: ContentLoading.serverWakingHint,
        ),
        error: (error, _) => ErrorRetry(
          error: error,
          onRetry: () => ref.invalidate(producerWorkspaceProvider),
        ),
        data: (data) => _Workspace(workspace: data),
      ),
    );
  }
}

class _Workspace extends ConsumerWidget {
  const _Workspace({required this.workspace});

  final ProducerWorkspace workspace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (workspace.hasError) {
      return ErrorRetry(
        error: workspace.error!,
        onRetry: () => ref.invalidate(producerWorkspaceProvider),
      );
    }

    // Three distinct blocked states, each with a different remedy, and each
    // said in its own words. A single "no access" screen would leave a person
    // who simply has not clicked a verification link with nothing to do.
    if (!workspace.emailVerified) {
      return const _EmailVerificationGate();
    }
    if (workspace.membership == null || !workspace.membership!.isActive) {
      return const _NoMembershipNotice();
    }

    final organization = workspace.organization;
    if (organization == null) {
      return const ContentEmpty(
        icon: Icons.business_outlined,
        title: 'No organisation',
        message:
            'Your account is not attached to a company yet. A 3ZERO Admin can '
            'attach it.',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= AppConstants.webBreakpoint;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(AppTheme.gapMd),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _OrganizationHeader(
                    organization: organization,
                    orgRole: workspace.orgRole,
                  ),

                  if (organization.isReadOnly) ...[
                    const SizedBox(height: AppTheme.gapMd),
                    NoticeCard(
                      icon: Icons.lock_outline,
                      tone: NoticeTone.warning,
                      title: organization.isAwaitingReview
                          ? 'Awaiting Chokro review'
                          : 'Read-only',
                      message: organization.isAwaitingReview
                          ? 'Your company record is with a 3ZERO Admin. Until it '
                                'is approved you can see this workspace but not '
                                'register products or file anything.'
                          : 'This workspace is read-only. Existing records and '
                                'documents stay available; nothing new can be '
                                'submitted or issued.',
                    ),
                  ],

                  const SizedBox(height: AppTheme.gapLg),
                  const SectionHeading(
                    'Your reporting position',
                    icon: Icons.summarize_outlined,
                  ),
                  _ReportingPosition(organization: organization),

                  const SizedBox(height: AppTheme.gapLg),
                  const SectionHeading(
                    'Workspace',
                    icon: Icons.dashboard_outlined,
                  ),
                  _ActionGrid(
                    wide: wide,
                    children: [
                      ActionCard(
                        icon: Icons.inventory_2_outlined,
                        title: 'Registered products',
                        subtitle:
                            'Declare what you place on the market. Chokro '
                            'weighs each one before it can be reported.',
                        tone: ActionTone.primary,
                        onTap: () => context.go('/producer/skus'),
                      ),
                      ActionCard(
                        icon: Icons.group_outlined,
                        title: 'People with access',
                        subtitle: workspace.can(OrgRoles.owner)
                            ? 'Invite colleagues, change what they can do and '
                                  'remove access.'
                            : 'See who in your company can use this workspace.',
                        onTap: () => context.go('/producer/members'),
                      ),
                      ActionCard(
                        icon: Icons.history_outlined,
                        title: 'Activity trail',
                        subtitle:
                            'Every change to your company record, with who made '
                            'it and when.',
                        onTap: () => context.push('/producer/activity'),
                      ),
                    ],
                  ),

                  const SizedBox(height: AppTheme.gapLg),
                  const _WhatChokroDoesNotClaim(),
                  const SizedBox(height: AppTheme.gapXl),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The header: who this company is, and what this person may do here.
class _OrganizationHeader extends StatelessWidget {
  const _OrganizationHeader({required this.organization, this.orgRole});

  final OrganizationModel organization;
  final String? orgRole;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              organization.displayName,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            if (organization.legalName != organization.displayName) ...[
              const SizedBox(height: AppTheme.gapXs),
              Text(
                organization.legalName,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: AppTheme.gapSm),
            Wrap(
              spacing: AppTheme.gapSm,
              runSpacing: AppTheme.gapSm,
              children: [
                _Pill(
                  icon: Icons.verified_user_outlined,
                  label: OrgStatus.label(organization.status),
                ),
                if (orgRole != null)
                  _Pill(
                    icon: Icons.badge_outlined,
                    label: 'You: ${OrgRoles.label(orgRole!)}',
                  ),
                if (organization.sizeClass != null)
                  _Pill(
                    icon: Icons.factory_outlined,
                    label: OrgSizeClass.label(organization.sizeClass!),
                  ),
                if (organization.doeRegistrationNo != null)
                  _Pill(
                    icon: Icons.assignment_outlined,
                    label: 'DoE ${organization.doeRegistrationNo}',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What this producer's reporting position actually is, right now.
///
/// Every line here is either a stored fact or an explicit statement that a fact
/// is missing. There is no arithmetic in this widget (QA-1) because there is
/// nothing yet to compute — and when there is, it will be computed in a model.
class _ReportingPosition extends StatelessWidget {
  const _ReportingPosition({required this.organization});

  final OrganizationModel organization;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final obligationYear = organization.obligationYearAt(now);
    final collectionTarget = organization.collectionTargetAt(now);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Fact(
              label: 'Gazette categories you are obligated for',
              value: organization.categories.isEmpty
                  ? null
                  : organization.categories
                        .map(GazetteCategory.label)
                        .join(', '),
              missing: 'Not set yet. A 3ZERO Admin sets this during review.',
            ),
            _Fact(
              label: 'Obligation year',
              value: obligationYear == null ? null : 'Year $obligationYear',
              missing:
                  'No obligation start date recorded, so the applicable year '
                  'cannot be stated.',
            ),
            _Fact(
              label: 'Applicable collection target',
              value: collectionTarget == null
                  ? null
                  : '${(collectionTarget * 100).toStringAsFixed(collectionTarget * 100 % 1 == 0 ? 0 : 1)}% '
                        'of what you place on the market',
              missing:
                  '${EprAbsenceReasons.noTargetWithoutObligationYear} '
                  '${EprAbsenceReasons.targetIsNotAnAssessment}',
            ),

            const Divider(height: AppTheme.gapXl),

            // The two figures a producer opens this screen for, and the honest
            // reason neither is here yet.
            NoticeCard(
              icon: Icons.scale_outlined,
              tone: NoticeTone.info,
              title: 'Collected mass is not being attributed yet',
              message: EprAbsenceReasons.noMassWithoutVerification,
            ),
            const SizedBox(height: AppTheme.gapSm),
            NoticeCard(
              icon: Icons.percent_outlined,
              tone: NoticeTone.info,
              title: 'No percentage without a declaration',
              message:
                  EprAbsenceReasons.noPercentageWithoutDeclaration,
            ),

            const SizedBox(height: AppTheme.gapSm),
            Text(
              EprAbsenceReasons.recyclingNotCovered,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The §6.7 boundary statements, on the screen rather than in a footnote.
class _WhatChokroDoesNotClaim extends StatelessWidget {
  const _WhatChokroDoesNotClaim();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppTheme.gapSm),
                Text(
                  'What Chokro does and does not claim',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.gapSm),
            // Rendered from the shared list, not retyped here. §6.7 is testable
            // (QA-4), and a sentence typed into a widget is not — see
            // `epr_claims.dart`. The Plastic Passport prints the same list.
            for (final line in eprBoundaryStatements)
              Padding(
                padding: const EdgeInsets.only(bottom: AppTheme.gapXs),
                child: Text('•  $line', style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}

/// The verification gate (EPR-5).
///
/// Its own screen rather than a banner, because until the address is verified
/// there is nothing else on this screen worth showing — and because the remedy
/// is one button.
class _EmailVerificationGate extends ConsumerStatefulWidget {
  const _EmailVerificationGate();

  @override
  ConsumerState<_EmailVerificationGate> createState() =>
      _EmailVerificationGateState();
}

class _EmailVerificationGateState
    extends ConsumerState<_EmailVerificationGate> {
  bool _sending = false;

  Future<void> _send() async {
    final snack = AppSnackBar.of(context);
    setState(() => _sending = true);
    try {
      await FirebaseAuth.instance.currentUser?.sendEmailVerification();
      if (!mounted) return;
      snack.success('Verification email sent. Check your inbox.');
    } catch (error) {
      if (!mounted) return;
      snack.failure('The verification email could not be sent. Try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _recheck() async {
    final snack = AppSnackBar.of(context);
    // Firebase caches `emailVerified` in the ID token, so a reload plus a
    // forced token refresh is what makes a verification that happened in
    // another tab visible here. Without the refresh the person clicks the link,
    // returns, and is told they still have not verified.
    await FirebaseAuth.instance.currentUser?.reload();
    await FirebaseAuth.instance.currentUser?.getIdToken(true);
    if (!mounted) return;
    ref.invalidate(producerWorkspaceProvider);
    snack.info('Checked again.');
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? 'your address';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapXl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NoticeCard(
                icon: Icons.mark_email_unread_outlined,
                tone: NoticeTone.warning,
                title: 'Verify $email',
                message:
                    'A compliance workspace needs proof that the person holding '
                    'the password also holds the mailbox the invitation went '
                    'to. Verify your address to continue.',
              ),
              const SizedBox(height: AppTheme.gapMd),
              FilledButton.icon(
                onPressed: _sending ? null : _send,
                icon: const Icon(Icons.send_outlined),
                label: Text(_sending ? 'Sending…' : 'Send the link again'),
              ),
              const SizedBox(height: AppTheme.gapSm),
              OutlinedButton.icon(
                onPressed: _recheck,
                icon: const Icon(Icons.refresh),
                label: const Text('I have verified — check again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoMembershipNotice extends StatelessWidget {
  const _NoMembershipNotice();

  @override
  Widget build(BuildContext context) {
    return const ContentEmpty(
      icon: Icons.no_accounts_outlined,
      title: 'No access to a workspace',
      message:
          'This account is not an active member of any company workspace. If '
          'your access was removed, or your invitation has not been redeemed, '
          'ask an owner at your company or a 3ZERO Admin.',
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, required this.missing});

  final String label;

  /// Null means the fact is not established. It is then said so, in words —
  /// never rendered as a dash, a zero or a placeholder that could be read as a
  /// measurement.
  final String? value;

  final String missing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final known = value != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.gapMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.gapXs),
          Text(
            known ? value! : missing,
            style: known
                ? theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  )
                : theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(label, style: theme.textTheme.labelMedium),
        ],
      ),
    );
  }
}

/// Cards side by side on a desktop browser, one column on a handset.
///
/// NFR-E-5: legible at 320 logical pixels with 2x text scaling, no overflow.
class _ActionGrid extends StatelessWidget {
  const _ActionGrid({required this.children, required this.wide});

  final List<Widget> children;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final child in children)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.gapSm),
              child: child,
            ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final child in children)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: AppTheme.gapSm),
              child: child,
            ),
          ),
      ],
    );
  }
}
