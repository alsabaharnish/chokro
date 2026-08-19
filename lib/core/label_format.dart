/// Pure display helpers.
///
/// No Flutter, no Firebase, no model imports — so this is unit-testable on its
/// own and safe to call from any layer. Everything here is total: it returns a
/// sensible string for any input rather than throwing.
library;

/// Returns the bare name of an enum value, or the string itself.
///
/// `ItemType.plasticBottles` -> `plasticBottles`
/// `'plasticBottles'`        -> `plasticBottles`
/// `null`                    -> `''`
///
/// Accepting `Object?` is deliberate: the view layer can render a field whether
/// the model stores it as a typed enum or as a raw wire string, so a later
/// change of representation in the model does not ripple into the views.
String enumName(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  final text = value.toString();
  final dot = text.indexOf('.');
  return dot == -1 ? text : text.substring(dot + 1);
}

/// Turns an identifier into readable sentence-case text.
///
/// `plasticBottles`   -> `Plastic bottles`
/// `paper_cardboard`  -> `Paper cardboard`
/// `outsideRadius`    -> `Outside radius`
String humanise(Object? value) {
  final raw = enumName(value).trim();
  if (raw.isEmpty) return '';
  final spaced = raw.replaceAll('_', ' ').replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (m) => '${m[1]} ${m[2]!.toLowerCase()}',
      );
  return spaced[0].toUpperCase() + spaced.substring(1);
}

const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `2 Aug 2026, 14:05`. Local time.
///
/// Written by hand rather than pulling in `intl`: one format is needed, the
/// interface is English-only for this release (NFR-8), and adding a
/// localisation package now would imply a localisation story that is deferred.
String formatDateTime(DateTime? value) {
  if (value == null) return '';
  final local = value.toLocal();
  final month = _months[local.month - 1];
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${local.day} $month ${local.year}, $hh:$mm';
}

/// `2 Aug 2026`. Local time, no clock.
///
/// For dates where the time of day is noise rather than information: a join
/// date, a suspension expiry. The home screen and the profile screen had each
/// grown a private copy of this, complete with its own duplicate month list.
String formatDate(DateTime? value) {
  if (value == null) return '';
  final local = value.toLocal();
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}

/// How long until [until]: `4h 12m`, `12m`, `under a minute`.
///
/// The counterpart to [formatAge], which looks backwards. Used for the disposal
/// lockout window (F2.6), where the number is the whole point of the message —
/// "you already used this bin" leaves someone guessing whether to wait or walk,
/// and "try again in 4h 12m" does not.
///
/// Rounds down and never returns a negative: an elapsed window reads as
/// `under a minute` on its way to not being shown at all.
String formatCountdown(DateTime? until, {DateTime? now}) {
  if (until == null) return '';

  final remaining = until.difference(now ?? DateTime.now());
  if (remaining.isNegative || remaining.inMinutes < 1) return 'under a minute';

  final hours = remaining.inHours;
  final minutes = remaining.inMinutes % 60;

  if (hours == 0) return '${minutes}m';
  if (minutes == 0) return '${hours}h';
  return '${hours}h ${minutes}m';
}

/// Short relative age for list rows: `just now`, `14m ago`, `3h ago`, `5d ago`.
/// Falls back to the absolute date beyond a week.
///
/// A null timestamp means the server timestamp has not resolved yet — the write
/// is still in Firestore's local queue — so it reads as `just now` rather than
/// as an error.
String formatAge(DateTime? value, {DateTime? now}) {
  if (value == null) return 'just now';
  final reference = now ?? DateTime.now();
  final diff = reference.difference(value);
  if (diff.isNegative || diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return formatDateTime(value);
}

/// `50` -> `+50`, `-120` -> `-120`, `0` -> `0`.
String signedPoints(int delta) => delta > 0 ? '+$delta' : '$delta';

/// `1` -> `1 item`, `4` -> `4 items`.
String itemCount(int? count) {
  if (count == null) return '';
  return count == 1 ? '1 item' : '$count items';
}

/// `1250` -> `৳1,250`.
///
/// Whole taka, with a thousands separator and no decimal part. Prices, discounts
/// and payable amounts are integers throughout (§7.3) — the points economy is
/// integer arithmetic end to end, and a displayed `৳1250.00` would imply a
/// precision the schema does not carry.
///
/// Grouping is done by hand rather than through `intl`'s `NumberFormat`, which
/// would need a locale and would place separators by that locale's convention.
/// The interface language is English (NFR-8) and the currency is fixed, so one
/// rule applied consistently is more predictable than one resolved at runtime.
String formatTaka(int amount) {
  final negative = amount < 0;
  final digits = amount.abs().toString();

  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }

  return '${negative ? '-' : ''}৳$buffer';
}

/// `1` -> `1 order`, `3` -> `3 orders`.
String orderCount(int count) => count == 1 ? '1 order' : '$count orders';
