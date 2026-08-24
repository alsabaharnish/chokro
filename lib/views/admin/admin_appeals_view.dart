import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/appeals_controller.dart';
import '../../core/label_format.dart';
import '../../core/network_errors.dart';
import '../../core/theme.dart';
import '../../models/appeal_model.dart';
import '../appeals/appeals_view.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';

/// The administrator's appeal queue (F5.4).
///
/// Oldest first, like the disposal and claim queues, so the earliest appeal is
/// not the one left waiting longest.
///
/// Both outcomes require a written answer, and the rules enforce it — a status
/// with no words is not an answer to somebody who was already told "rejected"
/// once with a reason they disputed. Upholding an appeal does **not** credit
/// anything: it records that the decision was wrong, and the user submits again
/// so the checks actually run.
class AdminAppealsView extends ConsumerWidget {
  const AdminAppealsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appealsAsync = ref.watch(pendingAppealsProvider);

    return AppShell(
      title: 'Appeals',
      child: appealsAsync.when(
        loading: () => const ContentLoading(label: 'Loading the queue…'),
        error: (error, _) => ErrorRetry(
          error: error,
          title: 'The appeal queue',
          onRetry: () => ref.invalidate(pendingAppealsProvider),
        ),
        data: (appeals) {
          if (appeals.isEmpty) {
            return const ContentEmpty(
              icon: Icons.gavel_outlined,
              title: 'Nothing to answer',
              message: 'No appeal is waiting for a decision.',
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.gapMd,
              AppTheme.gapMd,
              AppTheme.gapMd,
              AppTheme.gapXl,
            ),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppTheme.maxDashboardWidth,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _QueueNotice(count: appeals.length),
                      const SizedBox(height: AppTheme.gapMd),
                      for (final appeal in appeals) ...[
                        _AdminAppealCard(appeal: appeal),
                        const SizedBox(height: AppTheme.gapMd),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AdminAppealCard extends ConsumerStatefulWidget {
  const _AdminAppealCard({required this.appeal});

  final AppealModel appeal;

  @override
  ConsumerState<_AdminAppealCard> createState() => _AdminAppealCardState();
}

class _AdminAppealCardState extends ConsumerState<_AdminAppealCard> {
  bool _photoLoaded = false;
  bool _confirmed = false;
  int _imageAttempt = 0;

  AppealSubjectReference get _subject => (
    subjectType: widget.appeal.subjectType,
    subjectId: widget.appeal.subjectId,
  );

  void _setPhotoLoaded(bool loaded) {
    if (!mounted || loaded == _photoLoaded) return;
    setState(() {
      _photoLoaded = loaded;
      if (!loaded) _confirmed = false;
    });
  }

  Future<void> _retryPhoto(String url) async {
    _setPhotoLoaded(false);
    await CachedNetworkImage.evictFromCache(url);
    if (!mounted) return;
    setState(() => _imageAttempt += 1);
  }

  @override
  Widget build(BuildContext context) {
    final evidenceAsync = ref.watch(appealSubjectEvidenceProvider(_subject));
    final evidence = evidenceAsync.value;
    final canDecide = evidence?.hasPhoto == true && _photoLoaded && _confirmed;

    return AppealCard(
      appeal: widget.appeal,
      evidence: evidenceAsync.when(
        loading: () => const _EvidenceLoading(),
        error: (_, _) => _EvidenceFailure(
          message: 'The original submission could not be loaded.',
          onRetry: () =>
              ref.invalidate(appealSubjectEvidenceProvider(_subject)),
        ),
        data: (evidence) {
          if (evidence == null || !evidence.hasPhoto) {
            return const _EvidenceFailure(
              message:
                  'The original submission or its photograph is missing. '
                  'This appeal cannot be decided safely.',
            );
          }
          return _EvidencePanel(
            key: ValueKey('${evidence.photoUrl}:$_imageAttempt'),
            evidence: evidence,
            photoLoaded: _photoLoaded,
            confirmed: _confirmed,
            onPhotoStateChanged: _setPhotoLoaded,
            onConfirmationChanged: (value) {
              setState(() => _confirmed = value);
            },
            onRetryPhoto: () => _retryPhoto(evidence.photoUrl),
          );
        },
      ),
      action: _DecisionButtons(
        appeal: widget.appeal,
        evidenceConfirmed: canDecide,
      ),
    );
  }
}

class _EvidenceLoading extends StatelessWidget {
  const _EvidenceLoading();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppTheme.gapMd),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
    ),
    child: const Row(
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: 12),
        Expanded(child: Text('Loading the original evidence…')),
      ],
    ),
  );
}

class _EvidenceFailure extends StatelessWidget {
  const _EvidenceFailure({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppTheme.gapMd),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Row(
        children: [
          Icon(Icons.hide_image_outlined, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _EvidencePanel extends StatelessWidget {
  const _EvidencePanel({
    super.key,
    required this.evidence,
    required this.photoLoaded,
    required this.confirmed,
    required this.onPhotoStateChanged,
    required this.onConfirmationChanged,
    required this.onRetryPhoto,
  });

  final AppealSubjectEvidence evidence;
  final bool photoLoaded;
  final bool confirmed;
  final ValueChanged<bool> onPhotoStateChanged;
  final ValueChanged<bool> onConfirmationChanged;
  final VoidCallback onRetryPhoto;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // `Material`, not a `Container` with a `BoxDecoration`.
    //
    // This card ends in a `CheckboxListTile`, and a ListTile paints its
    // background and its ink splashes onto the nearest `Material` *ancestor* —
    // which, behind an opaque `DecoratedBox`, is hidden by it. Flutter asserts
    // on exactly this ("ListTile background color or ink splashes may be
    // invisible"), once per appeal in the queue, and the visible cost is that
    // the confirmation an administrator must tick before deciding an appeal
    // gave no press feedback at all.
    //
    // A `Material` with the same colour and a `RoundedRectangleBorder` carrying
    // the border as its `side` renders identically and gives the ink a surface
    // of its own. That is also the shape `cardTheme` uses for every other card.
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppTheme.gapMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ORIGINAL SUBMISSION',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: AppTheme.gapXs),
                Text(
                  evidence.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (evidence.submittedAt != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Submitted ${formatAge(evidence.submittedAt)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          AspectRatio(
            aspectRatio: 4 / 3,
            child: CachedNetworkImage(
              imageUrl: evidence.photoUrl,
              fit: BoxFit.contain,
              imageBuilder: (context, imageProvider) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  onPhotoStateChanged(true);
                });
                return Ink.image(
                  image: imageProvider,
                  fit: BoxFit.contain,
                  child: InkWell(
                    onTap: () => _showFullPhoto(context, imageProvider),
                  ),
                );
              },
              placeholder: (_, _) => ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: const Center(child: CircularProgressIndicator()),
              ),
              errorWidget: (_, _, _) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  onPhotoStateChanged(false);
                });
                return ColoredBox(
                  color: scheme.errorContainer,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.broken_image_outlined,
                          color: scheme.onErrorContainer,
                        ),
                        const SizedBox(height: AppTheme.gapSm),
                        Text(
                          'The evidence photo did not load.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onErrorContainer,
                          ),
                        ),
                        TextButton(
                          onPressed: onRetryPhoto,
                          child: const Text('Retry photo'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (evidence.rejectionReason?.trim().isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.gapMd,
                AppTheme.gapMd,
                AppTheme.gapMd,
                0,
              ),
              child: Text(
                'Original rejection: ${evidence.rejectionReason}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          CheckboxListTile(
            value: confirmed,
            onChanged: photoLoaded
                ? (value) => onConfirmationChanged(value ?? false)
                : null,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('I reviewed the original photograph'),
            subtitle: Text(
              photoLoaded
                  ? 'Required before an appeal decision.'
                  : 'Wait for the photograph to load.',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showFullPhoto(
    BuildContext context,
    ImageProvider imageProvider,
  ) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(AppTheme.gapMd),
        child: Stack(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960, maxHeight: 760),
              child: InteractiveViewer(
                minScale: .8,
                maxScale: 5,
                child: Image(image: imageProvider, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: IconButton.filled(
                tooltip: 'Close photograph',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueNotice extends StatelessWidget {
  const _QueueNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      color: scheme.surfaceContainerHighest,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: scheme.onSurfaceVariant),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: Text(
                '$count waiting, oldest first. Upholding an appeal records that '
                'the decision was wrong; it credits nothing. The user submits '
                'again and the verification runs properly — the lockout was '
                'already released when their submission was rejected.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DecisionButtons extends ConsumerStatefulWidget {
  const _DecisionButtons({
    required this.appeal,
    required this.evidenceConfirmed,
  });

  final AppealModel appeal;
  final bool evidenceConfirmed;

  @override
  ConsumerState<_DecisionButtons> createState() => _DecisionButtonsState();
}

class _DecisionButtonsState extends ConsumerState<_DecisionButtons> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.evidenceConfirmed) ...[
          Text(
            'Review and confirm the original photograph to enable a decision.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.gapSm),
        ],
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy || !widget.evidenceConfirmed
                    ? null
                    : () => _decide(uphold: false),
                icon: const Icon(Icons.thumb_down_outlined),
                label: const Text('Decline'),
              ),
            ),
            const SizedBox(width: AppTheme.gapSm),
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy || !widget.evidenceConfirmed
                    ? null
                    : () => _decide(uphold: true),
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.thumb_up_outlined),
                label: const Text('Uphold'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _decide({required bool uphold}) async {
    final response = await _askForAnswer(uphold: uphold);
    if (response == null || !mounted) return;

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(appealActionsProvider)
          .resolve(
            appealId: widget.appeal.id!,
            uphold: uphold,
            response: response,
          );
      messenger.showSnackBar(
        SnackBar(content: Text(uphold ? 'Appeal upheld.' : 'Appeal declined.')),
      );
    } on AppealValidationException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      messenger.showSnackBar(
        // Resolving an appeal is a Firestore write the rules can refuse for
        // several reasons at once, and `$error` handed the administrator the
        // vendor prefix instead of any of them.
        SnackBar(
          content: Text(
            'The decision was not recorded. ${friendlyErrorMessage(error)}',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Asks for the written answer both outcomes require.
  ///
  /// Deliberately not `showRejectionReasonDialog`: that one is worded for
  /// refusing something, and this dialog is also used to *uphold*. Reusing it
  /// would put "Reject" on the button that agrees with the user.
  Future<String?> _askForAnswer({required bool uphold}) {
    return showDialog<String>(
      context: context,
      builder: (context) => _AnswerDialog(uphold: uphold),
    );
  }
}

class _AnswerDialog extends StatefulWidget {
  const _AnswerDialog({required this.uphold});

  final bool uphold;

  @override
  State<_AnswerDialog> createState() => _AnswerDialogState();
}

class _AnswerDialogState extends State<_AnswerDialog> {
  // A StatefulWidget rather than a controller made inside an async helper —
  // that pattern leaked one controller per dialog in three screens before
  // `showRejectionReasonDialog` was extracted, and the same trap applies here.
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final problem = AppealModel.validateResponse(_controller.text);

    return AlertDialog(
      title: Text(widget.uphold ? 'Uphold this appeal' : 'Decline this appeal'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.uphold
                ? 'Tell them the decision was wrong and what to do next — '
                      'usually, submit again.'
                : 'Tell them why the original decision stands.',
          ),
          const SizedBox(height: AppTheme.gapMd),
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            maxLength: AppealModel.responseMax,
            decoration: InputDecoration(
              hintText: 'The user reads this exactly as you write it.',
              // Shown, not merely computed.
              //
              // The comment on the button below says the helper text explains
              // why it is disabled, and nothing rendered `problem` — so an
              // administrator two words into an answer saw a dead button and no
              // reason for it. `_RejectionReasonDialog` counts the shortfall
              // down for exactly this case; this dialog now does too.
              helperText: problem ?? 'This is shown to the user.',
              helperMaxLines: 2,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // Disabled until there is something to send, and the helper text says
          // why — rather than accepting an empty answer and failing at the
          // rules, which give no reason.
          onPressed: problem != null
              ? null
              : () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(widget.uphold ? 'Uphold' : 'Decline'),
        ),
      ],
    );
  }
}
