import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../controllers/seller_application_controller.dart';
import '../../core/constants.dart';
import '../shared/app_shell.dart';

class SellerApplicationView extends ConsumerStatefulWidget {
  const SellerApplicationView({super.key});

  @override
  ConsumerState<SellerApplicationView> createState() =>
      _SellerApplicationViewState();
}

class _SellerApplicationViewState
    extends ConsumerState<SellerApplicationView> {
  final _businessNameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _businessNameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    await ref.read(sellerApplicationControllerProvider.notifier).submit(
          businessName: _businessNameController.text.trim(),
          description: _descriptionController.text.trim(),
        );
    if (!mounted) return;
    final error = ref.read(sellerApplicationControllerProvider).error;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error?.toString() ?? 'Application submitted for review'),
        backgroundColor: error != null ? Colors.red : null,
      ),
    );
    if (error == null) {
      _businessNameController.clear();
      _descriptionController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(sellerApplicationControllerProvider).isLoading;
    final applicationsAsync = ref.watch(userApplicationsProvider);
    final theme = Theme.of(context);

    return AppShell(
      title: 'Become a seller',
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                applicationsAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (e, _) => Text('Could not load applications: $e'),
                  data: (apps) {
                    if (apps.isEmpty) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Your applications',
                            style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        ...apps.map((a) => Card(
                              child: ListTile(
                                title: Text(a.businessName),
                                subtitle: Text(
                                  a.status == AppConstants.statusRejected &&
                                          a.reason != null
                                      ? 'Rejected — ${a.reason}'
                                      : a.status,
                                ),
                                trailing: Icon(
                                  a.isApproved
                                      ? Icons.check_circle
                                      : a.isPending
                                          ? Icons.hourglass_empty
                                          : Icons.cancel,
                                  color: a.isApproved
                                      ? Colors.green
                                      : a.isPending
                                          ? theme.colorScheme.outline
                                          : theme.colorScheme.error,
                                ),
                              ),
                            )),
                        const SizedBox(height: 24),
                      ],
                    );
                  },
                ),
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('New application',
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _businessNameController,
                        decoration: const InputDecoration(
                          labelText: 'Business name',
                          prefixIcon: Icon(Icons.storefront_outlined),
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Enter a business name'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _descriptionController,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: 'What do you make or sell?',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => v == null || v.trim().length < 20
                            ? 'Give at least 20 characters'
                            : null,
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: isLoading ? null : _submit,
                        child: isLoading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Submit application'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
