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

    final (
      Color foreground,
      Color background,
      IconData icon,
      String label,
    ) = switch (status) {
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
          // `Flexible`, not a bare `Text`. Three of the four labels are short
          // sentences rather than single words, and `MainAxisSize.min` asks the
          // Row for their full intrinsic width however little the parent has —
          // so the chip overflowed its container on *every* phone size at the
          // default text scale, not merely at an accessibility one. Measured on
          // the submissions list, where the chip shares a row with a 64 px
          // thumbnail and the points badge: 204 px over at 320 dp, 164 at 360,
          // 134 at 390, 94 at 430. Debug builds paint the striped banner; a
          // release build silently clips the label with no ellipsis, so
          // "Approved automatically" read as "Approved autom".
          //
          // Wrapping rather than ellipsising: the label *is* the information,
          // and "Verified by a reviewer" truncated to "Verified by a…" loses
          // the part that distinguishes it from the automatic decision.
          Flexible(
            child: Text(
              label,
              style:
                  (dense
                          ? Theme.of(context).textTheme.labelSmall
                          : Theme.of(context).textTheme.labelMedium)
                      ?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
            ),
          ),
        ],
      ),
    );
  }
}
