import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/submission_history_controller.dart';
import '../../controllers/disposal_controller.dart'
    show verificationServiceProvider;
import '../../core/image_delivery.dart';
import '../../core/label_format.dart';
import '../../models/disposal_model.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';
import '../../models/appeal_model.dart';
import '../appeals/appeal_button.dart';
import '../shared/status_chip.dart';
import '../../core/network_errors.dart';

/// Every submission the signed-in user has made, newest first (F7.2).
///
/// Read-only by construction. The screen exists to answer three questions a
/// user has after submitting: was it accepted, why not, and what was it worth.
class SubmissionHistoryView extends ConsumerWidget {
  const SubmissionHistoryView({super.key});

  /// Above this width the list stops stretching and centres. One number, no
  /// LayoutBuilder needed — the list is single-column at every size, so only
  /// the measure changes.
  static const double _maxContentWidth = 720;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(submissionHistoryProvider);

    return AppShell(
      title: 'My submissions',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxContentWidth),
          child: async.when(
            loading: () =>
                const ContentLoading(label: 'Loading your submissions…'),
            error: (error, _) => _ErrorState(
              error: error,
              onRetry: () => ref.invalidate(submissionHistoryProvider),
            ),
            data: (items) {
              if (items.isEmpty) return const _EmptyState();
              return RefreshIndicator(
                onRefresh: () async {
                  try {
                    final refresh = ref.refresh(
                      submissionHistoryProvider.future,
                    );
                    await refresh;
                  } catch (_) {
                    // The provider retains the error and renders it here.
                  }
                },
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) => _SubmissionCard(
                    key: ValueKey(items[index].id),
                    disposal: items[index],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SubmissionCard extends ConsumerStatefulWidget {
  const _SubmissionCard({super.key, required this.disposal});

  final DisposalModel disposal;

  @override
  ConsumerState<_SubmissionCard> createState() => _SubmissionCardState();
}

class _SubmissionCardState extends ConsumerState<_SubmissionCard> {
  bool _retrying = false;
  String? _retryMessage;

  Future<void> _retryVerification() async {
    final id = widget.disposal.id;
    if (id == null || _retrying) return;

    setState(() {
      _retrying = true;
      _retryMessage = null;
    });

    final outcome = await ref.read(verificationServiceProvider).verify(id);
    if (!mounted) return;
    setState(() {
      _retrying = false;
      _retryMessage = outcome.userMessage;
    });
  }

  @override
  Widget build(BuildContext context) {
    final disposal = widget.disposal;
    final theme = Theme.of(context);
    final status = disposal.status;
    final points = disposal.pointsAwarded;
    final reason = disposal.rejectionReason;
    final flags = disposal.flags;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Thumbnail(url: disposal.photoUrl),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        humanise(disposal.itemType),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          itemCount(disposal.declaredItemCount),
                          formatAge(disposal.createdAt),
                        ].where((s) => s.isNotEmpty).join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _PointsBadge(points: points, status: status),
              ],
            ),
            // The status sits on its own line rather than inside the middle
            // column. In that column it was competing with a 64 px thumbnail
            // and the points badge for what was left of the row — 91 px on a
            // 320 dp phone, against the ~295 px "Approved automatically" needs
            // — so it overflowed on every handset. Given the full card width it
            // fits on one line on any phone, and it reads better: the status is
            // the thing a submitter opens this screen to check.
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: StatusChip(status: disposal.status),
            ),
            if (status.isRejected && reason != null && reason.isNotEmpty)
              _Note(
                icon: Icons.info_outline,
                tone: theme.colorScheme.error,
                title: 'Why it was rejected',
                body: reason,
              ),
            // Offered on every rejection, reason or not. A rejection with no
            // recorded reason is exactly the one most worth disputing.
            if (status.isRejected && disposal.id != null)
              AppealButton(
                subjectType: AppealSubject.disposal,
                subjectId: disposal.id!,
              ),
            if (status.isPending && flags.isNotEmpty)
              _Note(
                icon: Icons.flag_outlined,
                tone: theme.colorScheme.onSurfaceVariant,
                title: 'Sent for review because',
                body: flags.map(humanise).join(' · '),
              ),
            if (disposal.needsVerificationRetry) ...[
              _Note(
                icon: Icons.sync_problem_outlined,
                tone: theme.colorScheme.error,
                title: 'Verification was interrupted',
                body:
                    'Retry the secure checks so this submission can be '
                    'approved or sent to a reviewer.',
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: _retrying ? null : _retryVerification,
                icon: _retrying
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(_retrying ? 'Retrying…' : 'Retry verification'),
              ),
              if (_retryMessage != null) ...[
                const SizedBox(height: 8),
                Text(_retryMessage!, style: theme.textTheme.bodySmall),
              ],
            ],
            if (status.isPending &&
                flags.isEmpty &&
                !disposal.needsVerificationRetry)
              _Note(
                icon: Icons.schedule_outlined,
                tone: theme.colorScheme.onSurfaceVariant,
                title: 'In the queue',
                body:
                    'A reviewer will check this submission. Your balance stays '
                    'the same until they do.',
              ),
          ],
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: 64,
      height: 64,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.image_outlined,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: url.isEmpty
          ? placeholder
          // A history screen is fifty rows of evidence photographs. Full
          // size, that is half a gigabyte of decoded bitmaps to draw fifty
          // 64 px squares.
          : CachedNetworkImage(
              imageUrl: thumbnailUrl(url, width: 64),
              memCacheWidth: decodeWidthFor(64),
              width: 64,
              height: 64,
              fit: BoxFit.cover,
              placeholder: (_, _) => placeholder,
              errorWidget: (_, _, _) => placeholder,
            ),
    );
  }
}

class _PointsBadge extends StatelessWidget {
  const _PointsBadge({required this.points, required this.status});

  final int? points;
  final DisposalStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final awarded = points != null && points! > 0;

    if (!awarded) {
      return Text(
        status.isRejected ? 'No points' : '—',
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '+$points',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.primary,
          ),
        ),
        Text(
          'points',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({
    required this.icon,
    required this.tone,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color tone;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: tone),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: tone,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(body, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const ContentEmpty(
      icon: Icons.recycling_outlined,
      title: 'No submissions yet',
      message:
          'Scan a registered bin to record your first disposal. Its '
          'status, decision reason and points will appear here.',
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 40,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 14),
            Text(
              'Submissions did not load',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              // Interpreted, not printed. `'$error'` rendered the vendor
              // prefix and class name straight to the user.
              friendlyErrorMessage(error),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
