/// Chokro — reporting periods in Asia/Dhaka (EPR-23, QA-3).
///
/// ## Why this is a file and not an inline `toIso8601String().substring(0, 7)`
///
/// A period boundary error in an annual filing is a compliance error. A
/// disposal decided at 02:00 on 1 October Dhaka time is 20:00 on 30 September
/// in UTC, so a `periodId` taken from a UTC timestamp puts it in the wrong
/// month — and the two months it lands between are both reported to a
/// regulator, one of them short and one long, with nothing in either document
/// that looks wrong.
///
/// ## Why a fixed offset is correct here, and not a shortcut
///
/// Asia/Dhaka is UTC+6 with no daylight saving. Bangladesh has observed DST
/// exactly once, from June to December 2009, when clocks ran at UTC+7. Every
/// timestamp this system will ever hold is from 2026 or later, so the offset is
/// a constant for all data in scope and a timezone database would add a
/// dependency to resolve a value that cannot vary.
///
/// That reasoning is recorded because it stops being true if Bangladesh
/// reintroduces DST. If it does, [dhakaOffset] is the one thing to change, and
/// historical periods must be recomputed rather than reinterpreted — which is
/// what `recomputedAt` on `eprPeriods` exists for.
///
/// Plain Dart, no Firebase and no Flutter imports. Pure and clock-injected, so
/// every branch is testable without waiting (QA-1).
library;

/// Asia/Dhaka's fixed offset from UTC. See the library comment.
const Duration dhakaOffset = Duration(hours: 6);

/// The `periodId` a moment falls in, formatted `YYYY-MM`.
///
/// Takes any [DateTime] and converts through UTC first, so a local
/// [DateTime.now()] on a device in another timezone resolves to the same period
/// as the server would. A caller that passed an already-local value and expected
/// it to be treated as Dhaka time would be wrong, and this cannot tell the
/// difference — which is why the server derives every stored `periodId` from its
/// own clock and the client only ever displays one (EPR-23).
String periodIdFor(DateTime moment) {
  final dhaka = moment.toUtc().add(dhakaOffset);
  final month = dhaka.month.toString().padLeft(2, '0');
  return '${dhaka.year}-$month';
}

/// Whether [value] is a well-formed `periodId`.
///
/// Used to refuse a client-supplied period rather than querying with it. A
/// malformed period would return an empty rollup, which a screen would render
/// as a month with no activity — indistinguishable from a real quiet month.
bool isValidPeriodId(String value) {
  if (!RegExp(r'^\d{4}-\d{2}$').hasMatch(value)) return false;
  final month = int.parse(value.substring(5));
  if (month < 1 || month > 12) return false;
  final year = int.parse(value.substring(0, 4));
  // The gazette was published in 2026; a period before it cannot carry an
  // obligation, and one far ahead is a typo rather than a forecast.
  return year >= 2026 && year <= 2100;
}

/// The first instant of a period, as UTC.
///
/// Half-open ranges throughout: a period covers `[start, end)`. A closed range
/// would need "the last millisecond of the month", which is a value nobody can
/// write correctly twice.
DateTime periodStartUtc(String periodId) {
  final year = int.parse(periodId.substring(0, 4));
  final month = int.parse(periodId.substring(5));
  // Midnight in Dhaka is 18:00 the previous day in UTC.
  return DateTime.utc(year, month, 1).subtract(dhakaOffset);
}

/// The first instant of the *next* period, as UTC — the exclusive end.
DateTime periodEndUtc(String periodId) {
  final year = int.parse(periodId.substring(0, 4));
  final month = int.parse(periodId.substring(5));
  final nextYear = month == 12 ? year + 1 : year;
  final nextMonth = month == 12 ? 1 : month + 1;
  return DateTime.utc(nextYear, nextMonth, 1).subtract(dhakaOffset);
}

/// Whether [moment] falls inside [periodId].
///
/// Derived from [periodIdFor] rather than from a range comparison, so there is
/// one definition of which period a moment belongs to and no possibility of the
/// two disagreeing at a boundary.
bool periodContains(String periodId, DateTime moment) =>
    periodIdFor(moment) == periodId;

/// The period before [periodId].
String previousPeriodId(String periodId) {
  final year = int.parse(periodId.substring(0, 4));
  final month = int.parse(periodId.substring(5));
  final priorYear = month == 1 ? year - 1 : year;
  final priorMonth = month == 1 ? 12 : month - 1;
  return '$priorYear-${priorMonth.toString().padLeft(2, '0')}';
}

/// The period after [periodId].
String nextPeriodId(String periodId) {
  final year = int.parse(periodId.substring(0, 4));
  final month = int.parse(periodId.substring(5));
  final laterYear = month == 12 ? year + 1 : year;
  final laterMonth = month == 12 ? 1 : month + 1;
  return '$laterYear-${laterMonth.toString().padLeft(2, '0')}';
}

/// The [count] most recent periods ending at [periodId], oldest first.
///
/// Bounded by construction: a caller asks for twelve months, not "all of
/// them", so a trend chart cannot become an unbounded read (QA-10).
List<String> periodsEndingAt(String periodId, {required int count}) {
  if (count <= 0) return const <String>[];

  final periods = <String>[periodId];
  var current = periodId;
  for (var i = 1; i < count; i += 1) {
    current = previousPeriodId(current);
    periods.add(current);
  }
  return periods.reversed.toList(growable: false);
}

/// A period as a person reads it: `September 2026`.
String periodLabel(String periodId) {
  if (!isValidPeriodId(periodId)) return periodId;
  const months = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final month = int.parse(periodId.substring(5));
  return '${months[month - 1]} ${periodId.substring(0, 4)}';
}

/// The composite document id for a period rollup: `{orgId}_{periodId}`.
///
/// One function, so the client, the server and the rules tests cannot drift
/// into composing it differently — the same reasoning as
/// `OrgMemberModel.documentId`.
String eprPeriodDocumentId(String orgId, String periodId) =>
    '${orgId}_$periodId';
