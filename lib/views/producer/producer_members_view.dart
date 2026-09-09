import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/producer_workspace_controller.dart';
import '../../core/api_config.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../core/validators.dart';
import '../../models/org_member_model.dart';
import '../../services/organization_service.dart';
import '../shared/app_shell.dart';
import '../shared/app_snackbar.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';

/// Who may use this company's workspace (EPR-3, SEC-8).
///
/// ## Why an invitation link is shown rather than emailed
///
/// Chokro has no mail service. Push notification runs through FCM, which sends
/// nothing to an inbox, and adding a transactional email provider is a billing
/// decision that has not been taken (§3.3's constraint, in a new place).
///
/// So the link is shown once to the person who issued it, to send however their
/// company already sends things. That is honest about the constraint, and it
/// has one genuine advantage over an emailed link: the token never passes
/// through Chokro's outbound mail at all. What it costs is that an invitation
/// cannot be re-sent — the token is not stored, only its digest — so the screen
/// says so at the moment it matters rather than in a help page.
class ProducerMembersView extends ConsumerWidget {
  const ProducerMembersView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(producerWorkspaceProvider);
    final membership = ref.watch(orgMembersProvider);

    return AppShell(
      title: 'People with access',
      child: workspace.when(
        loading: () => const ContentLoading(
          label: 'Loading…',
          slowHint: ContentLoading.serverWakingHint,
        ),
        error: (error, _) => ErrorRetry(
          error: error,
          onRetry: () => ref.invalidate(producerWorkspaceProvider),
        ),
        data: (data) {
          if (!data.isReady) {
            return const ContentEmpty(
              icon: Icons.no_accounts_outlined,
              title: 'No access',
              message:
                  'Open the workspace first — it will tell you what is '
                  'outstanding on this account.',
            );
          }

          final canManage = data.can(OrgRoles.owner);

          return membership.when(
            loading: () => const ContentLoading(label: 'Loading members…'),
            error: (error, _) => ErrorRetry(
              error: error,
              onRetry: () => ref.invalidate(orgMembersProvider),
            ),
            data: (rows) => _MembersBody(
              membership: rows,
              canManage: canManage,
              readOnlyOrganization: data.organization?.isReadOnly ?? true,
            ),
          );
        },
      ),
    );
  }
}

class _MembersBody extends ConsumerWidget {
  const _MembersBody({
    required this.membership,
    required this.canManage,
    required this.readOnlyOrganization,
  });

  final OrgMembership membership;
  final bool canManage;
  final bool readOnlyOrganization;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = membership.active;
    final pending = membership.pending;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppTheme.gapMd),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!canManage)
                const NoticeCard(
                  icon: Icons.visibility_outlined,
                  tone: NoticeTone.info,
                  message:
                      'You can see who has access. Only an Owner can invite '
                      'people, change what they can do, or remove them.',
                )
              else if (readOnlyOrganization)
                const NoticeCard(
                  icon: Icons.lock_outline,
                  tone: NoticeTone.warning,
                  message:
                      'This workspace is read-only, so no new invitations can '
                      'be issued. Existing access is unchanged.',
                ),

              const SizedBox(height: AppTheme.gapMd),
              Row(
                children: [
                  const Expanded(
                    child: SectionHeadingText('Members'),
                  ),
                  if (canManage && !readOnlyOrganization)
                    FilledButton.icon(
                      onPressed: () => _openInviteDialog(context, ref),
                      icon: const Icon(Icons.person_add_outlined),
                      label: const Text('Invite'),
                    ),
                ],
              ),
              const SizedBox(height: AppTheme.gapSm),

              if (active.isEmpty)
                const NoticeCard(
                  icon: Icons.group_outlined,
                  message: 'Nobody has joined this workspace yet.',
                )
              else
                for (final member in active)
                  _MemberRow(
                    member: member,
                    canManage: canManage,
                    isLastOwner: membership.wouldOrphan(member),
                  ),

              if (canManage) ...[
                const SizedBox(height: AppTheme.gapLg),
                const SectionHeadingText('Outstanding invitations'),
                const SizedBox(height: AppTheme.gapSm),
                if (pending.isEmpty)
                  const NoticeCard(
                    icon: Icons.mail_outline,
                    message: 'No invitations are waiting to be redeemed.',
                  )
                else
                  for (final invitation in pending)
                    _InvitationRow(invitation: invitation),
              ],

              const SizedBox(height: AppTheme.gapXl),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemberRow extends ConsumerWidget {
  const _MemberRow({
    required this.member,
    required this.canManage,
    required this.isLastOwner,
  });

  final OrgMemberModel member;
  final bool canManage;

  /// True when demoting or removing this person would leave the organisation
  /// with no owner. The server refuses it in the same transaction as the
  /// change; this greys the control and says why, rather than offering an
  /// action that fails a second later.
  final bool isLastOwner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                (member.displayName.isNotEmpty
                        ? member.displayName
                        : member.email)
                    .characters
                    .first
                    .toUpperCase(),
                style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
              ),
            ),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    member.displayName.isNotEmpty
                        ? member.displayName
                        : member.email,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    member.email,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppTheme.gapXs),
                  Text(
                    OrgRoles.description(member.orgRole),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppTheme.gapSm),
            if (!canManage)
              Chip(label: Text(OrgRoles.label(member.orgRole)))
            else
              _MemberMenu(member: member, isLastOwner: isLastOwner),
          ],
        ),
      ),
    );
  }
}

class _MemberMenu extends ConsumerWidget {
  const _MemberMenu({required this.member, required this.isLastOwner});

  final OrgMemberModel member;
  final bool isLastOwner;

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
    String success,
  ) async {
    final snack = AppSnackBar.of(context);
    try {
      await action();
      snack.success(success);
    } on OrgActionException catch (error) {
      // Re-authentication is a condition the person can fix, so it is named
      // rather than folded into a generic refusal (SEC-9).
      snack.failure(
        error.needsReauthentication
            ? 'Sign in again before changing who has access.'
            : error.message,
      );
    } catch (error) {
      snack.failure('That change could not be saved.');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(producerMemberActionsProvider);

    return PopupMenuButton<String>(
      tooltip: 'Change what ${member.displayName} can do',
      itemBuilder: (context) => [
        for (final role in OrgRoles.ordered)
          PopupMenuItem<String>(
            value: 'role:$role',
            enabled: role != member.orgRole && !(isLastOwner && role != OrgRoles.owner),
            child: Text(
              role == member.orgRole
                  ? '${OrgRoles.label(role)} (current)'
                  : 'Make ${OrgRoles.label(role)}',
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'remove',
          enabled: !isLastOwner,
          child: Text(
            isLastOwner ? 'Remove — needs another Owner first' : 'Remove access',
          ),
        ),
      ],
      onSelected: (value) {
        if (value == 'remove') {
          _confirmRemoval(context, ref, actions);
          return;
        }
        final role = value.split(':').last;
        _run(
          context,
          ref,
          () => actions.changeRole(uid: member.uid, orgRole: role),
          '${member.displayName} is now ${OrgRoles.label(role)}.',
        );
      },
      child: Chip(
        label: Text(OrgRoles.label(member.orgRole)),
        avatar: const Icon(Icons.arrow_drop_down, size: 18),
      ),
    );
  }

  Future<void> _confirmRemoval(
    BuildContext context,
    WidgetRef ref,
    ProducerMemberActions actions,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove access?'),
        content: Text(
          '${member.displayName.isNotEmpty ? member.displayName : member.email} '
          'will lose access to this workspace on their next request — not when '
          'their session expires.\n\n'
          'Their record is kept, so the activity trail still shows what they '
          'did and when they had access.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep access'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    await _run(
      context,
      ref,
      () => actions.remove(member.uid),
      'Access removed.',
    );
  }
}

class _InvitationRow extends ConsumerWidget {
  const _InvitationRow({required this.invitation});

  final OrgInvitation invitation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Card(
      child: ListTile(
        leading: const Icon(Icons.mail_outline),
        title: Text(invitation.email),
        subtitle: Text(
          '${OrgRoles.label(invitation.orgRole)}'
          '${invitation.expiresAt == null ? '' : ' · expires ${_shortDate(invitation.expiresAt!)}'}',
          style: theme.textTheme.bodySmall,
        ),
        trailing: TextButton(
          onPressed: () async {
            final snack = AppSnackBar.of(context);
            final actions = ref.read(producerMemberActionsProvider);
            try {
              await actions.revokeInvitation(invitation.invitationId);
              snack.success('Invitation revoked.');
            } on OrgActionException catch (error) {
              snack.failure(error.message);
            }
          },
          child: const Text('Revoke'),
        ),
      ),
    );
  }
}

Future<void> _openInviteDialog(BuildContext context, WidgetRef ref) async {
  final formKey = GlobalKey<FormState>();
  final emailController = TextEditingController();
  var role = OrgRoles.reporter;
  var submitting = false;

  final invitation = await showDialog<OrgInvitation>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Invite a colleague'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: emailController,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Work email address',
                  helperText: 'The invitation is bound to this exact address.',
                ),
                validator: validateEmail,
              ),
              const SizedBox(height: AppTheme.gapMd),
              DropdownButtonFormField<String>(
                initialValue: role,
                decoration: const InputDecoration(labelText: 'What they can do'),
                items: [
                  for (final value in OrgRoles.ordered)
                    DropdownMenuItem(
                      value: value,
                      child: Text(OrgRoles.label(value)),
                    ),
                ],
                onChanged: (value) => setState(() => role = value ?? role),
              ),
              const SizedBox(height: AppTheme.gapSm),
              Text(
                OrgRoles.description(role),
                style: Theme.of(context).textTheme.bodySmall,
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
                    if (formKey.currentState?.validate() != true) return;
                    setState(() => submitting = true);
                    final snack = AppSnackBar.of(context);
                    final navigator = Navigator.of(context);
                    try {
                      final created = await ref
                          .read(producerMemberActionsProvider)
                          .invite(
                            email: emailController.text.trim(),
                            orgRole: role,
                          );
                      navigator.pop(created);
                    } on OrgActionException catch (error) {
                      setState(() => submitting = false);
                      snack.failure(
                        error.needsReauthentication
                            ? 'Sign in again before inviting anyone.'
                            : error.message,
                      );
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

  emailController.dispose();

  if (invitation == null || !context.mounted) return;
  await _showInvitationLink(context, invitation);
}

/// Shows the one-time link.
///
/// Deliberately a dialog that has to be dismissed rather than a snackbar: the
/// token is not stored anywhere and this is the only moment it exists outside
/// the person's clipboard. A message that slides away after four seconds would
/// lose it.
Future<void> _showInvitationLink(
  BuildContext context,
  OrgInvitation invitation,
) async {
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
                'This link is shown once and cannot be recovered — Chokro '
                'stores only a fingerprint of it. If it is lost, revoke the '
                'invitation and issue a new one.',
          ),
          const SizedBox(height: AppTheme.gapMd),
          SelectableText(
            link,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link));
            if (context.mounted) {
              AppSnackBar.of(context).success('Link copied.');
            }
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

String _shortDate(DateTime value) {
  final local = value.toLocal();
  return '${local.day}/${local.month}/${local.year}';
}

/// A plain heading, for rows where [SectionHeading]'s icon slot is not wanted.
class SectionHeadingText extends StatelessWidget {
  const SectionHeadingText(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
  );
}
