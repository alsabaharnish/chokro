import 'package:flutter/material.dart';

import '../../models/disposal_model.dart';

/// The four-state disposal status, rendered for the person who submitted it.
///
/// `autoApproved` and `manualApproved` stay visibly distinct. Collapsing them
/// would lose the answer to "was this checked by a person?", which is exactly
/// what a user needs to know before appealing and what an examiner asks about
/// any auto-credited award.
///
/// The switch below is exhaustive over the enum, so there is no fallback here
/// and there should not be one: an unrecognised wire value is already resolved
/// to [DisposalStatus.pending] by `DisposalStatus.fromName` at the parse
/// boundary. One fallback, in one place.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status, this.dense = false});

  final DisposalStatus status;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final (Color foreground, Color background, IconData icon, String label) =
        switch (status) {
      DisposalStatus.pending => (
          scheme.onSurfaceVariant,
          scheme.surfaceContainerHighest,
          Icons.hourglass_empty_outlined,
          'Waiting for review',
        ),
      DisposalStatus.autoApproved => (
          scheme.onTertiaryContainer,
          scheme.tertiaryContainer,
          Icons.bolt_outlined,
          'Approved automatically',
        ),
      DisposalStatus.manualApproved => (
          scheme.onSecondaryContainer,
          scheme.secondaryContainer,
          Icons.verified_outlined,
          'Verified by a reviewer',
        ),
      DisposalStatus.rejected => (
          scheme.onErrorContainer,
          scheme.errorContainer,
          Icons.cancel_outlined,
          'Rejected',
        ),
    };

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: dense ? 13 : 15, color: foreground),
          const SizedBox(width: 5),
          Text(
            label,
            style: (dense
                    ? Theme.of(context).textTheme.labelSmall
                    : Theme.of(context).textTheme.labelMedium)
                ?.copyWith(color: foreground, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
