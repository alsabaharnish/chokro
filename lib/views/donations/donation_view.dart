import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/donation_controller.dart';
import '../../controllers/wallet_controller.dart';
import '../../core/theme.dart';
import '../../models/donation_model.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';

class DonationView extends ConsumerStatefulWidget {
  const DonationView({super.key});

  @override
  ConsumerState<DonationView> createState() => _DonationViewState();
}

class _DonationViewState extends ConsumerState<DonationView> {
  static const int _minimum = 10;

  final _formKey = GlobalKey<FormState>();
  final _points = TextEditingController(text: '100');
  GreenInitiative _initiative = GreenInitiative.wasteRecovery;

  @override
  void dispose() {
    _points.dispose();
    super.dispose();
  }

  void _changeDraft(VoidCallback change) {
    setState(change);
    ref.read(donationControllerProvider.notifier).resetDraft();
  }

  void _useAmount(int points) {
    _changeDraft(() => _points.text = '$points');
  }

  Future<void> _submit(int balance) async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final points = int.parse(_points.text.trim());
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm point donation'),
        content: Text(
          'Donate $points points to ${_initiative.label}? Your balance will be '
          '${balance - points} points. Point donations cannot be reversed in the app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not yet'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.volunteer_activism_outlined),
            label: const Text('Donate points'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await ref
        .read(donationControllerProvider.notifier)
        .donate(initiative: _initiative, points: points);
  }

  @override
  Widget build(BuildContext context) {
    final walletAsync = ref.watch(walletProvider);
    final donation = ref.watch(donationControllerProvider);
    final outcome = donation.value;

    return AppShell(
      title: 'Support green initiatives',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTheme.maxContentWidth),
          child: walletAsync.when(
            loading: () => const ContentLoading(label: 'Loading your points…'),
            error: (error, _) => ContentEmpty(
              icon: Icons.account_balance_wallet_outlined,
              title: 'Your wallet could not be loaded',
              message: 'Check your connection and try again.',
              actionLabel: 'Try again',
              onAction: () => ref.invalidate(walletProvider),
            ),
            data: (wallet) {
              final balance = wallet?.balance ?? 0;
              if (outcome != null) {
                return _DonationSuccess(
                  outcome: outcome,
                  onViewWallet: () => context.go('/wallet'),
                  onDonateAgain: () {
                    _points.text = '100';
                    ref.read(donationControllerProvider.notifier).resetDraft();
                  },
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
                  _Intro(balance: balance),
                  const SizedBox(height: AppTheme.gapLg),
                  Text(
                    'Choose an initiative',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppTheme.gapSm),
                  RadioGroup<GreenInitiative>(
                    groupValue: _initiative,
                    onChanged: (value) {
                      if (value == null || donation.isLoading) return;
                      _changeDraft(() => _initiative = value);
                    },
                    child: Column(
                      children: [
                        for (final initiative in GreenInitiative.values)
                          Card(
                            margin: const EdgeInsets.only(
                              bottom: AppTheme.gapSm,
                            ),
                            child: RadioListTile<GreenInitiative>(
                              value: initiative,
                              enabled: !donation.isLoading,
                              title: Text(initiative.label),
                              subtitle: Text(initiative.description),
                              secondary: Icon(_initiativeIcon(initiative)),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppTheme.gapMd),
                  Text(
                    'Choose points',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppTheme.gapSm),
                  Wrap(
                    spacing: AppTheme.gapSm,
                    runSpacing: AppTheme.gapSm,
                    children: [
                      for (final amount in const [50, 100, 250, 500])
                        ChoiceChip(
                          label: Text('$amount'),
                          selected: _points.text.trim() == '$amount',
                          onSelected: donation.isLoading || amount > balance
                              ? null
                              : (_) => _useAmount(amount),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppTheme.gapMd),
                  Form(
                    key: _formKey,
                    child: TextFormField(
                      controller: _points,
                      enabled: !donation.isLoading,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) {
                        setState(() {});
                        ref
                            .read(donationControllerProvider.notifier)
                            .resetDraft();
                      },
                      decoration: const InputDecoration(
                        labelText: 'Points to donate',
                        prefixIcon: Icon(Icons.stars_outlined),
                        helperText:
                            'Minimum 10 points. This is not a cash payment.',
                      ),
                      validator: (value) {
                        final points = int.tryParse(value?.trim() ?? '');
                        if (points == null) {
                          return 'Enter a whole number of points';
                        }
                        if (points < _minimum) {
                          return 'Donate at least $_minimum points';
                        }
                        if (points > balance) {
                          return 'You have $balance points available';
                        }
                        return null;
                      },
                    ),
                  ),
                  if (donation.hasError) ...[
                    const SizedBox(height: AppTheme.gapMd),
                    _DonationError(message: donation.error.toString()),
                  ],
                  const SizedBox(height: AppTheme.gapLg),
                  FilledButton.icon(
                    onPressed: donation.isLoading || balance < _minimum
                        ? null
                        : () => _submit(balance),
                    icon: donation.isLoading
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.volunteer_activism_outlined),
                    label: Text(
                      donation.isLoading ? 'Donating…' : 'Review donation',
                    ),
                  ),
                  if (balance < _minimum) ...[
                    const SizedBox(height: AppTheme.gapSm),
                    Text(
                      'Earn at least $_minimum points through verified green actions before donating.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  static IconData _initiativeIcon(GreenInitiative initiative) =>
      switch (initiative) {
        GreenInitiative.wasteRecovery => Icons.recycling_outlined,
        GreenInitiative.treePlanting => Icons.park_outlined,
        GreenInitiative.greenEntrepreneurship => Icons.storefront_outlined,
      };
}

class _Intro extends StatelessWidget {
  const _Intro({required this.balance});

  final int balance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppTheme.gapLg),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.volunteer_activism_outlined,
            color: theme.colorScheme.onPrimaryContainer,
            size: 32,
          ),
          const SizedBox(height: AppTheme.gapMd),
          Text(
            'Turn your rewards into shared impact',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppTheme.gapSm),
          Text(
            'Contribute earned reward points to a 3ZERO initiative. Every debit '
            'is recorded in your wallet activity. You currently have $balance points.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _DonationError extends StatelessWidget {
  const _DonationError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppTheme.gapMd),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: AppTheme.gapSm),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _DonationSuccess extends StatelessWidget {
  const _DonationSuccess({
    required this.outcome,
    required this.onViewWallet,
    required this.onDonateAgain,
  });

  final DonationOutcome outcome;
  final VoidCallback onViewWallet;
  final VoidCallback onDonateAgain;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppTheme.gapMd),
      children: [
        const SizedBox(height: AppTheme.gapXl),
        Icon(
          Icons.check_circle,
          size: 72,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: AppTheme.gapMd),
        Text(
          'Thank you, Champion',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppTheme.gapSm),
        Text(
          '${outcome.points} points were contributed to '
          '${outcome.initiative.label}. Your new balance is '
          '${outcome.balanceAfter} points.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppTheme.gapXl),
        FilledButton.icon(
          onPressed: onViewWallet,
          icon: const Icon(Icons.account_balance_wallet_outlined),
          label: const Text('View wallet activity'),
        ),
        const SizedBox(height: AppTheme.gapSm),
        OutlinedButton(
          onPressed: onDonateAgain,
          child: const Text('Support another initiative'),
        ),
      ],
    );
  }
}
