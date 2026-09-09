import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/admin_producers_controller.dart';
import '../../core/api_config.dart';
import '../../core/constants.dart';
import '../../core/epr_categories.dart';
import '../../core/theme.dart';
import '../../core/validators.dart';
import '../../models/organization_model.dart';
import '../../services/organization_service.dart';
import '../shared/app_shell.dart';
import '../shared/app_snackbar.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';

/// The Admin producer directory and onboarding review queue
/// (EPR-40, EPR-41, EPR-14).
///
/// ## Why the queue is a separate list rather than a filter
///
/// An application has a clock on it: registration with the Department of
/// Environment is due within six months of listing, and Chokro's evidence takes
/// longer than that to accumulate. An application sitting behind forty active
/// companies in one alphabetical list is an application nobody sees. So the
/// pending list is first, by itself, and it says how many are waiting.
class AdminProducersView extends ConsumerWidget {
  const AdminProducersView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final directory = ref.watch(producerDirectoryProvider);

    return AppShell(
      title: 'EPR producers',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openCreateDialog(context, ref),
        icon: const Icon(Icons.add_business_outlined),
        label: const Text('Add company'),
      ),
      child: directory.when(
        loading: () => const ContentLoading(
          label: 'Loading the producer register…',
          slowHint: ContentLoading.serverWakingHint,
        ),
        error: (error, _) => ErrorRetry(
          error: error,
          onRetry: () => ref.invalidate(adminProducersProvider),
        ),
        data: (data) => data.isEmpty
            ? const ContentEmpty(
                icon: Icons.factory_outlined,
                title: 'No producers yet',
                message:
                    'Add an obligated company to begin. Nothing self-registers '
                    'into this register — a company record is opened here and '
                    'its people arrive by invitation.',
              )
            : _Directory(directory: data),
      ),
    );
  }
}

class _Directory extends ConsumerWidget {
  const _Directory({required this.directory});

  final ProducerDirectory directory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = directory.awaitingReview;

    return ListView(
      padding: const EdgeInsets.all(AppTheme.gapMd),
      children: [
        if (directory.truncatedAt(QueryLimits.producerDirectory))
          const Padding(
            padding: EdgeInsets.only(bottom: AppTheme.gapMd),
            child: NoticeCard(
              icon: Icons.filter_list_outlined,
              tone: NoticeTone.warning,
              message:
                  'This list has reached its read cap, so it may be a prefix '
                  'of the register rather than all of it.',
            ),
          ),

        if (pending.isNotEmpty) ...[
          _Heading(
            'Awaiting review',
            count: pending.length,
            icon: Icons.pending_actions_outlined,
          ),
          for (final org in pending)
            _ProducerCard(organization: org, highlight: true),
          const SizedBox(height: AppTheme.gapLg),
        ],

        if (directory.active.isNotEmpty) ...[
          _Heading(
            'Active',
            count: directory.active.length,
            icon: Icons.verified_outlined,
          ),
          for (final org in directory.active) _ProducerCard(organization: org),
          const SizedBox(height: AppTheme.gapLg),
        ],

        if (directory.inactive.isNotEmpty) ...[
          _Heading(
            'Suspended and closed',
            count: directory.inactive.length,
            icon: Icons.block_outlined,
          ),
          for (final org in directory.inactive) _ProducerCard(organization: org),
        ],

        const SizedBox(height: AppTheme.gap2Xl),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.label, {required this.count, required this.icon});

  final String label;
  final int count;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.gapSm),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppTheme.gapSm),
          Text(
            '$label ($count)',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProducerCard extends ConsumerWidget {
  const _ProducerCard({required this.organization, this.highlight = false});

  final OrganizationModel organization;
  final bool highlight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final detail = ref.watch(adminProducerDetailProvider(organization.id));

    // The collision flag is loaded with the detail rather than on demand,
    // because EPR-14 makes it *blocking*: an Admin must not be able to approve
    // an application without having seen that another organisation already
    // claims the brand.
    final collision = detail.maybeWhen(
      data: (d) => d.hasBrandCollision ? d.brandCollisions : null,
      orElse: () => null,
    );

    return Card(
      color: highlight ? theme.colorScheme.surfaceContainerHigh : null,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        organization.displayName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        organization.legalName,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Chip(label: Text(OrgStatus.label(organization.status))),
              ],
            ),

            const SizedBox(height: AppTheme.gapSm),
            Wrap(
              spacing: AppTheme.gapMd,
              runSpacing: AppTheme.gapXs,
              children: [
                if (organization.sizeClass != null)
                  Text(
                    OrgSizeClass.label(organization.sizeClass!),
                    style: theme.textTheme.labelMedium,
                  ),
                if (organization.district.isNotEmpty)
                  Text(
                    organization.district,
                    style: theme.textTheme.labelMedium,
                  ),
                if (organization.categories.isNotEmpty)
                  Text(
                    organization.categories
                        .map(GazetteCategory.shortLabel)
                        .join(' · '),
                    style: theme.textTheme.labelMedium,
                  ),
                if (organization.contactEmail.isNotEmpty)
                  Text(
                    organization.contactEmail,
                    style: theme.textTheme.labelMedium,
                  ),
              ],
            ),

            if (collision != null) ...[
              const SizedBox(height: AppTheme.gapMd),
              NoticeCard(
                icon: Icons.report_problem_outlined,
                tone: NoticeTone.error,
                title: 'Brand-name collision — resolve before approving',
                message:
                    'Another organisation already claims this name: '
                    '${collision.map((c) => c.tradeName).join(', ')}. '
                    'Registering a brand a company does not own is a way to '
                    'claim someone else’s collected mass. Check the '
                    'brand-ownership evidence before deciding.',
              ),
            ],

            const SizedBox(height: AppTheme.gapMd),
            Wrap(
              spacing: AppTheme.gapSm,
              runSpacing: AppTheme.gapSm,
              children: [
                if (organization.isAwaitingReview) ...[
                  FilledButton.icon(
                    onPressed: () => _openReviewDialog(
                      context,
                      ref,
                      organization,
                      hasCollision: collision != null,
                    ),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('Review'),
                  ),
                  TextButton(
                    onPressed: () =>
                        _openReasonDialog(context, ref, organization, 'requestInfo'),
                    child: const Text('Request information'),
                  ),
                  TextButton(
                    onPressed: () =>
                        _openReasonDialog(context, ref, organization, 'reject'),
                    child: const Text('Reject'),
                  ),
                ],
                if (organization.isActive) ...[
                  OutlinedButton.icon(
                    onPressed: () => _openInviteDialog(context, ref, organization),
                    icon: const Icon(Icons.person_add_outlined),
                    label: const Text('Invite an owner'),
                  ),
                  TextButton(
                    onPressed: () =>
                        _openReasonDialog(context, ref, organization, 'suspend'),
                    child: const Text('Suspend'),
                  ),
                ],
                if (organization.status == OrgStatus.suspended)
                  TextButton(
                    onPressed: () async {
                      final snack = AppSnackBar.of(context);
                      try {
                        await ref
                            .read(adminProducerActionsProvider)
                            .reinstate(organization.id);
                        snack.success('Reinstated.');
                      } on OrgActionException catch (error) {
                        snack.failure(error.message);
                      }
                    },
                    child: const Text('Reinstate'),
                  ),
                TextButton.icon(
                  onPressed: () => _openActivity(context, ref, organization),
                  icon: const Icon(Icons.history_outlined),
                  label: const Text('Activity'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------

/// The onboarding approval form (EPR-41).
///
/// The size class and the obligation start date are mandatory here because they
/// are mandatory on the server: together they decide which gazette targets this
/// entity is measured against and from when. Approving without them would
/// produce a workspace that cannot state its own obligation, which is worse
/// than an unapproved one.
Future<void> _openReviewDialog(
  BuildContext context,
  WidgetRef ref,
  OrganizationModel organization, {
  required bool hasCollision,
}) async {
  final formKey = GlobalKey<FormState>();
  final binController = TextEditingController();
  final licenceController = TextEditingController();
  final doeController = TextEditingController();
  final reasonController = TextEditingController();

  String? sizeClass;
  var complianceRoute = ComplianceRoute.self;
  var startDate = DateTime.now();
  final categories = <String>{};
  var collisionAcknowledged = !hasCollision;
  var submitting = false;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Approve ${organization.displayName}'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasCollision) ...[
                    const NoticeCard(
                      icon: Icons.report_problem_outlined,
                      tone: NoticeTone.error,
                      message:
                          'Another organisation already claims this brand name. '
                          'Confirm you have checked the brand-ownership '
                          'evidence.',
                    ),
                    CheckboxListTile(
                      value: collisionAcknowledged,
                      onChanged: (value) => setState(
                        () => collisionAcknowledged = value ?? false,
                      ),
                      title: const Text(
                        'I have checked the brand-ownership evidence',
                      ),
                    ),
                    const Divider(),
                  ],

                  DropdownButtonFormField<String>(
                    initialValue: sizeClass,
                    decoration: const InputDecoration(
                      labelText: 'Gazette size class',
                      helperText:
                          'Decides the phase-in: large in years 1–2, medium 3–4, '
                          'small in year 5.',
                    ),
                    items: [
                      for (final value in OrgSizeClass.all)
                        DropdownMenuItem(
                          value: value,
                          child: Text(OrgSizeClass.label(value)),
                        ),
                    ],
                    validator: (value) =>
                        value == null ? 'Choose a size class.' : null,
                    onChanged: (value) => setState(() => sizeClass = value),
                  ),
                  const SizedBox(height: AppTheme.gapMd),

                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Obligation start date',
                      helperText:
                          'The clock the applicable target is counted from.',
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${startDate.day}/${startDate.month}/${startDate.year}',
                          ),
                        ),
                        TextButton(
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: startDate,
                              firstDate: DateTime(2026, 8, 13),
                              lastDate: DateTime(2036),
                            );
                            if (picked != null) {
                              setState(() => startDate = picked);
                            }
                          },
                          child: const Text('Change'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppTheme.gapMd),

                  Text(
                    'Obligated categories',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  for (final category in GazetteCategory.all)
                    CheckboxListTile(
                      dense: true,
                      value: categories.contains(category),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          categories.add(category);
                        } else {
                          categories.remove(category);
                        }
                      }),
                      title: Text(GazetteCategory.label(category)),
                      subtitle: Text(GazetteCategory.description(category)),
                    ),

                  const SizedBox(height: AppTheme.gapMd),
                  DropdownButtonFormField<String>(
                    initialValue: complianceRoute,
                    decoration: const InputDecoration(
                      labelText: 'Compliance route',
                    ),
                    items: [
                      for (final value in ComplianceRoute.all)
                        DropdownMenuItem(
                          value: value,
                          child: Text(ComplianceRoute.label(value)),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => complianceRoute = value ?? complianceRoute),
                  ),

                  const SizedBox(height: AppTheme.gapMd),
                  TextFormField(
                    controller: binController,
                    decoration: const InputDecoration(
                      labelText: 'Business Identification Number (optional)',
                    ),
                  ),
                  TextFormField(
                    controller: licenceController,
                    decoration: const InputDecoration(
                      labelText: 'Trade licence number (optional)',
                    ),
                  ),
                  TextFormField(
                    controller: doeController,
                    decoration: const InputDecoration(
                      labelText: 'DoE EPR registration number (optional)',
                      helperText:
                          'Usually absent — most companies engage Chokro before '
                          'registering.',
                    ),
                  ),
                  TextFormField(
                    controller: reasonController,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Note for the record (optional)',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: submitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: submitting || !collisionAcknowledged
                ? null
                : () async {
                    if (formKey.currentState?.validate() != true) return;
                    setState(() => submitting = true);
                    final snack = AppSnackBar.of(context);
                    final navigator = Navigator.of(context);
                    try {
                      await ref.read(adminProducerActionsProvider).approve(
                        orgId: organization.id,
                        sizeClass: sizeClass!,
                        obligationStartDate: startDate,
                        categories: categories.toList(),
                        complianceRoute: complianceRoute,
                        bin: _orNull(binController.text),
                        tradeLicenceNo: _orNull(licenceController.text),
                        doeRegistrationNo: _orNull(doeController.text),
                        reason: _orNull(reasonController.text),
                      );
                      navigator.pop();
                      snack.success('${organization.displayName} approved.');
                    } on OrgActionException catch (error) {
                      setState(() => submitting = false);
                      snack.failure(
                        error.needsReauthentication
                            ? 'Sign in again before approving an onboarding.'
                            : error.message,
                      );
                    } catch (_) {
                      setState(() => submitting = false);
                      snack.failure('The approval could not be saved.');
                    }
                  },
            child: Text(submitting ? 'Approving…' : 'Approve'),
          ),
        ],
      ),
    ),
  );

  binController.dispose();
  licenceController.dispose();
  doeController.dispose();
  reasonController.dispose();
}

/// Rejection, information request and suspension all need a stated reason.
///
/// One dialog for the three, because the requirement is identical: a decision
/// with no recorded reason is a dead end for the applicant and an unreviewable
/// act for the auditor.
Future<void> _openReasonDialog(
  BuildContext context,
  WidgetRef ref,
  OrganizationModel organization,
  String action,
) async {
  final controller = TextEditingController();
  var submitting = false;

  final (title, label, verb) = switch (action) {
    'reject' => ('Reject application', 'Why is it rejected?', 'Reject'),
    'requestInfo' => (
      'Request information',
      'What is needed?',
      'Send request',
    ),
    _ => ('Suspend organisation', 'Why is it suspended?', 'Suspend'),
  };

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: label,
              helperText: 'Recorded on the activity trail and shown to them.',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: submitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: submitting
                ? null
                : () async {
                    final reason = controller.text.trim();
                    final snack = AppSnackBar.of(context);
                    if (reason.length < 5) {
                      snack.failure('Give a reason of at least a few words.');
                      return;
                    }
                    setState(() => submitting = true);
                    final navigator = Navigator.of(context);
                    final actions = ref.read(adminProducerActionsProvider);
                    try {
                      switch (action) {
                        case 'reject':
                          await actions.reject(
                            orgId: organization.id,
                            reason: reason,
                          );
                        case 'requestInfo':
                          await actions.requestInformation(
                            orgId: organization.id,
                            reason: reason,
                          );
                        default:
                          await actions.suspend(
                            orgId: organization.id,
                            reason: reason,
                          );
                      }
                      navigator.pop();
                      snack.success('Recorded.');
                    } on OrgActionException catch (error) {
                      setState(() => submitting = false);
                      snack.failure(error.message);
                    } catch (_) {
                      setState(() => submitting = false);
                      snack.failure('That could not be saved.');
                    }
                  },
            child: Text(submitting ? 'Saving…' : verb),
          ),
        ],
      ),
    ),
  );

  controller.dispose();
}

Future<void> _openCreateDialog(BuildContext context, WidgetRef ref) async {
  final formKey = GlobalKey<FormState>();
  final legal = TextEditingController();
  final trade = TextEditingController();
  final contactName = TextEditingController();
  final contactEmail = TextEditingController();
  final district = TextEditingController();
  var submitting = false;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Add an obligated company'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const NoticeCard(
                    icon: Icons.info_outline,
                    message:
                        'The record opens as pending. Approving it is a separate '
                        'step, because that is where the size class and the '
                        'obligation clock are set against evidence.',
                  ),
                  const SizedBox(height: AppTheme.gapMd),
                  TextFormField(
                    controller: legal,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Registered legal name',
                    ),
                    validator: (v) => (v == null || v.trim().length < 2)
                        ? 'Enter the name on the trade licence.'
                        : null,
                  ),
                  TextFormField(
                    controller: trade,
                    decoration: const InputDecoration(
                      labelText: 'Trade or brand name',
                      helperText: 'What the packaging says.',
                    ),
                    validator: (v) => (v == null || v.trim().length < 2)
                        ? 'Enter the brand name.'
                        : null,
                  ),
                  TextFormField(
                    controller: contactName,
                    decoration: const InputDecoration(
                      labelText: 'Contact name',
                    ),
                  ),
                  TextFormField(
                    controller: contactEmail,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Contact email',
                    ),
                    validator: validateEmail,
                  ),
                  TextFormField(
                    controller: district,
                    decoration: const InputDecoration(labelText: 'District'),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: submitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: submitting
                ? null
                : () async {
                    if (formKey.currentState?.validate() != true) return;
                    setState(() => submitting = true);
                    final snack = AppSnackBar.of(context);
                    final navigator = Navigator.of(context);
                    try {
                      await ref.read(adminProducerActionsProvider).create({
                        'legalName': legal.text.trim(),
                        'tradeName': trade.text.trim(),
                        'contactName': contactName.text.trim(),
                        'contactEmail': contactEmail.text.trim(),
                        'district': district.text.trim(),
                      });
                      navigator.pop();
                      snack.success('Company record opened, pending review.');
                    } on OrgActionException catch (error) {
                      setState(() => submitting = false);
                      snack.failure(error.message);
                    } catch (_) {
                      setState(() => submitting = false);
                      snack.failure('The record could not be created.');
                    }
                  },
            child: Text(submitting ? 'Saving…' : 'Add'),
          ),
        ],
      ),
    ),
  );

  legal.dispose();
  trade.dispose();
  contactName.dispose();
  contactEmail.dispose();
  district.dispose();
}

Future<void> _openInviteDialog(
  BuildContext context,
  WidgetRef ref,
  OrganizationModel organization,
) async {
  final controller = TextEditingController();
  var orgRole = OrgRoles.owner;
  var submitting = false;

  final invitation = await showDialog<OrgInvitation>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Invite to ${organization.displayName}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Work email address',
                  helperText: 'The invitation is bound to this exact address.',
                ),
              ),
              const SizedBox(height: AppTheme.gapMd),
              DropdownButtonFormField<String>(
                initialValue: orgRole,
                decoration: const InputDecoration(labelText: 'Capability'),
                items: [
                  for (final value in OrgRoles.ordered)
                    DropdownMenuItem(
                      value: value,
                      child: Text(OrgRoles.label(value)),
                    ),
                ],
                onChanged: (value) => setState(() => orgRole = value ?? orgRole),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: submitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: submitting
                ? null
                : () async {
                    setState(() => submitting = true);
                    final snack = AppSnackBar.of(context);
                    final navigator = Navigator.of(context);
                    try {
                      final created = await ref
                          .read(adminProducerActionsProvider)
                          .inviteOwner(
                            orgId: organization.id,
                            email: controller.text.trim(),
                            orgRole: orgRole,
                          );
                      navigator.pop(created);
                    } on OrgActionException catch (error) {
                      setState(() => submitting = false);
                      snack.failure(error.message);
                    } catch (_) {
                      setState(() => submitting = false);
                      snack.failure('The invitation could not be issued.');
                    }
                  },
            child: Text(submitting ? 'Inviting…' : 'Issue invitation'),
          ),
        ],
      ),
    ),
  );

  controller.dispose();
  if (invitation == null || !context.mounted) return;

  final link = invitation.linkFor(ApiConfig.baseUrl) ?? '';
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Send this link now'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Invitation for ${invitation.email}'),
          const SizedBox(height: AppTheme.gapMd),
          const NoticeCard(
            icon: Icons.warning_amber_outlined,
            tone: NoticeTone.warning,
            message:
                'Shown once and unrecoverable — Chokro stores only a '
                'fingerprint of it. If it is lost, revoke and issue a new one.',
          ),
          const SizedBox(height: AppTheme.gapMd),
          SelectableText(
            link,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link));
            if (context.mounted) AppSnackBar.of(context).success('Link copied.');
          },
          child: const Text('Copy link'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('I have sent it'),
        ),
      ],
    ),
  );
}

/// Opens one organisation's timeline, recording the read first (EPR-46).
///
/// The order is deliberate: if the entry cannot be written, the view does not
/// open. An unrecorded read of a customer's compliance history is precisely
/// what the trail exists to prevent, so a logging failure is a reason not to
/// look rather than a reason to look quietly.
Future<void> _openActivity(
  BuildContext context,
  WidgetRef ref,
  OrganizationModel organization,
) async {
  final snack = AppSnackBar.of(context);
  try {
    await ref.read(adminProducerActionsProvider).recordView(organization.id);
  } catch (_) {
    snack.failure(
      'This view could not be recorded on the audit trail, so it was not '
      'opened.',
    );
    return;
  }
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (context) => _ActivityDialog(organization: organization),
  );
}

class _ActivityDialog extends ConsumerWidget {
  const _ActivityDialog({required this.organization});

  final OrganizationModel organization;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activity = ref.watch(adminProducerActivityProvider(organization.id));
    final chain = ref.watch(adminAuditChainProvider(organization.id));

    return AlertDialog(
      title: Text('${organization.displayName} — activity'),
      content: SizedBox(
        width: 620,
        height: 480,
        child: Column(
          children: [
            chain.when(
              loading: () => const LinearProgressIndicator(),
              error: (_, _) => const NoticeCard(
                icon: Icons.help_outline,
                tone: NoticeTone.warning,
                message: 'The chain could not be verified just now.',
              ),
              data: (report) => NoticeCard(
                icon: report.intact
                    ? Icons.verified_outlined
                    : Icons.report_problem_outlined,
                tone: report.intact ? NoticeTone.success : NoticeTone.error,
                title: report.intact
                    ? 'Chain intact over ${report.entriesChecked} entries'
                    : 'Chain problem detected',
                message: report.intact
                    ? 'Every entry links to the one before it and none has been '
                          'altered.'
                    : report.complete
                    ? 'Findings: ${report.findings.join(', ')}. This means an '
                          'entry has been altered, removed or truncated.'
                    : 'The log is longer than one verification pass, so this '
                          'is not a verdict over all of it.',
              ),
            ),
            const SizedBox(height: AppTheme.gapSm),
            Expanded(
              child: activity.when(
                loading: () => const ContentLoading(label: 'Loading…'),
                error: (error, _) => ErrorRetry(error: error),
                data: (entries) => entries.isEmpty
                    ? const Center(child: Text('Nothing recorded yet.'))
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          return ListTile(
                            dense: true,
                            leading: Text('#${entry.sequence ?? '?'}'),
                            title: Text(entry.summary),
                            subtitle: Text(
                              '${entry.actorName.isEmpty ? entry.actorUid : entry.actorName}'
                              ' · ${entry.actorRole}',
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

String? _orNull(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
