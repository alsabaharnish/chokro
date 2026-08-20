/// Chokro — an appeal against a rejection (F5.4).
///
/// Plain Dart, no Firebase imports (§5.1).
///
/// ## What an appeal is, and what it deliberately is not
///
/// A rejection already records a reason and shows it to the user (§7.4). An
/// appeal is the reply to that reason: the user says why they think the decision
/// was wrong, and an administrator answers in writing.
///
/// **Resolving an appeal moves no points.** That is the design, not an omission.
/// A rejection releases the bin lockout precisely so a legitimate submission can
/// be made again, so the remedy for a wrong rejection is a fresh submission that
/// goes through the whole verification pipeline — not a hand-credited award that
/// bypasses it. Keeping payouts out of this collection is what lets appeals be
/// resolved through `firestore.rules` at all, the same shape as
/// `sellerApplications`: an administrator may flip a pending appeal's status and
/// write a response, and that is the entire privilege. Nothing here can credit a
/// wallet, so nothing here needs the server.
///
/// This is the same test applied throughout — is the constraint expressible
/// where it is enforced? For an appeal it is, so it stays in the rules.
library;

/// What the appeal is about. Both routes can be rejected, so both can be
/// appealed.
enum AppealSubject {
  disposal,
  claim;

  static AppealSubject? fromName(String? name) {
    for (final subject in AppealSubject.values) {
      if (subject.name == name) return subject;
    }
    return null;
  }

  String get label =>
      this == AppealSubject.disposal ? 'Disposal' : 'Eco-action claim';
}

/// Where the appeal stands.
enum AppealStatus {
  pending,
  upheld,
  declined;

  /// Unrecognised reads as [pending] — an appeal nobody can parse is one nobody
  /// has answered.
  static AppealStatus fromName(String? name) {
    for (final status in AppealStatus.values) {
      if (status.name == name) return status;
    }
    return AppealStatus.pending;
  }

  bool get isPending => this == AppealStatus.pending;

  String get label {
    switch (this) {
      case AppealStatus.pending:
        return 'Awaiting review';
      case AppealStatus.upheld:
        return 'Upheld';
      case AppealStatus.declined:
        return 'Declined';
    }
  }
}

class AppealModel {
  const AppealModel({
    this.id,
    required this.userId,
    required this.subjectType,
    required this.subjectId,
    required this.message,
    this.status = AppealStatus.pending,
    this.response,
    this.reviewedBy,
    this.reviewedAt,
    this.createdAt,
  });

  final String? id;
  final String userId;
  final AppealSubject subjectType;

  /// The rejected disposal or claim this appeal is about.
  final String subjectId;

  /// The user's case, in their own words.
  final String message;

  final AppealStatus status;

  /// The administrator's written answer. Mandatory on any resolution — an
  /// appeal answered with a status and no words is not an answer, and rules
  /// enforce its presence exactly as they do a rejection reason.
  final String? response;

  final String? reviewedBy;
  final DateTime? reviewedAt;
  final DateTime? createdAt;

  static const int messageMin = 20;
  static const int messageMax = 1000;
  static const int responseMin = 10;
  static const int responseMax = 1000;

  /// Deterministic so one rejection can create at most one appeal per user.
  String get documentId => '${userId}_${subjectType.name}_$subjectId';

  /// Type-qualified key for client-side lookups. Claim and disposal document
  /// ids can coincidentally be equal and must not hide each other's button.
  String get subjectKey => '${subjectType.name}:$subjectId';

  /// The exact key set `firestore.rules` allows a user to create. `createdAt` is
  /// supplied by the service as a server timestamp.
  Map<String, dynamic> toCreateJson() => <String, dynamic>{
    'userId': userId,
    'subjectType': subjectType.name,
    'subjectId': subjectId,
    'message': message.trim(),
    'status': AppealStatus.pending.name,
  };

  factory AppealModel.fromMap(Map<String, dynamic>? raw, {String? id}) {
    final data = raw ?? const <String, dynamic>{};
    return AppealModel(
      id: id,
      userId: _string(data['userId']),
      subjectType:
          AppealSubject.fromName(_nullableString(data['subjectType'])) ??
          AppealSubject.disposal,
      subjectId: _string(data['subjectId']),
      message: _string(data['message']),
      status: AppealStatus.fromName(_nullableString(data['status'])),
      response: _nullableString(data['response']),
      reviewedBy: _nullableString(data['reviewedBy']),
      reviewedAt: _date(data['reviewedAt']),
      createdAt: _date(data['createdAt']),
    );
  }

  /// Problems with the user's text, in the words they need. The same bounds the
  /// rules enforce.
  static String? validateMessage(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Explain why you think the decision was wrong';
    if (text.length < messageMin) {
      final needed = messageMin - text.length;
      return '$needed more character${needed == 1 ? '' : 's'}';
    }
    if (text.length > messageMax) {
      return 'That is longer than $messageMax characters';
    }
    return null;
  }

  static String? validateResponse(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Write the answer the user will see';
    if (text.length < responseMin) {
      final needed = responseMin - text.length;
      return '$needed more character${needed == 1 ? '' : 's'}';
    }
    if (text.length > responseMax) {
      return 'That is longer than $responseMax characters';
    }
    return null;
  }
}

String _string(Object? value) => value is String ? value : '';
String? _nullableString(Object? value) => value is String ? value : null;

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
