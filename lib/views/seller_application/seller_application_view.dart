import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../controllers/seller_application_controller.dart';
import '../../core/constants.dart';
import '../../core/network_errors.dart';
import '../../core/theme.dart';
import '../../core/validators.dart';
import '../../models/seller_application_model.dart';
import '../shared/app_snackbar.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/unsaved_changes.dart';

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
    final notify = AppSnackBar.of(context);

    // Through `AppSnackBar`, which cannot get the pairing wrong. Hand-rolled,
    // this overrode `backgroundColor` to `errorContainer` and left the text at
    // Material's default `onInverseSurface` — the 1.70:1 combination that class
    // was written to end, so every failed application reported itself
    // invisibly. It also carries the error icon, which is what distinguishes
    // the two outcomes without colour vision.
    if (error == null) {
      notify.success('Application submitted for review');
    } else {
      // The controller carries specific, user-facing failures (including the
      // already-pending case). Preserve those instead of labelling every
      // refusal as a connection problem.
      notify.failure(friendlyErrorMessage(error));
    }

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

    final shell = AppShell(
      title: 'Become a 3ZERO Greenpreneur',
      rootBackToHome: false,
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
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppTheme.gapXl),
                    child: ContentLoading(label: 'Checking your applications…'),
                  ),
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

    // Protect the only substantial prose form in the onboarding flow. The
    // guard is armed only while the form itself is available; loading and
    // under-review states should still leave immediately.
    if (!applicationsAsync.hasValue || hasPending) return shell;

    return ListenableBuilder(
      listenable: Listenable.merge([
        _businessNameController,
        _descriptionController,
      ]),
      child: shell,
      builder: (context, child) => UnsavedChangesGuard(
        hasChanges:
            _businessNameController.text.trim().isNotEmpty ||
            _descriptionController.text.trim().isNotEmpty,
        title: 'Discard this application?',
        message:
            'What you have written has not been sent, and leaving now loses '
            'it.',
        child: child!,
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
