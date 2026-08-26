import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/appeals_controller.dart';
import '../../models/appeal_model.dart';

/// The way into an appeal, shown beside a rejection (F5.4).
///
/// Its own `ConsumerWidget` rather than part of the history cards, so those stay
/// stateless and both history screens get identical behaviour from one place.
///
/// Once an appeal exists for this submission the button becomes a link to it.
/// New appeals use a deterministic document id, so the rules also prevent a
/// second appeal against the same subject. This lookup changes the button into
/// a useful link before the user attempts that refused write.
class AppealButton extends ConsumerWidget {
  const AppealButton({
    super.key,
    required this.subjectType,
    required this.subjectId,
  });

  final AppealSubject subjectType;
  final String subjectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Null until the user's appeals have actually loaded. While it is null the
    // button cannot know which of its two jobs it has, so it does neither —
    // offering "Appeal this decision" on a guess sent the user to write a
    // duplicate the rules then refused.
    final appealed = ref.watch(appealedSubjectIdsProvider);
    final alreadyAppealed = appealed?.contains(
      '${subjectType.name}:$subjectId',
    );

    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: alreadyAppealed == null
            ? null
            : () => alreadyAppealed
                  ? context.push('/appeals')
                  : context.push(
                      '/appeals/new?type=${subjectType.name}&id=$subjectId',
                    ),
        icon: Icon(
          alreadyAppealed == true
              ? Icons.mark_email_read_outlined
              : Icons.gavel_outlined,
          size: 18,
        ),
        label: Text(
          alreadyAppealed == true
              ? 'You appealed this'
              : 'Appeal this decision',
        ),
      ),
    );
  }
}
