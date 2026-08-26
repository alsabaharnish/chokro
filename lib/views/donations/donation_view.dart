import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/donation_controller.dart';
import '../../controllers/wallet_controller.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../models/donation_model.dart';
import '../../models/payment_model.dart';
import '../../models/wallet_model.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';
import '../shared/prototype_payment_dialog.dart';

enum DonationMode { points, prototypeOnline }

class DonationView extends ConsumerStatefulWidget {
  const DonationView({super.key});

  @override
  ConsumerState<DonationView> createState() => _DonationViewState();
}

class _DonationViewState extends ConsumerState<DonationView> {
  static const int _minimum = 10;

  final _formKey = GlobalKey<FormState>();
  final _points = TextEditingController(text: '100');
  final _amountTaka = TextEditingController(text: '500');
  GreenInitiative _initiative = GreenInitiative.wasteRecovery;
  SettlementMethod _paymentMethod = SettlementMethod.prototypeBkash;
  DonationMode _mode = DonationMode.points;

  @override
  void initState() {
    super.initState();
    // Neither donation controller is `autoDispose`, deliberately — holding the
    // idempotency key across a rebuild is what makes "Try again" safe after a
    // lost response. But it also means a completed outcome outlives the route:
    // a Champion who donated, read the receipt, and left with the back button
    // instead of "Done" found `/donate` reopening straight onto that old
    // receipt, with no form and no way to donate again except to notice the
    // "Donate again" button and press it.
    //
    // Deferred a frame because this runs during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(donationControllerProvider).value != null ||
          ref.read(prototypeDonationControllerProvider).value != null) {
        _resetDrafts();
      }
    });
  }

  @override
  void dispose() {
    _points.dispose();
    _amountTaka.dispose();
    super.dispose();
  }

  void _resetDrafts() {
    ref.read(donationControllerProvider.notifier).resetDraft();
    ref.read(prototypeDonationControllerProvider.notifier).resetDraft();
  }

  void _changeDraft(VoidCallback change) {
    setState(change);
    _resetDrafts();
  }

  Future<void> _submitPoints(int balance) async {
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

  Future<void> _submitPrototypePayment() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final amount = int.parse(_amountTaka.text.trim());
    final confirmed = await showPrototypePaymentDialog(
      context: context,
      method: _paymentMethod,
      amountTaka: amount,
      purpose: 'Donation to ${_initiative.label}',
    );
    if (!confirmed || !mounted) return;

    await ref
        .read(prototypeDonationControllerProvider.notifier)
        .donate(
          initiative: _initiative,
          amountTaka: amount,
          settlementMethod: _paymentMethod,
        );
  }

  @override
  Widget build(BuildContext context) {
    final walletAsync = ref.watch(walletProvider);
    final pointDonation = ref.watch(donationControllerProvider);
    final prototypeDonation = ref.watch(prototypeDonationControllerProvider);
    final pointOutcome = pointDonation.value;
    final prototypeOutcome = prototypeDonation.value;

    Widget child;
    if (_mode == DonationMode.points && pointOutcome != null) {
      child = _PointDonationSuccess(
        outcome: pointOutcome,
        onViewWallet: () => context.go('/wallet'),
        onDonateAgain: () {
          _points.text = '100';
          ref.read(donationControllerProvider.notifier).resetDraft();
        },
      );
    } else if (_mode == DonationMode.prototypeOnline &&
        prototypeOutcome != null) {
      child = _PrototypeDonationSuccess(
        outcome: prototypeOutcome,
        onDonateAgain: () {
          _amountTaka.text = '500';
          ref.read(prototypeDonationControllerProvider.notifier).resetDraft();
        },
      );
    } else {
      final activeState = _mode == DonationMode.points
          ? pointDonation
          : prototypeDonation;
      child = ListView(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.gapMd,
          AppTheme.gapMd,
          AppTheme.gapMd,
          AppTheme.gapXl,
        ),
        children: [
          _ModeSelector(
            mode: _mode,
            enabled: !activeState.isLoading,
            onChanged: (mode) => _changeDraft(() => _mode = mode),
          ),
          const SizedBox(height: AppTheme.gapMd),
          _Intro(mode: _mode),
          const SizedBox(height: AppTheme.gapLg),
          Text(
            'Choose an initiative',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppTheme.gapSm),
          RadioGroup<GreenInitiative>(
            groupValue: _initiative,
            onChanged: (value) {
              if (value != null && !activeState.isLoading) {
                _changeDraft(() => _initiative = value);
              }
            },
            child: Column(
              children: [
                for (final initiative in GreenInitiative.values)
                  Card(
                    margin: const EdgeInsets.only(bottom: AppTheme.gapSm),
                    child: RadioListTile<GreenInitiative>(
                      value: initiative,
                      enabled: !activeState.isLoading,
                      title: Text(initiative.label),
                      subtitle: Text(initiative.description),
                      secondary: Icon(_initiativeIcon(initiative)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.gapMd),
          if (_mode == DonationMode.points)
            _PointEditor(
              formKey: _formKey,
              controller: _points,
              walletAsync: walletAsync,
              state: pointDonation,
              onChanged: () {
                setState(() {});
                ref.read(donationControllerProvider.notifier).resetDraft();
              },
              onUseAmount: (points) =>
                  _changeDraft(() => _points.text = '$points'),
              onSubmit: _submitPoints,
              onRetryWallet: () => ref.invalidate(walletProvider),
            )
          else
            _PrototypePaymentEditor(
              formKey: _formKey,
              controller: _amountTaka,
              method: _paymentMethod,
              state: prototypeDonation,
              onMethodChanged: (method) =>
                  _changeDraft(() => _paymentMethod = method),
              onChanged: () {
                setState(() {});
                ref
                    .read(prototypeDonationControllerProvider.notifier)
                    .resetDraft();
              },
              onUseAmount: (amount) =>
                  _changeDraft(() => _amountTaka.text = '$amount'),
              onSubmit: _submitPrototypePayment,
            ),
        ],
      );
    }

    return AppShell(
      title: 'Support green initiatives',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTheme.maxContentWidth),
          child: child,
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

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });

  final DonationMode mode;
  final bool enabled;
  final ValueChanged<DonationMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<DonationMode>(
      segments: const [
        ButtonSegment(
          value: DonationMode.points,
          icon: Icon(Icons.stars_outlined),
          label: Text('Use points'),
        ),
        ButtonSegment(
          value: DonationMode.prototypeOnline,
          icon: Icon(Icons.credit_card_outlined),
          label: Text('Online prototype', key: Key('donation-mode-prototype')),
        ),
      ],
      selected: {mode},
      onSelectionChanged: enabled
          ? (selection) => onChanged(selection.single)
          : null,
      showSelectedIcon: false,
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro({required this.mode});

  final DonationMode mode;

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
            'Support practical green work',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppTheme.gapSm),
          Text(
            mode == DonationMode.points
                ? 'Contribute earned reward points. Every debit is recorded in '
                      'your wallet activity.'
                : 'Try the future online-donation journey. This prototype '
                      'records a simulated receipt; no real money moves.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _PointEditor extends StatelessWidget {
  const _PointEditor({
    required this.formKey,
    required this.controller,
    required this.walletAsync,
    required this.state,
    required this.onChanged,
    required this.onUseAmount,
    required this.onSubmit,
    required this.onRetryWallet,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController controller;
  final AsyncValue<WalletModel?> walletAsync;
  final AsyncValue<DonationOutcome?> state;
  final VoidCallback onChanged;
  final ValueChanged<int> onUseAmount;
  final Future<void> Function(int) onSubmit;
  final VoidCallback onRetryWallet;

  @override
  Widget build(BuildContext context) {
    return walletAsync.when(
      loading: () => const ContentLoading(label: 'Loading your points…'),
      error: (error, _) => ContentEmpty(
        icon: Icons.account_balance_wallet_outlined,
        title: 'Your wallet could not be loaded',
        message:
            'Point donations need your current balance. You can still use the online prototype.',
        actionLabel: 'Try again',
        onAction: onRetryWallet,
      ),
      data: (wallet) {
        final balance = wallet?.balance ?? 0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Choose points · $balance available',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppTheme.gapSm),
            Wrap(
              spacing: AppTheme.gapSm,
              runSpacing: AppTheme.gapSm,
              children: [
                for (final amount in const [50, 100, 250, 500])
                  ChoiceChip(
                    label: Text('$amount'),
                    selected: controller.text.trim() == '$amount',
                    onSelected: state.isLoading || amount > balance
                        ? null
                        : (_) => onUseAmount(amount),
                  ),
              ],
            ),
            const SizedBox(height: AppTheme.gapMd),
            Form(
              key: formKey,
              child: TextFormField(
                controller: controller,
                enabled: !state.isLoading,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => onChanged(),
                decoration: const InputDecoration(
                  labelText: 'Points to donate',
                  prefixIcon: Icon(Icons.stars_outlined),
                  helperText: 'Minimum 10 points. This is not a cash payment.',
                ),
                validator: (value) {
                  final points = int.tryParse(value?.trim() ?? '');
                  if (points == null) return 'Enter a whole number of points';
                  if (points < _DonationViewState._minimum) {
                    return 'Donate at least ${_DonationViewState._minimum} points';
                  }
                  if (points > balance) {
                    return 'You have $balance points available';
                  }
                  return null;
                },
              ),
            ),
            if (state.hasError) ...[
              const SizedBox(height: AppTheme.gapMd),
              _DonationError(message: state.error.toString()),
            ],
            const SizedBox(height: AppTheme.gapLg),
            FilledButton.icon(
              onPressed:
                  state.isLoading || balance < _DonationViewState._minimum
                  ? null
                  : () => onSubmit(balance),
              icon: state.isLoading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.volunteer_activism_outlined),
              label: Text(state.isLoading ? 'Donating…' : 'Review donation'),
            ),
          ],
        );
      },
    );
  }
}

class _PrototypePaymentEditor extends StatelessWidget {
  const _PrototypePaymentEditor({
    required this.formKey,
    required this.controller,
    required this.method,
    required this.state,
    required this.onMethodChanged,
    required this.onChanged,
    required this.onUseAmount,
    required this.onSubmit,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController controller;
  final SettlementMethod method;
  final AsyncValue<PrototypeDonationOutcome?> state;
  final ValueChanged<SettlementMethod> onMethodChanged;
  final VoidCallback onChanged;
  final ValueChanged<int> onUseAmount;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    const methods = [
      SettlementMethod.prototypeBkash,
      SettlementMethod.prototypeNagad,
      SettlementMethod.prototypeCard,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Choose a prototype payment method',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppTheme.gapSm),
        RadioGroup<SettlementMethod>(
          groupValue: method,
          onChanged: (value) {
            if (value != null && !state.isLoading) onMethodChanged(value);
          },
          child: Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final option in methods)
                  RadioListTile<SettlementMethod>(
                    value: option,
                    enabled: !state.isLoading,
                    title: Text(option.label),
                    subtitle: const Text('Simulation only'),
                    secondary: Icon(
                      option == SettlementMethod.prototypeCard
                          ? Icons.credit_card_outlined
                          : Icons.phone_android_outlined,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppTheme.gapMd),
        Wrap(
          spacing: AppTheme.gapSm,
          runSpacing: AppTheme.gapSm,
          children: [
            for (final amount in const [100, 500, 1000, 2500])
              ChoiceChip(
                label: Text(formatTaka(amount)),
                selected: controller.text.trim() == '$amount',
                onSelected: state.isLoading ? null : (_) => onUseAmount(amount),
              ),
          ],
        ),
        const SizedBox(height: AppTheme.gapMd),
        Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            enabled: !state.isLoading,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => onChanged(),
            decoration: const InputDecoration(
              labelText: 'Donation amount (taka)',
              prefixIcon: Icon(Icons.currency_exchange_outlined),
              helperText: 'Prototype only. Minimum ৳10; no real charge.',
            ),
            validator: (value) {
              final amount = int.tryParse(value?.trim() ?? '');
              if (amount == null) return 'Enter a whole-taka amount';
              if (amount < _DonationViewState._minimum) {
                return 'Donate at least ${formatTaka(_DonationViewState._minimum)}';
              }
              if (amount > 1000000) return 'Enter no more than ৳1,000,000';
              return null;
            },
          ),
        ),
        const SizedBox(height: AppTheme.gapSm),
        const Text(
          'Never enter a card number, mobile-wallet number, PIN, OTP, or password. '
          'This demonstration has no credential fields.',
        ),
        if (state.hasError) ...[
          const SizedBox(height: AppTheme.gapMd),
          _DonationError(message: state.error.toString()),
        ],
        const SizedBox(height: AppTheme.gapLg),
        FilledButton.icon(
          onPressed: state.isLoading ? null : onSubmit,
          icon: state.isLoading
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.science_outlined),
          label: Text(
            state.isLoading
                ? 'Recording simulation…'
                : 'Review prototype payment',
          ),
        ),
      ],
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

class _PointDonationSuccess extends StatelessWidget {
  const _PointDonationSuccess({
    required this.outcome,
    required this.onViewWallet,
    required this.onDonateAgain,
  });

  final DonationOutcome outcome;
  final VoidCallback onViewWallet;
  final VoidCallback onDonateAgain;

  @override
  Widget build(BuildContext context) {
    return _SuccessLayout(
      title: 'Thank you, Champion',
      message:
          '${outcome.points} points were contributed to ${outcome.initiative.label}. '
          'Your new balance is ${outcome.balanceAfter} points.',
      primaryLabel: 'View wallet activity',
      onPrimary: onViewWallet,
      onDonateAgain: onDonateAgain,
    );
  }
}

class _PrototypeDonationSuccess extends StatelessWidget {
  const _PrototypeDonationSuccess({
    required this.outcome,
    required this.onDonateAgain,
  });

  final PrototypeDonationOutcome outcome;
  final VoidCallback onDonateAgain;

  @override
  Widget build(BuildContext context) {
    return _SuccessLayout(
      title: 'Prototype donation recorded',
      message:
          '${formatTaka(outcome.amountTaka)} for ${outcome.initiative.label} was '
          'simulated with ${outcome.settlementMethod.shortLabel}. No real money '
          'moved.\n\nReference: ${outcome.paymentReference}',
      primaryLabel: 'Back to Champion home',
      onPrimary: () => context.go('/home'),
      onDonateAgain: onDonateAgain,
    );
  }
}

class _SuccessLayout extends StatelessWidget {
  const _SuccessLayout({
    required this.title,
    required this.message,
    required this.primaryLabel,
    required this.onPrimary,
    required this.onDonateAgain,
  });

  final String title;
  final String message;
  final String primaryLabel;
  final VoidCallback onPrimary;
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
          title,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppTheme.gapSm),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: AppTheme.gapXl),
        FilledButton(onPressed: onPrimary, child: Text(primaryLabel)),
        const SizedBox(height: AppTheme.gapSm),
        OutlinedButton(
          onPressed: onDonateAgain,
          child: const Text('Support another initiative'),
        ),
      ],
    );
  }
}
