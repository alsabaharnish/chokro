import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../controllers/seller_application_controller.dart';
import '../../models/seller_application_model.dart';
import '../shared/app_shell.dart';

class AdminApplicationsView extends ConsumerWidget {
  const AdminApplicationsView({super.key});

  Future<void> _approve(
      BuildContext context, WidgetRef ref, SellerApplicationModel app) async {
    await ref
        .read(sellerApplicationControllerProvider.notifier)
        .approve(app.id);
    if (!context.mounted) return;
    final error = ref.read(sellerApplicationControllerProvider).error;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error?.toString() ??
            '${app.businessName} approved — applicant is now a seller'),
        backgroundColor: error != null ? Colors.red : null,
      ),
    );
  }

  Future<void> _reject(
      BuildContext context, WidgetRef ref, SellerApplicationModel app) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Reject ${app.businessName}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Reason (shown to the applicant)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) Navigator.pop(context, text);
            },
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (reason == null) return;

    await ref
        .read(sellerApplicationControllerProvider.notifier)
        .reject(app.id, reason);
    if (!context.mounted) return;
    final error = ref.read(sellerApplicationControllerProvider).error;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error?.toString() ?? 'Application rejected'),
        backgroundColor: error != null ? Colors.red : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingAsync = ref.watch(pendingApplicationsProvider);
    final theme = Theme.of(context);
    final dateFormat = DateFormat('d MMM y, h:mm a');

    return AppShell(
      title: 'Seller applications',
      child: pendingAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load the queue: $e'),
          ),
        ),
        data: (apps) {
          if (apps.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.inbox_outlined,
                      size: 48, color: theme.colorScheme.outline),
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
                          Text(app.businessName,
                              style: theme.textTheme.titleLarge),
                          const SizedBox(height: 4),
                          Text(
                            'Submitted ${dateFormat.format(app.createdAt)}',
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
