import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/auth_controller.dart' show currentUserProvider;
import '../../controllers/claim_controller.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../models/claim_model.dart';
import '../shared/app_shell.dart';
import '../../models/appeal_model.dart';
import '../appeals/appeal_button.dart';
import '../shared/error_retry.dart';

/// Submitting a self-reported eco-action (F6.1, F6.2, F6.4).
///
/// The screen is honest with the user about what this route is. A claim pays
/// less than a disposal and always waits for a person, and saying so up front
/// is better than letting someone expect an instant credit and feel cheated.
class ClaimSubmitView extends ConsumerWidget {
  const ClaimSubmitView({super.key});

  static const double _maxContentWidth = 640;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(claimDraftProvider);
    final quota = ref.watch(claimQuotaProvider);
    final user = ref.watch(currentUserProvider).value;
    final theme = Theme.of(context);

    if (draft.submittedId != null) {
      return const _ClaimSubmitted();
    }

    // The quota was read, shown, and then ignored by both buttons. A Champion
    // at their weekly limit saw "You have used all 3 claims for this week" in
    // red and was still invited to choose an action, photograph it, upload the
    // evidence and submit — because nothing downstream stops them either.
    // `validClaimCreate` in `firestore.rules` does not read the quota, so the
    // write succeeds; the limit is enforced inside `approveClaim`, which fails
    // in front of the *administrator* days later, leaving them to reject by
    // hand a claim that was never approvable.
    //
    // `claimQuotaProvider`'s own comment says the point of reading it is "so a
    // user is not invited to photograph something they cannot submit". Only the
    // `data` branch blocks: a quota that failed to load or is still loading must
    // stay permissive, which is what the notice above already promises.
    final quotaSpent = quota.asData?.value.isExhausted ?? false;

    return AppShell(
      title: 'Log an eco-action',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: ClaimSubmitView._maxContentWidth,
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              quota.when(
                loading: () => const LinearProgressIndicator(),
                error: (error, _) => _Notice(
                  icon: Icons.cloud_off_outlined,
                  tone: theme.colorScheme.onSurfaceVariant,
                  text:
                      'Your weekly quota could not be checked. You can still '
                      'submit; the server will decide.',
                ),
                data: (q) => _Notice(
                  icon: q.isExhausted
                      ? Icons.block
                      : Icons.calendar_today_outlined,
                  tone: q.isExhausted
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                  text: q.summary,
                ),
              ),
              const SizedBox(height: 8),
              _Notice(
                icon: Icons.person_search_outlined,
                tone: theme.colorScheme.onSurfaceVariant,
                text:
                    'Every eco-action is checked by a person, so points '
                    'arrive after review rather than straight away. Disposals '
                    'at a registered bin are verified automatically and pay '
                    'more.',
              ),
              const SizedBox(height: 20),
              Text(
                'What did you do?',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              // RadioGroup owns the selection and the callback; the tiles
              // below only declare their value. Flutter 3.32 deprecated the
              // per-tile groupValue/onChanged pair.
              RadioGroup<ClaimActionType>(
                groupValue: draft.actionType,
                onChanged: (value) {
                  if (value != null) {
                    ref.read(claimDraftProvider.notifier).setActionType(value);
                  }
                },
                child: Column(
                  children: [
                    for (final type in ClaimActionType.values)
                      RadioListTile<ClaimActionType>(
                        value: type,
                        enabled: !draft.isSubmitting,
                        title: Text(type.label),
                        subtitle: Text(
                          type.evidenceHint,
                          style: theme.textTheme.bodySmall,
                        ),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Evidence',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                draft.actionType?.evidenceHint ??
                    'Choose an action above, then photograph it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              if (draft.hasPhoto)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    draft.photoBytes!,
                    height: 220,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    key: ObjectKey(draft.photoBytes),
                  ),
                ),
              if (draft.hasPhoto) const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: draft.isCapturing || draft.isSubmitting || quotaSpent
                    ? null
                    : () =>
                          ref.read(claimDraftProvider.notifier).capturePhoto(),
                icon: draft.isCapturing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        kIsWeb
                            ? Icons.add_photo_alternate_outlined
                            : Icons.photo_camera_outlined,
                      ),
                label: Text(
                  kIsWeb
                      ? (draft.hasPhoto
                            ? 'Choose another photo'
                            : 'Choose photo')
                      : (draft.hasPhoto ? 'Retake photo' : 'Take photo'),
                ),
              ),
              if (draft.error != null) ...[
                const SizedBox(height: 14),
                Text(
                  draft.error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: AppTheme.gapLg),
              Text(
                'Tell the story behind it',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppTheme.gapXs),
              Text(
                'Optional — a short, personal detail makes the action useful '
                'and encouraging when it is shared.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppTheme.gapSm),
              TextFormField(
                key: const ValueKey('claim-story-field'),
                initialValue: draft.story,
                minLines: 3,
                maxLines: 6,
                maxLength: 800,
                readOnly: draft.isSubmitting,
                textCapitalization: TextCapitalization.sentences,
                onChanged: ref.read(claimDraftProvider.notifier).setStory,
                decoration: const InputDecoration(
                  labelText: 'Your story',
                  hintText:
                      'What inspired you, who joined you, or what changed?',
                  alignLabelWithHint: true,
                  prefixIcon: Icon(Icons.auto_stories_outlined),
                ),
              ),
              _Notice(
                icon: Icons.privacy_tip_outlined,
                tone: theme.colorScheme.onSurfaceVariant,
                text:
                    'If you choose anonymous sharing, avoid names, addresses, '
                    'school or workplace details in the story and photo.',
              ),
              const SizedBox(height: AppTheme.gapLg),
              Text(
                'How may Chokro share this action?',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppTheme.gapXs),
              Text(
                'Choose one before submitting. This choice is saved with this '
                'action and controls the public photocard.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppTheme.gapSm),
              RadioGroup<ClaimPublicationMode>(
                groupValue: draft.publicationMode,
                onChanged: (mode) {
                  if (mode != null) {
                    ref
                        .read(claimDraftProvider.notifier)
                        .setPublicationMode(mode);
                  }
                },
                child: Column(
                  children: [
                    Card(
                      margin: EdgeInsets.zero,
                      child: RadioListTile<ClaimPublicationMode>(
                        value: ClaimPublicationMode.anonymous,
                        enabled: !draft.isSubmitting,
                        secondary: const Icon(Icons.visibility_off_outlined),
                        title: const Text('Share anonymously'),
                        subtitle: const Text(
                          'Chokro may share the action photo and story without '
                          'your name or profile picture.',
                        ),
                      ),
                    ),
                    const SizedBox(height: AppTheme.gapSm),
                    Card(
                      margin: EdgeInsets.zero,
                      child: RadioListTile<ClaimPublicationMode>(
                        value: ClaimPublicationMode.named,
                        enabled:
                            !draft.isSubmitting &&
                            (user?.hasProfilePhoto ?? false),
                        secondary: const Icon(Icons.account_circle_outlined),
                        title: const Text('Share with my name and picture'),
                        subtitle: Text(
                          user?.hasProfilePhoto ?? false
                              ? 'Chokro may credit your saved name and current '
                                    'profile picture on the public photocard.'
                              : 'Add a profile picture first to use this option.',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (!(user?.hasProfilePhoto ?? false)) ...[
                const SizedBox(height: AppTheme.gapXs),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: draft.isSubmitting
                        ? null
                        : () => context.push('/profile'),
                    icon: const Icon(Icons.add_a_photo_outlined),
                    label: const Text('Add profile picture'),
                  ),
                ),
              ],
              if (draft.publicationMode == null) ...[
                const SizedBox(height: AppTheme.gapXs),
                Text(
                  'Choose a public sharing option to continue.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: AppTheme.gapLg),
              FilledButton.icon(
                onPressed:
                    draft.isReadyToSubmit && !draft.isSubmitting && !quotaSpent
                    ? () async {
                        await ref.read(claimDraftProvider.notifier).submit();
                        if (!context.mounted) return;
                        final error = ref.read(claimDraftProvider).error;
                        if (error == null) return;
                        final messenger = ScaffoldMessenger.of(context);
                        messenger.hideCurrentSnackBar();
                        messenger.showSnackBar(SnackBar(content: Text(error)));
                      }
                    : null,
                icon: draft.isSubmitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined),
                label: Text(
                  draft.isSubmitting ? 'Submitting…' : 'Submit eco-action',
                ),
              ),

              // A disabled control has to say why it is disabled. The quota
              // banner is at the top of a long scrolling form, so by the time
              // the reader reaches a greyed-out Submit it is off screen.
              if (quotaSpent) ...[
                const SizedBox(height: AppTheme.gapSm),
                Text(
                  'Submitting is paused until your weekly limit resets on '
                  'Monday. Disposals at a registered bin are not affected.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],

              // ── Earlier claims ───────────────────────────────────────────
              //
              // [ClaimHistoryList] existed but was never mounted anywhere, so a
              // user could log an eco-action and then had no way at all to see
              // what had become of it — the disposal history screen only lists
              // disposals. Every claim waits on a person, which makes "where is
              // mine" the obvious next question, and the answer was unreachable.
              const SizedBox(height: AppTheme.gapXl),
              const Divider(),
              const SizedBox(height: AppTheme.gapMd),
              Text(
                'Your eco-actions',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppTheme.gapSm),
              const ClaimHistoryList(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClaimSubmitted extends ConsumerWidget {
  const _ClaimSubmitted();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final draft = ref.watch(claimDraftProvider);
    final publication =
        draft.submittedPublicationMode == ClaimPublicationMode.named
        ? 'If approved, Chokro may share it with your saved name and profile picture.'
        : 'If approved, Chokro may share it as an anonymous Champion story.';
    return AppShell(
      title: 'Claim submitted',
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle_outline,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text('Sent for review', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'A reviewer will look at your photo. Points are added to your '
                'wallet only if it is approved, and you will be told either '
                'way. $publication',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppTheme.gapLg),
              // "Log another" was the only way off this screen, so a user who
              // was finished had to log a second claim they did not want, or use
              // the system back gesture, to leave.
              FilledButton(
                onPressed: () {
                  ref.read(claimDraftProvider.notifier).reset();
                  context.go('/home');
                },
                child: const Text('Done'),
              ),
              const SizedBox(height: AppTheme.gapSm),
              TextButton(
                onPressed: () => ref.read(claimDraftProvider.notifier).reset(),
                child: const Text('Log another'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A user's own claim history, appended to the submission screen's flow.
class ClaimHistoryList extends ConsumerWidget {
  const ClaimHistoryList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final claims = ref.watch(userClaimsProvider);

    return claims.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ErrorRetry(
        error: error,
        title: 'Your eco-actions',
        onRetry: () => ref.invalidate(userClaimsProvider),
      ),
      data: (items) {
        if (items.isEmpty) {
          return Text(
            'No eco-actions logged yet.',
            style: theme.textTheme.bodySmall,
          );
        }
        return Column(
          children: [
            for (final claim in items) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  claim.status.isApproved
                      ? Icons.check_circle_outline
                      : claim.status.isRejected
                      ? Icons.cancel_outlined
                      : Icons.hourglass_empty_outlined,
                  color: claim.status.isApproved
                      ? theme.colorScheme.primary
                      : claim.status.isRejected
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
                title: Text(claim.actionType.label),
                subtitle: Text(
                  [
                    claim.userFacingStatus,
                    claim.publicationLabel,
                    formatAge(claim.createdAt),
                    if (claim.status.isRejected &&
                        claim.rejectionReason != null)
                      claim.rejectionReason!,
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
                trailing: claim.status.isApproved
                    ? Text(
                        '+${claim.creditedPoints}',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      )
                    : null,
              ),
              // The same appeal route as a rejected disposal (F5.4). A claim is
              // the weaker verification route, so a rejection here rests on one
              // administrator's reading of one photograph — which is exactly the
              // decision most worth being able to answer.
              if (claim.status.isRejected && claim.id != null)
                AppealButton(
                  subjectType: AppealSubject.claim,
                  subjectId: claim.id!,
                ),
            ],
          ],
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.tone, required this.text});

  final IconData icon;
  final Color tone;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: tone),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tone),
          ),
        ),
      ],
    );
  }
}
