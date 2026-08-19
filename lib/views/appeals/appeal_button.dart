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
/// Nothing in the rules forbids a second appeal against the same subject — an
/// exact-key rule cannot express "not already present in this collection" — so
/// this is a courtesy that keeps the administrator's queue from filling with
/// duplicates, not a guarantee.
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
    final alreadyAppealed = ref
        .watch(appealedSubjectIdsProvider)
        .contains(subjectId);

    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => alreadyAppealed
            ? context.push('/appeals')
            : context.push(
                '/appeals/new?type=${subjectType.name}&id=$subjectId',
              ),
        icon: Icon(
          alreadyAppealed
              ? Icons.mark_email_read_outlined
              : Icons.gavel_outlined,
          size: 18,
        ),
        label: Text(
          alreadyAppealed ? 'You appealed this' : 'Appeal this decision',
        ),
      ),
    );
  }
}
