import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../controllers/seller_application_controller.dart';
import '../../models/seller_application_model.dart';
import '../shared/app_shell.dart';
import '../shared/app_snackbar.dart';
import '../shared/rejection_reason_dialog.dart';
import '../shared/error_retry.dart';

class AdminApplicationsView extends ConsumerWidget {
  const AdminApplicationsView({super.key});

  Future<void> _approve(
    BuildContext context,
    WidgetRef ref,
    SellerApplicationModel app,
  ) async {
    await ref
        .read(sellerApplicationControllerProvider.notifier)
        .approve(app.id);
    if (!context.mounted) return;
    _report(
      context,
      ref,
      success:
          '${app.businessName} approved — applicant is now a 3ZERO Greenpreneur',
    );
  }

  Future<void> _reject(
    BuildContext context,
    WidgetRef ref,
    SellerApplicationModel app,
  ) async {
    final reason = await showRejectionReasonDialog(
      context,
      title: 'Reject ${app.businessName}',
      hintText: 'The business description does not explain what you sell.',
    );
    if (reason == null || !context.mounted) return;

    await ref
        .read(sellerApplicationControllerProvider.notifier)
        .reject(app.id, reason);
    if (!context.mounted) return;
    _report(context, ref, success: 'Application rejected');
  }

  /// One place that turns the controller's outcome into a snackbar.
  ///
  /// Both actions on this screen were duplicating this, and both were passing
  /// `error.toString()` straight to the user and colouring it with a hardcoded
  /// `Colors.red` — which is the same red in dark mode, where it glares.
  static void _report(
    BuildContext context,
    WidgetRef ref, {
    required String success,
  }) {
    final error = ref.read(sellerApplicationControllerProvider).error;
    final notify = AppSnackBar.of(context);

    // The failure branch used to paint `errorContainer` behind SnackBar's
    // default `onInverseSurface` text, which is 1.70:1 — so an administrator
    // whose decision failed to save was told so in text they could not read,
    // and the application stayed in the queue looking unreviewed.
    if (error != null) {
      notify.failure(
        'That did not go through. Check your connection and try again.',
      );
      return;
    }
    notify.success(success);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingAsync = ref.watch(pendingApplicationsProvider);
    final theme = Theme.of(context);
    final dateFormat = DateFormat('d MMM y, h:mm a');

    return AppShell(
      title: 'Greenpreneur applications',
      child: pendingAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorRetry(
          error: e,
          title: 'The application queue',
          onRetry: () => ref.invalidate(pendingApplicationsProvider),
        ),
        data: (apps) {
          if (apps.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.inbox_outlined,
                    size: 48,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(height: 12),
                  const Text('Nothing pending review'),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(24),
            itemCount: apps.length,
            itemBuilder: (context, i) {
              final app = apps[i];
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Card(
                    margin: const EdgeInsets.only(bottom: 16),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            app.businessName,
                            style: theme.textTheme.titleLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            // Null for one round trip after the write, now that
                            // `createdAt` comes from the server per §6.
                            'Submitted ${app.createdAt == null ? 'just now' : dateFormat.format(app.createdAt!)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(app.description),
                          const SizedBox(height: 20),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => _reject(context, ref, app),
                                child: const Text('Reject'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: () => _approve(context, ref, app),
                                child: const Text('Approve'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
