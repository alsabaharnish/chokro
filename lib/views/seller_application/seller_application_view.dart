import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../controllers/seller_application_controller.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../core/validators.dart';
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
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    await ref.read(sellerApplicationControllerProvider.notifier).submit(
          businessName: _businessNameController.text.trim(),
          description: _descriptionController.text.trim(),
        );
    if (!mounted) return;

    final error = ref.read(sellerApplicationControllerProvider).error;
    final scheme = Theme.of(context).colorScheme;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            // `error.toString()` used to go straight to the applicant, which
            // meant a Firestore permission-denied stack prefix was the feedback
            // on their business application.
            error == null
                ? 'Application submitted for review'
                : 'Your application could not be sent. Check your connection '
                    'and try again.',
          ),
          backgroundColor: error != null ? scheme.errorContainer : null,
          showCloseIcon: error != null,
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
                                      ? theme.colorScheme.success
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
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.next,
                        enabled: !isLoading,
                        // `border` is no longer repeated at every field — the
                        // shared input theme owns it.
                        decoration: const InputDecoration(
                          labelText: 'Business name',
                          prefixIcon: Icon(Icons.storefront_outlined),
                        ),
                        validator: (v) => validateMinLength(v, 2, 'a business name'),
                      ),
                      const SizedBox(height: AppTheme.gapMd),
                      TextFormField(
                        controller: _descriptionController,
                        maxLines: 4,
                        minLines: 4,
                        textCapitalization: TextCapitalization.sentences,
                        enabled: !isLoading,
                        decoration: const InputDecoration(
                          labelText: 'What do you make or sell?',
                          alignLabelWithHint: true,
                          helperText:
                              'An administrator reads this. At least 20 characters.',
                        ),
                        validator: (v) =>
                            validateMinLength(v, 20, 'a description'),
                      ),
                      const SizedBox(height: AppTheme.gapLg),
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
