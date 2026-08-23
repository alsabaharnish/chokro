import 'package:flutter/material.dart';

import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../models/payment_model.dart';

/// Reviews a simulated online payment without collecting sensitive data.
Future<bool> showPrototypePaymentDialog({
  required BuildContext context,
  required SettlementMethod method,
  required int amountTaka,
  required String purpose,
}) async {
  assert(method.isPrototype);
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.science_outlined),
      title: const Text('Prototype payment'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppTheme.maxFormWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppTheme.gapMd),
              decoration: BoxDecoration(
                color: Theme.of(dialogContext).colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              ),
              child: const Text(
                'Simulation only — no real money will be charged or transferred.',
              ),
            ),
            const SizedBox(height: AppTheme.gapMd),
            Text('Method: ${method.shortLabel}'),
            Text('Amount: ${formatTaka(amountTaka)}'),
            Text('For: $purpose'),
            const SizedBox(height: AppTheme.gapMd),
            const Text(
              'Chokro will not ask for a card number, mobile-wallet number, PIN, '
              'OTP, or password in this prototype.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('Simulate successful payment'),
        ),
      ],
    ),
  );
  return result ?? false;
}
