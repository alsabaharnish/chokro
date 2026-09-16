/// Champion account deletion (SEC-13).
///
/// ## What these models exist to prevent
///
/// Two flattenings, both of which would turn an honest server response into a
/// dishonest screen.
///
/// **A partial deletion is not a deletion.** The server answers 207 when a step
/// failed, and reports which. Modelling the outcome as a bool would collapse
/// "we removed your name and your photograph is still on a CDN" into "done",
/// which is how somebody is told they were forgotten when they were not.
///
/// **What is retained is part of the answer, not a footnote.** Every category
/// in [DeletionPlan.retained] is something a person asking to be erased would
/// reasonably expect to go. They travel with the plan and with the outcome, so
/// a screen cannot show one without the other.
library;

/// One thing a deletion removes.
class ErasedCategory {
  const ErasedCategory({required this.what, required this.where});

  final String what;

  /// Where it lived. Shown because "we deleted your photo" and "we deleted your
  /// photo from the CDN that served it" are different assurances.
  final String where;

  factory ErasedCategory.fromJson(Map<String, dynamic> json) {
    return ErasedCategory(
      what: json['what'] is String ? json['what'] as String : '',
      where: json['where'] is String ? json['where'] as String : '',
    );
  }
}

/// One thing a deletion keeps, and the reason.
class RetainedCategory {
  const RetainedCategory({
    required this.what,
    required this.why,
    required this.contested,
  });

  final String what;
  final String why;

  /// Whether Chokro's right to keep this is settled.
  ///
  /// False means nothing identifies anyone and there is no question to answer.
  /// True means a lawyer has not yet confirmed Chokro may keep it — and an
  /// Admin telling a Champion what happens to their data should know which
  /// answers are firm and which are Chokro's position (decision 9).
  final bool contested;

  factory RetainedCategory.fromJson(Map<String, dynamic> json) {
    return RetainedCategory(
      what: json['what'] is String ? json['what'] as String : '',
      why: json['why'] is String ? json['why'] as String : '',
      contested: json['contested'] == true,
    );
  }
}

/// What a deletion would do, before it does it.
class DeletionPlan {
  const DeletionPlan({
    required this.uid,
    required this.accountExists,
    required this.alreadyDeleted,
    required this.erased,
    required this.retained,
    this.name,
    this.email,
    this.role,
    this.hasProfilePhoto = false,
    this.note,
  });

  final String uid;
  final bool accountExists;
  final bool alreadyDeleted;
  final List<ErasedCategory> erased;
  final List<RetainedCategory> retained;

  /// Null once the account has been erased. Not an empty string — there is a
  /// difference between an account with no name and an account whose name has
  /// been removed, and only one of them is this screen's doing.
  final String? name;
  final String? email;
  final String? role;
  final bool hasProfilePhoto;

  /// The server's explanation when there is no account document.
  final String? note;

  /// Whether anything Chokro has not settled its right to keep is involved.
  bool get hasContestedRetention => retained.any((r) => r.contested);

  factory DeletionPlan.fromJson(Map<String, dynamic> json) {
    return DeletionPlan(
      uid: json['uid'] is String ? json['uid'] as String : '',
      accountExists: json['accountExists'] == true,
      alreadyDeleted: json['alreadyDeleted'] == true,
      erased: _erased(json['erased']),
      retained: _retained(json['retained']),
      name: json['name'] is String ? json['name'] as String : null,
      email: json['email'] is String ? json['email'] as String : null,
      role: json['role'] is String ? json['role'] as String : null,
      hasProfilePhoto: json['hasProfilePhoto'] == true,
      note: json['note'] is String ? json['note'] as String : null,
    );
  }
}

/// What a deletion actually did.
class DeletionOutcome {
  const DeletionOutcome({
    required this.uid,
    required this.complete,
    required this.alreadyDeleted,
    required this.erased,
    required this.failed,
    required this.retained,
  });

  final String uid;

  /// False when any step failed. The screen must not render this the way it
  /// renders a clean run — see the library comment.
  final bool complete;

  final bool alreadyDeleted;

  /// What actually ran, in the server's words.
  final List<String> erased;

  /// What did not, named. Empty on a clean run.
  final List<String> failed;

  final List<RetainedCategory> retained;

  factory DeletionOutcome.fromJson(Map<String, dynamic> json) {
    return DeletionOutcome(
      uid: json['uid'] is String ? json['uid'] as String : '',
      // Absent means the server did not say. Treated as INCOMPLETE rather than
      // complete: a missing field must never read as reassurance here.
      complete: json['complete'] == true,
      alreadyDeleted: json['alreadyDeleted'] == true,
      erased: _strings(json['erased']),
      failed: _strings(json['failed']),
      retained: _retained(json['retained']),
    );
  }
}

List<ErasedCategory> _erased(Object? value) {
  if (value is! List) return const <ErasedCategory>[];
  return value
      .whereType<Map<String, dynamic>>()
      .map(ErasedCategory.fromJson)
      .toList(growable: false);
}

List<RetainedCategory> _retained(Object? value) {
  if (value is! List) return const <RetainedCategory>[];
  return value
      .whereType<Map<String, dynamic>>()
      .map(RetainedCategory.fromJson)
      .toList(growable: false);
}

List<String> _strings(Object? value) {
  if (value is! List) return const <String>[];
  return value.whereType<String>().toList(growable: false);
}
