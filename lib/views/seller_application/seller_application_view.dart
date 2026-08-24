import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../controllers/seller_application_controller.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../core/validators.dart';
import '../../models/seller_application_model.dart';
import '../shared/app_shell.dart';
import '../shared/error_retry.dart';

class SellerApplicationView extends ConsumerStatefulWidget {
  const SellerApplicationView({super.key});

  @override
  ConsumerState<SellerApplicationView> createState() =>
      _SellerApplicationViewState();
}

class _SellerApplicationViewState extends ConsumerState<SellerApplicationView> {
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

    await ref
        .read(sellerApplicationControllerProvider.notifier)
        .submit(
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
    final hasPending =
        applicationsAsync.value?.any((application) => application.isPending) ??
        false;
    final theme = Theme.of(context);

    return AppShell(
      title: 'Become a 3ZERO Greenpreneur',
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppTheme.gapLg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.storefront_outlined,
                          size: 34,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: AppTheme.gapMd),
                        Text(
                          'Grow a green livelihood',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: AppTheme.gapSm),
                        const Text(
                          '3ZERO Greenpreneurs offer sustainable products, '
                          'keep stock accurate and fulfil orders for 3ZERO '
                          'Champions. Applications are reviewed before selling '
                          'tools are enabled.',
                        ),
                        const SizedBox(height: AppTheme.gapMd),
                        const _Benefit(
                          icon: Icons.inventory_2_outlined,
                          text:
                              'Create and manage sustainable product listings',
                        ),
                        const _Benefit(
                          icon: Icons.local_shipping_outlined,
                          text: 'Receive and fulfil Champion orders',
                        ),
                        const _Benefit(
                          icon: Icons.swap_horiz,
                          text:
                              'Keep your 3ZERO Champion profile and switch any time',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppTheme.gapLg),
                applicationsAsync.when(
                  loading: () => const SizedBox.shrink(),
                  // The last raw `$error` surface in `lib/views/`. This one is
                  // shown to an applicant, so a Firestore vendor prefix was
                  // being offered as feedback on their business application.
                  error: (e, _) => ErrorRetry(
                    error: e,
                    title: 'Your applications',
                    onRetry: () => ref.invalidate(userApplicationsProvider),
                  ),
                  data: (apps) {
                    if (apps.isEmpty) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Your applications',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        ...apps.map(
                          (a) => Card(
                            child: ListTile(
                              title: Text(a.businessName),
                              subtitle: Text(_applicationStatus(a)),
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
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                    );
                  },
                ),
                if (!applicationsAsync.hasValue)
                  const SizedBox.shrink()
                else if (hasPending)
                  Card(
                    color: theme.colorScheme.secondaryContainer,
                    child: const ListTile(
                      leading: Icon(Icons.hourglass_top_outlined),
                      title: Text('Application under review'),
                      subtitle: Text(
                        'You can keep using your Champion profile. The '
                        'Greenpreneur workspace will appear automatically if '
                        'your application is approved.',
                      ),
                    ),
                  )
                else
                  Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'New application',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _businessNameController,
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          enabled: !isLoading,
                          // Both bounds come from `firestore.rules`, which
                          // refuses the write outright with no way to say which
                          // field was wrong — see [TextLimits].
                          maxLength: TextLimits.businessNameMax,
                          // `border` is no longer repeated at every field — the
                          // shared input theme owns it.
                          decoration: const InputDecoration(
                            labelText: 'Business name',
                            prefixIcon: Icon(Icons.storefront_outlined),
                          ),
                          validator: (v) => validateMinLength(
                            v,
                            TextLimits.businessNameMin,
                            'a business name',
                            maximum: TextLimits.businessNameMax,
                          ),
                        ),
                        const SizedBox(height: AppTheme.gapMd),
                        TextFormField(
                          controller: _descriptionController,
                          maxLines: 4,
                          minLines: 4,
                          textCapitalization: TextCapitalization.sentences,
                          enabled: !isLoading,
                          maxLength: TextLimits.applicationDescriptionMax,
                          decoration: const InputDecoration(
                            labelText: 'What do you make or sell?',
                            alignLabelWithHint: true,
                            helperText:
                                'A 3ZERO Admin reads this. At least 20 characters.',
                          ),
                          validator: (v) => validateMinLength(
                            v,
                            TextLimits.applicationDescriptionMin,
                            'a description',
                            maximum: TextLimits.applicationDescriptionMax,
                          ),
                        ),
                        const SizedBox(height: AppTheme.gapLg),
                        FilledButton(
                          onPressed: isLoading ? null : _submit,
                          child: isLoading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
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

  static String _applicationStatus(SellerApplicationModel application) {
    if (application.status == AppConstants.statusRejected) {
      return application.reason == null
          ? 'Not approved'
          : 'Not approved — ${application.reason}';
    }
    if (application.status == AppConstants.statusApproved) return 'Approved';
    return 'Under review';
  }
}

class _Benefit extends StatelessWidget {
  const _Benefit({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.gapSm),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: AppTheme.gapSm),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
