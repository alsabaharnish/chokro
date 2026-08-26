import 'package:flutter/material.dart';

import '../../core/network_errors.dart';
import '../../core/theme.dart';

/// The error branch of a loading screen, with a way out of it.
///
/// Written because eight screens each had their own, and four of those had no
/// retry at all — `admin_applications`, `admin_claims`, `admin_disposals` and
/// `admin_users`. An administrator whose queue failed to load on a flaky
/// connection had one option: leave the screen and come back. On the review queue
/// that is the screen they are meant to sit on all shift.
///
/// The message comes from [friendlyErrorMessage] rather than `'$error'`. What
/// those screens rendered was
/// `[cloud_firestore/permission-denied] Missing or insufficient permissions.`,
/// which names a vendor, a class and no next step.
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.error, this.onRetry, this.title});

  /// Whatever landed in the error branch. Interpreted, never printed raw.
  final Object? error;

  /// Omit only when there is genuinely nothing to re-attempt — a stream that
  /// rebuilds itself, for instance. A retry button that does nothing is worse
  /// than none.
  final VoidCallback? onRetry;

  /// What failed to load, in the caller's words: "The review queue", "Accounts".
  /// Gives the reader the subject the interpreted message does not carry.
  final String? title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppTheme.gapMd),
            if (title != null) ...[
              Text(
                '$title could not be loaded',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppTheme.gapXs),
            ],
            Text(
              friendlyErrorMessage(error),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: AppTheme.gapMd),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
